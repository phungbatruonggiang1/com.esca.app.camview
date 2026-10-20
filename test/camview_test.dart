import 'dart:async';
import 'dart:ui' as ui;

import 'package:esca_camview/camera_feed.dart';
import 'package:esca_camview/camview_controller.dart';
import 'package:esca_camview/main.dart';
import 'package:esca_camview/vision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the camera: frames are pushed by the test.
class FakeFrames implements FrameSource {
  StreamController<FeedEvent>? controller;
  int starts = 0;

  @override
  Stream<FeedEvent> start() {
    starts++;
    controller = StreamController<FeedEvent>();
    return controller!.stream;
  }

  @override
  Future<void> stop() async => controller?.close();

  void push(FeedEvent event) => controller!.add(event);
}

/// Stands in for esca-visiond.
class FakeVision implements VisionBackend {
  FakeVision({this.available = true});

  bool available;
  bool started = false;
  final sets = StreamController<DetectionSet>.broadcast();

  @override
  Future<void> start({required int every, required double threshold}) async {
    if (!available) throw StateError('no vision');
    started = true;
  }

  @override
  Future<void> setThreshold(double threshold) async {}

  @override
  Future<void> stop() async => started = false;

  @override
  Stream<DetectionSet> get detections => sets.stream;

  @override
  Future<void> dispose() => sets.close();
}

DetectionSet personAt(int frame, {double score = 0.9}) => DetectionSet(
      frameSequence: frame,
      inferenceMs: 66,
      objects: [
        Detection(
            label: 'person',
            classId: 0,
            score: score,
            left: 0.2,
            top: 0.2,
            right: 0.5,
            bottom: 0.9),
      ],
    );

void camTest(String description,
    Future<void> Function(WidgetTester, FakeFrames, FakeVision, CamviewController) body,
    {bool visionAvailable = true}) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1920, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final frames = FakeFrames();
    final vision = FakeVision(available: visionAvailable);
    final controller = CamviewController(frames: frames, vision: vision);
    final shader = await tester.runAsync(() => ui.FragmentProgram.fromAsset('shaders/i420.frag'));
    await tester.pumpWidget(CamviewApp(controller: controller, shader: shader!, onBack: () {}));
    await tester.pump();

    await body(tester, frames, vision, controller);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

Future<void> pushFrame(WidgetTester tester, FakeFrames frames, int sequence) async {
  // The packed I420 of a 64x36 frame: 16 texels wide, 54 rows.
  final planes = await tester.runAsync(() => createTestImage(width: 16, height: 54));
  frames.push(FeedFrame(CameraFrame(planes!, sequence, 64, 36)));
  await tester.pump();
}

void main() {
  camTest('shows the camera once frames arrive', (tester, frames, vision, c) async {
    expect(find.text('Đang kết nối camera…'), findsOneWidget);
    frames.push(FeedOpened(1280, 720));
    await pushFrame(tester, frames, 1);
    expect(c.status, CameraStatus.streaming);
    expect(c.frame.value?.sequence, 1);
    expect(find.text('Trực tiếp'), findsOneWidget);
  });

  camTest('a camera that will not open says why, and can be retried',
      (tester, frames, vision, c) async {
    frames.push(FeedFailed('no cameras (is esca-camerad running?)'));
    await tester.pump();
    expect(find.text('Không mở được camera'), findsOneWidget);
    expect(find.text('no cameras (is esca-camerad running?)'), findsOneWidget);

    await tester.tap(find.text('Thử lại'));
    // retry() releases the old feed before opening a new one, and closing a
    // stream completes outside the test's fake clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(frames.starts, 2);
    expect(find.text('Đang kết nối camera…'), findsOneWidget);
  });

  camTest('boxes are listed while fresh and dropped once stale', (tester, frames, vision, c) async {
    frames.push(FeedOpened(1280, 720));
    await pushFrame(tester, frames, 100);
    vision.sets.add(personAt(99));
    await tester.pump();
    expect(c.visible, hasLength(1));
    expect(find.text('person'), findsOneWidget);

    // Sixteen frames on, the detector has said nothing new: no ghosts.
    await pushFrame(tester, frames, 116);
    expect(c.visible, isEmpty);
  });

  camTest('boxes below the threshold are not shown', (tester, frames, vision, c) async {
    frames.push(FeedOpened(1280, 720));
    await pushFrame(tester, frames, 10);
    vision.sets.add(personAt(10, score: 0.4));
    await tester.pump();
    expect(c.visible, isEmpty);
  });

  camTest('video plays without the detector', (tester, frames, vision, c) async {
    frames.push(FeedOpened(1280, 720));
    await pushFrame(tester, frames, 1);
    expect(c.status, CameraStatus.streaming);
    expect(c.detecting, isFalse);
    expect(find.text('Dịch vụ nhận diện chưa sẵn sàng'), findsOneWidget);
  }, visionAvailable: false);

  camTest('detection can be switched off', (tester, frames, vision, c) async {
    expect(vision.started, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(vision.started, isFalse);
    expect(find.text('Đã tắt — chỉ hiển thị hình'), findsOneWidget);
  });
}
