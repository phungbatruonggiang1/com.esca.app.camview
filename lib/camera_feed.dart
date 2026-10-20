// Camera frames, from esca-camerad's shared memory to a ui.Image.
//
// libesca-camview-bridge does the native half (claim the camera, wait for a
// frame, YUV420 to RGBA). It blocks, so it runs on its own isolate: the UI
// isolate only ever receives finished RGBA buffers, and a slow frame never
// holds up a pointer event or an animation.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

/// One frame ready to draw.
class CameraFrame {
  CameraFrame(this.image, this.sequence);

  final ui.Image image;
  final int sequence;
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
  Stream<FeedEvent> start({required int rotation});

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
typedef _NextNative = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Int32, Int32, Int32, Int32, Pointer<Uint64>);
typedef _Next = int Function(Pointer<Void>, Pointer<Uint8>, int, int, int, int, Pointer<Uint64>);

const _library = 'libesca-camview-bridge.so';

/// Never convert more pixels than this across: the screen scales the image
/// up on the GPU for nothing, while every pixel converted here costs CPU.
const _maxWidth = 1280;

class _Start {
  _Start(this.reply, this.rotation);
  final SendPort reply;
  final int rotation;
}

/// The isolate. Frames go out only while the UI holds credits for them, so
/// when drawing falls behind, conversion stops instead of piling up frames
/// that would be thrown away.
Future<void> _frameLoop(_Start start) async {
  final out = start.reply;
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
  final next = lib.lookupFunction<_NextNative, _Next>('escv_next_rgba');

  final error = calloc<Uint8>(256);
  final camera = open(error.cast<Utf8>(), 256);
  if (camera == nullptr) {
    out.send(['error', error.cast<Utf8>().toDartString()]);
    calloc.free(error);
    commands.close();
    return;
  }
  calloc.free(error);

  final w = width(camera), h = height(camera);
  final sideways = start.rotation == 90 || start.rotation == 270;
  var outW = sideways ? h : w;
  var outH = sideways ? w : h;
  if (outW > _maxWidth) {
    outH = outH * _maxWidth ~/ outW;
    outW = _maxWidth;
  }
  out.send(['opened', w, h, outW, outH]);

  var credits = 2;
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

  final bytes = outW * outH * 4;
  final buffer = calloc<Uint8>(bytes);
  final sequence = calloc<Uint64>();
  while (running) {
    if (credits == 0) {
      wake = Completer<void>();
      await wake!.future;
      continue;
    }
    // A short timeout keeps a stop request from waiting on a camera that
    // has gone quiet.
    if (next(camera, buffer, outW, outH, start.rotation, 250, sequence) == 1) {
      credits--;
      out.send([
        'frame',
        sequence.value,
        TransferableTypedData.fromList([buffer.asTypedList(bytes)]),
      ]);
    }
    // Lets the command port deliver acks and stop between frames.
    await Future<void>.delayed(Duration.zero);
  }

  close(camera);
  calloc.free(buffer);
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
  Stream<FeedEvent> start({required int rotation}) {
    final events = _events = StreamController<FeedEvent>();
    final port = _port = ReceivePort();
    _closed = Completer<void>();
    var outW = 0, outH = 0;

    port.listen((message) async {
      if (message is SendPort) {
        _commands = message;
        return;
      }
      final m = message as List<Object?>;
      switch (m[0]) {
        case 'opened':
          outW = m[3]! as int;
          outH = m[4]! as int;
          events.add(FeedOpened(m[1]! as int, m[2]! as int));
        case 'frame':
          final pixels = (m[2]! as TransferableTypedData).materialize().asUint8List();
          final image = await _toImage(pixels, outW, outH);
          // The credit goes back only once the frame is an image: the
          // isolate never runs more than two frames ahead of the screen.
          _commands?.send('ack');
          if (!events.isClosed) events.add(FeedFrame(CameraFrame(image, m[1]! as int)));
        case 'error':
          events.add(FeedFailed(m[1]! as String));
          _finish();
        case 'closed':
          _finish();
      }
    });

    Isolate.spawn(_frameLoop, _Start(port.sendPort, rotation), debugName: 'camera')
        .then((isolate) => _isolate = isolate);
    return events.stream;
  }

  static Future<ui.Image> _toImage(Uint8List pixels, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
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
