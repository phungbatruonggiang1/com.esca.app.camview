import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'camera_feed.dart';
import 'camview_controller.dart';
import 'kit/theme.dart';
import 'kit/widgets.dart';
import 'vision.dart';

class CamviewScreen extends StatelessWidget {
  const CamviewScreen({
    super.key,
    required this.controller,
    required this.shader,
    required this.onBack,
  });

  final CamviewController controller;

  /// shaders/i420.frag, which turns a frame's packed I420 into colour.
  final ui.FragmentProgram shader;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: EscaBackground(
        tint: EscaColors.info,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 32, 40, 32),
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EscaTopBar(
                    icon: Icons.videocam_rounded,
                    color: EscaColors.info,
                    title: 'Camera AI',
                    subtitle: controller.captureWidth == 0
                        ? 'IMX219 camera · on-board object detection'
                        : 'IMX219 camera · ${controller.captureWidth}×${controller.captureHeight}'
                            ' · on-board object detection',
                    onBack: onBack,
                    trailing: [
                      if (controller.status == CameraStatus.streaming)
                        // Static: a pulse would make the engine draw at 60 Hz for a picture
                        // that changes 30 times a second.
                        const StatusPill(label: 'Live', color: EscaColors.bad),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _Viewport(controller: controller, shader: shader)),
                        const SizedBox(width: 24),
                        SizedBox(width: 380, child: _SidePanel(controller: controller)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture, letterboxed into whatever room is left, with the boxes over
/// it in the same coordinate space.
class _Viewport extends StatelessWidget {
  const _Viewport({required this.controller, required this.shader});

  final CamviewController controller;
  final ui.FragmentProgram shader;

  @override
  Widget build(BuildContext context) {
    // Top-aligned, so the picture lines up with the panel beside it.
    return Align(
      alignment: Alignment.topCenter,
      child: AspectRatio(
        aspectRatio: controller.aspectRatio,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(EscaRadius.card),
            border: Border.all(color: EscaColors.border, width: 1.2),
            color: Colors.black,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(EscaRadius.card - 1),
            child: switch (controller.status) {
              CameraStatus.streaming => _Video(controller: controller, shader: shader),
              CameraStatus.connecting => const _Placeholder(
                  icon: Icons.videocam_outlined,
                  title: 'Connecting to the camera…',
                  busy: true,
                ),
              CameraStatus.failed => _Placeholder(
                  icon: Icons.videocam_off_outlined,
                  title: 'Cannot open the camera',
                  detail: controller.cameraError,
                  action: FilledButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                    style: FilledButton.styleFrom(
                      backgroundColor: EscaColors.info,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
            },
          ),
        ),
      ),
    );
  }
}

class _Video extends StatelessWidget {
  const _Video({required this.controller, required this.shader});

  final CamviewController controller;
  final ui.FragmentProgram shader;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(painter: _FramePainter(controller, shader.fragmentShader())),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _BoxesPainter(controller, rotation: controller.rotation),
          ),
        ),
        Positioned(
          left: 16,
          bottom: 16,
          child: ValueListenableBuilder<CameraFrame?>(
            valueListenable: controller.frame,
            builder: (context, frame, _) => _GlassChip(
              icon: Icons.tag_rounded,
              label: 'frame ${frame?.sequence ?? 0}',
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(EscaRadius.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white70),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    this.detail = '',
    this.busy = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: EscaColors.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 56,
                height: 56,
                child: CircularProgressIndicator(strokeWidth: 3, color: EscaColors.info),
              )
            else
              Icon(icon, size: 64, color: EscaColors.textFaint),
            const SizedBox(height: 24),
            Text(title, style: text.headlineSmall),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(detail, style: text.bodyMedium?.copyWith(color: EscaColors.textDim)),
            ],
            if (action != null) ...[const SizedBox(height: 28), action!],
          ],
        ),
      ),
    );
  }
}

/// The picture: the newest frame's I420 through shaders/i420.frag, which
/// converts and rotates it on the GPU. Repaints with every frame and nothing
/// else.
class _FramePainter extends CustomPainter {
  _FramePainter(this.controller, this.shader) : super(repaint: controller.frame);

  final CamviewController controller;
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = controller.frame.value;
    if (frame == null) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, frame.width.toDouble())
      ..setFloat(3, frame.height.toDouble())
      ..setFloat(4, controller.rotation / 90)
      // Nearest: every texel is four unrelated bytes, and blending two of
      // them would mix luma from different pixels.
      ..setImageSampler(0, frame.planes, filterQuality: FilterQuality.none);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.shader != shader;
}

Color classColor(int classId) => EscaColors.classes[classId % EscaColors.classes.length];

/// Detection boxes, in the picture's own coordinates. Repaints with every
/// frame, because whether a box is still fresh depends on which frame is up.
class _BoxesPainter extends CustomPainter {
  _BoxesPainter(this.controller, {required this.rotation})
      : super(repaint: Listenable.merge([controller.frame, controller]));

  final CamviewController controller;
  final int rotation;

  /// Normalised corners in the unrotated frame, turned the way the pixels
  /// were turned.
  Rect _map(Detection d, Size size) {
    var (l, t, r, b) = (d.left, d.top, d.right, d.bottom);
    (l, t, r, b) = switch (rotation) {
      90 => (1 - b, l, 1 - t, r),
      180 => (1 - r, 1 - b, 1 - l, 1 - t),
      270 => (t, 1 - r, b, 1 - l),
      _ => (l, t, r, b),
    };
    return Rect.fromLTRB(
      l.clamp(0.0, 1.0) * size.width,
      t.clamp(0.0, 1.0) * size.height,
      r.clamp(0.0, 1.0) * size.width,
      b.clamp(0.0, 1.0) * size.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final frame = controller.frame.value;
    if (frame == null) return;

    for (final d in controller.detectionsFor(frame.sequence)) {
      final box = _map(d, size);
      if (box.width <= 1 || box.height <= 1) continue;
      final color = classColor(d.classId);
      final rrect = RRect.fromRectAndRadius(box, const Radius.circular(10));

      canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: 0.10));
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      final label = TextPainter(
        text: TextSpan(
          text: '${d.label}  ${(d.score * 100).round()}%',
          style: const TextStyle(
            color: Color(0xFF071018),
            fontSize: 14,
            fontWeight: FontWeight.w700,
            fontFamily: kEscaFontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Above the box, or inside it when the box is at the top edge; pulled
      // back in from the right so a long label stays whole.
      final w = label.width + 16, h = label.height + 8;
      var y = box.top - h - 6;
      if (y < 4) y = box.top + 6;
      final x = math.max(4.0, math.min(box.left, size.width - w - 4));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(8)),
        Paint()..color = color,
      );
      label.paint(canvas, Offset(x + 8, y + 4));
    }
  }

  @override
  bool shouldRepaint(_BoxesPainter old) => old.rotation != rotation;
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.controller});

  final CamviewController controller;

  @override
  Widget build(BuildContext context) {
    final streaming = controller.status == CameraStatus.streaming;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: MetricTile(
                label: 'Frame rate',
                icon: Icons.speed_rounded,
                value: streaming ? controller.fps.toStringAsFixed(0) : '—',
                unit: 'fps',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: MetricTile(
                label: 'Inference',
                icon: Icons.memory_rounded,
                value: controller.detecting && controller.inferenceMs > 0
                    ? controller.inferenceMs.toStringAsFixed(0)
                    : '—',
                unit: 'ms',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _DetectionControls(controller: controller),
        const SizedBox(height: 16),
        Expanded(child: _ObjectsCard(controller: controller)),
      ],
    );
  }
}

class _DetectionControls extends StatelessWidget {
  const _DetectionControls({required this.controller});

  final CamviewController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (status, color) = controller.visionBusy
        ? ('Starting…', EscaColors.warn)
        : controller.detecting
            ? ('Running · every ${CamviewController.every} frames', EscaColors.good)
            : controller.visionWanted && controller.visionError.isNotEmpty
                ? (controller.visionError, EscaColors.warn)
                : ('Off — video only', EscaColors.textFaint);

    return EscaCard(
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.center_focus_strong_rounded, size: 20, color: EscaColors.info),
              const SizedBox(width: 10),
              Expanded(child: Text('Object detection', style: text.titleSmall)),
              Switch(
                value: controller.visionWanted,
                onChanged: controller.visionBusy ? null : controller.setDetection,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              PulseDot(color: color, pulsing: false, size: 7),
              const SizedBox(width: 4),
              Expanded(
                child: Text(status,
                    style: text.bodySmall?.copyWith(color: color), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text('Confidence threshold',
                  style: text.bodyMedium?.copyWith(color: EscaColors.textDim)),
              const Spacer(),
              Text('${(controller.threshold * 100).round()}%', style: text.titleSmall),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: EscaColors.info,
              thumbColor: EscaColors.info,
              overlayColor: EscaColors.info.withValues(alpha: 0.16),
            ),
            child: Slider(
              value: controller.threshold,
              min: 0.2,
              max: 0.9,
              divisions: 14,
              onChanged: controller.detecting ? controller.setThreshold : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// What is in view, grouped by kind, strongest first.
class _ObjectsCard extends StatelessWidget {
  const _ObjectsCard({required this.controller});

  final CamviewController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final groups = <String, List<Detection>>{};
    for (final d in controller.visible) {
      groups.putIfAbsent(d.label, () => []).add(d);
    }
    final rows = groups.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));

    return EscaCard(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Objects in view', style: text.titleSmall),
              const Spacer(),
              Text('${controller.visible.length}',
                  style: text.titleSmall?.copyWith(
                    color: EscaColors.info,
                  )),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      controller.detecting
                          ? 'Nothing detected yet'
                          : 'Turn detection on to see objects',
                      style: text.bodyMedium?.copyWith(color: EscaColors.textFaint),
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    separatorBuilder: (context, i) =>
                        const Divider(height: 1, color: EscaColors.border),
                    itemBuilder: (context, i) {
                      final entry = rows[i];
                      final best = entry.value.map((d) => d.score).reduce(math.max);
                      final color = classColor(entry.value.first.classId);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(entry.key, style: text.bodyLarge)),
                            if (entry.value.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Text('×${entry.value.length}', style: text.titleSmall),
                              ),
                            Text('${(best * 100).round()}%',
                                style: text.bodyMedium?.copyWith(color: EscaColors.textDim)),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
