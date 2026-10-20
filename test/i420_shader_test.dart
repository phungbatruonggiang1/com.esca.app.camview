// shaders/i420.frag against the CPU conversion libesca-ui used: the bytes
// go in exactly as libesca-camview-bridge packs them, and every pixel that
// comes out must match BT.601 within rounding.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 16, h = 8;

/// A frame where every pixel differs: Y ramps across and down, U and V vary
/// per 2x2 block, so a byte read from the wrong lane, row or plane shows.
Uint8List packedI420() {
  final bytes = Uint8List(w * h * 3 ~/ 2);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      bytes[y * w + x] = 40 + x * 9 + y * 7;
    }
  }
  final u = w * h, v = u + w * h ~/ 4;
  for (var y = 0; y < h ~/ 2; y++) {
    for (var x = 0; x < w ~/ 2; x++) {
      bytes[u + y * (w ~/ 2) + x] = 60 + x * 17;
      bytes[v + y * (w ~/ 2) + x] = 200 - y * 23 - x * 5;
    }
  }
  return bytes;
}

/// libesca-ui's integer BT.601, the reference.
List<int> reference(Uint8List f, int sx, int sy) {
  final y = f[sy * w + sx];
  final c = (sy ~/ 2) * (w ~/ 2) + sx ~/ 2;
  final u = f[w * h + c] - 128, v = f[w * h + w * h ~/ 4 + c] - 128;
  int clamp(int x) => x.clamp(0, 255);
  return [
    clamp(y + ((91881 * v) >> 16)),
    clamp(y - ((22554 * u + 46802 * v) >> 16)),
    clamp(y + ((116130 * u) >> 16)),
  ];
}

Future<ByteData> render(ui.FragmentProgram program, ui.Image planes, int rotation) async {
  final sideways = rotation == 90 || rotation == 270;
  final outW = sideways ? h : w, outH = sideways ? w : h;
  final shader = program.fragmentShader()
    ..setFloat(0, outW.toDouble())
    ..setFloat(1, outH.toDouble())
    ..setFloat(2, w.toDouble())
    ..setFloat(3, h.toDouble())
    ..setFloat(4, rotation / 90)
    ..setImageSampler(0, planes, filterQuality: FilterQuality.none);
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()), Paint()..shader = shader);
  final image = await recorder.endRecording().toImage(outW, outH);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

void main() {
  testWidgets('the shader converts and rotates like libesca-ui', (tester) async {
    await tester.runAsync(() async {
      final program = await ui.FragmentProgram.fromAsset('shaders/i420.frag');
      final frame = packedI420();
      final buffer = await ui.ImmutableBuffer.fromUint8List(frame);
      final descriptor = ui.ImageDescriptor.raw(buffer,
          width: w ~/ 4, height: h * 3 ~/ 2, pixelFormat: ui.PixelFormat.rgba8888);
      final planes = (await (await descriptor.instantiateCodec()).getNextFrame()).image;

      for (final rotation in [0, 90, 180, 270]) {
        final out = await render(program, planes, rotation);
        final sideways = rotation == 90 || rotation == 270;
        final outW = sideways ? h : w, outH = sideways ? w : h;
        var worst = 0;
        for (var dy = 0; dy < outH; dy++) {
          for (var dx = 0; dx < outW; dx++) {
            // The bridge's old mapping from a rotated pixel to the source.
            final (sx, sy) = switch (rotation) {
              90 => (dy, h - 1 - dx),
              180 => (w - 1 - dx, h - 1 - dy),
              270 => (w - 1 - dy, dx),
              _ => (dx, dy),
            };
            final want = reference(frame, sx, sy);
            for (var ch = 0; ch < 3; ch++) {
              final got = out.getUint8((dy * outW + dx) * 4 + ch);
              final diff = (got - want[ch]).abs();
              if (diff > worst) worst = diff;
            }
          }
        }
        expect(worst, lessThanOrEqualTo(2),
            reason: 'rotation $rotation, worst channel error $worst');
      }
    });
  });
}
