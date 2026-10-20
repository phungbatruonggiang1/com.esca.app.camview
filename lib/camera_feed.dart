// Camera frames, from esca-camerad's shared memory to a texture.
//
// libesca-camview-bridge does the native half: claim the camera, wait for a
// frame, copy it out as packed I420. It blocks, so it runs on its own
// isolate. The bytes go straight to the GPU as they are and shaders/i420.frag
// turns them into colour there: on a Pi 4 converting on the CPU, and
// uploading four bytes a pixel instead of one and a half, cost more than a
// core and held the picture under 20 fps.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

/// One frame ready to draw: the I420 bytes as an RGBA image a quarter of the
/// capture width wide and one and a half times its height tall, four bytes
/// to a texel. Only meaningful through shaders/i420.frag.
class CameraFrame {
  CameraFrame(this.planes, this.sequence, this.width, this.height);

  final ui.Image planes;
  final int sequence;

  /// Capture size in pixels, before rotation.
  final int width, height;
}

sealed class FeedEvent {}

class FeedOpened extends FeedEvent {
  FeedOpened(this.width, this.height);

  /// Capture size, before rotation.
  final int width, height;
}

class FeedFrame extends FeedEvent {
  FeedFrame(this.frame);
  final CameraFrame frame;
}

class FeedFailed extends FeedEvent {
  FeedFailed(this.message);
  final String message;
}

abstract interface class FrameSource {
  /// Opens the camera and starts delivering. Events end with [FeedFailed] or
  /// when [stop] completes.
  Stream<FeedEvent> start();

  /// Releases the camera. Completes once the native side has let go, so the
  /// process can exit without leaving esca-camerad a client that never left.
  Future<void> stop();
}

// --- the native library ---------------------------------------------------

typedef _OpenNative = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _Open = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _Close = void Function(Pointer<Void>);
typedef _SizeNative = Int32 Function(Pointer<Void>);
typedef _Size = int Function(Pointer<Void>);
typedef _NextNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Uint64>);
typedef _Next = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint64>);

const _library = 'libesca-camview-bridge.so';

/// Frames the screen may hold at once. One more buffer than that is
/// allocated, so the isolate always has one to fill that nobody is reading.
const _credits = 2;
const _buffers = _credits + 1;

/// The isolate. It fills native buffers both isolates can see and sends only
/// which one is ready; a frame is never copied between isolates. Frames go
/// out only while the UI holds credits for them, so when drawing falls
/// behind, the isolate waits instead of piling up frames to throw away.
Future<void> _frameLoop(SendPort out) async {
  final commands = ReceivePort();
  out.send(commands.sendPort);

  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(_library);
  } on ArgumentError catch (e) {
    out.send(['error', 'cannot load $_library: $e']);
    commands.close();
    return;
  }
  final open = lib.lookupFunction<_OpenNative, _Open>('escv_open');
  final close = lib.lookupFunction<_CloseNative, _Close>('escv_close');
  final width = lib.lookupFunction<_SizeNative, _Size>('escv_width');
  final height = lib.lookupFunction<_SizeNative, _Size>('escv_height');
  final size = lib.lookupFunction<_SizeNative, _Size>('escv_i420_size');
  final next = lib.lookupFunction<_NextNative, _Next>('escv_next_i420');

  final error = calloc<Uint8>(256);
  final camera = open(error.cast<Utf8>(), 256);
  if (camera == nullptr) {
    out.send(['error', error.cast<Utf8>().toDartString()]);
    calloc.free(error);
    commands.close();
    return;
  }
  calloc.free(error);

  final bytes = size(camera);
  final buffers = [for (var i = 0; i < _buffers; i++) calloc<Uint8>(bytes)];
  out.send([
    'opened',
    width(camera),
    height(camera),
    bytes,
    [for (final b in buffers) b.address]
  ]);

  var credits = _credits;
  var running = true;
  Completer<void>? wake;
  commands.listen((message) {
    if (message == 'ack') {
      credits++;
    } else if (message == 'stop') {
      running = false;
    }
    wake?.complete();
    wake = null;
  });

  final sequence = calloc<Uint64>();
  var slot = 0;
  while (running) {
    if (credits == 0) {
      wake = Completer<void>();
      await wake!.future;
      continue;
    }
    // A short timeout keeps a stop request from waiting on a camera that
    // has gone quiet.
    if (next(camera, buffers[slot], 250, sequence) == 1) {
      credits--;
      out.send(['frame', sequence.value, slot]);
      slot = (slot + 1) % _buffers;
    }
    // Lets the command port deliver acks and stop between frames.
    await Future<void>.delayed(Duration.zero);
  }

  close(camera);
  // Freed only now: until 'closed' arrives the UI may still be reading one.
  for (final buffer in buffers) {
    calloc.free(buffer);
  }
  calloc.free(sequence);
  commands.close();
  out.send(['closed']);
}

class NativeFrameSource implements FrameSource {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _port;
  StreamController<FeedEvent>? _events;
  Completer<void>? _closed;

  @override
  Stream<FeedEvent> start() {
    final events = _events = StreamController<FeedEvent>();
    final port = _port = ReceivePort();
    _closed = Completer<void>();
    var width = 0, height = 0, bytes = 0;
    var buffers = const <int>[];

    port.listen((message) async {
      if (message is SendPort) {
        _commands = message;
        return;
      }
      final m = message as List<Object?>;
      switch (m[0]) {
        case 'opened':
          width = m[1]! as int;
          height = m[2]! as int;
          bytes = m[3]! as int;
          buffers = (m[4]! as List<Object?>).cast<int>();
          events.add(FeedOpened(width, height));
        case 'frame':
          final pixels = Pointer<Uint8>.fromAddress(buffers[m[2]! as int]).asTypedList(bytes);
          // The engine takes its own copy here; after that the buffer is the
          // isolate's again, and the credit goes back.
          final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
          _commands?.send('ack');
          final image = await _toImage(buffer, width ~/ 4, height * 3 ~/ 2);
          if (events.isClosed) {
            image.dispose();
          } else {
            events.add(FeedFrame(CameraFrame(image, m[1]! as int, width, height)));
          }
        case 'error':
          events.add(FeedFailed(m[1]! as String));
          _finish();
        case 'closed':
          _finish();
      }
    });

    Isolate.spawn(_frameLoop, port.sendPort, debugName: 'camera')
        .then((isolate) => _isolate = isolate);
    return events.stream;
  }

  static Future<ui.Image> _toImage(ui.ImmutableBuffer buffer, int width, int height) async {
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  void _finish() {
    _port?.close();
    _events?.close();
    if (!(_closed?.isCompleted ?? true)) _closed!.complete();
  }

  @override
  Future<void> stop() async {
    final commands = _commands;
    if (commands == null) {
      _isolate?.kill();
      _finish();
      return;
    }
    commands.send('stop');
    // Bounded: an isolate wedged in the native call must not keep the
    // application from closing.
    await _closed!.future.timeout(const Duration(seconds: 2), onTimeout: () {
      _isolate?.kill(priority: Isolate.immediate);
      _finish();
    });
  }
}
