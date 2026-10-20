import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera_feed.dart';
import 'vision.dart';

enum CameraStatus { connecting, streaming, failed }

class CamviewController extends ChangeNotifier {
  CamviewController({
    required FrameSource frames,
    required VisionBackend vision,
    this.rotation = 0,
  })  : _frames = frames,
        _vision = vision {
    _detections = _vision.detections.listen(_onDetections, onError: (_) {});
    _openCamera();
    _startVision();
  }

  /// Boxes this many frames behind the picture are not drawn. The detector
  /// always trails by a frame or two -- that is expected -- but a service
  /// that stops must not leave its last boxes on screen as if still true.
  static const maxStaleFrames = 15;

  /// Ask the detector for every Nth frame: about seven inferences a second
  /// at 30 fps, which leaves a core for drawing.
  static const every = 3;

  final FrameSource _frames;
  final VisionBackend _vision;

  /// Clockwise, for a sensor mounted sideways. Fixing the mount is cheaper.
  final int rotation;

  late final StreamSubscription<DetectionSet> _detections;
  StreamSubscription<FeedEvent>? _feed;

  /// The newest frame. The picture and the boxes repaint from this alone, so
  /// thirty frames a second do not rebuild the rest of the screen.
  final frame = ValueNotifier<CameraFrame?>(null);

  CameraStatus _status = CameraStatus.connecting;
  String _cameraError = '';
  int _captureWidth = 0, _captureHeight = 0;

  bool _detecting = false;
  bool _visionWanted = true;
  bool _visionBusy = false;
  String _visionError = '';
  double _threshold = 0.5;
  DetectionSet? _latest;

  int _framesThisSecond = 0;
  DateTime _secondStarted = DateTime.now();
  double _fps = 0;
  Timer? _thresholdDebounce;

  CameraStatus get status => _status;
  String get cameraError => _cameraError;
  int get captureWidth => _captureWidth;
  int get captureHeight => _captureHeight;

  /// Width over height of the picture as shown, after rotation.
  double get aspectRatio {
    if (_captureWidth == 0 || _captureHeight == 0) return 16 / 9;
    final sideways = rotation == 90 || rotation == 270;
    return sideways ? _captureHeight / _captureWidth : _captureWidth / _captureHeight;
  }

  bool get detecting => _detecting;
  bool get visionWanted => _visionWanted;
  bool get visionBusy => _visionBusy;
  String get visionError => _visionError;
  double get threshold => _threshold;
  double get fps => _fps;
  double get inferenceMs => _latest?.inferenceMs ?? 0;

  /// The boxes worth drawing over the frame with [sequence]: recent enough,
  /// and above the threshold.
  List<Detection> detectionsFor(int sequence) {
    final set = _latest;
    if (!_detecting || set == null || set.frameSequence == 0) return const [];
    if (sequence > set.frameSequence + maxStaleFrames) return const [];
    return [
      for (final d in set.objects)
        if (d.score >= _threshold) d,
    ];
  }

  /// What is in view now, for the side panel.
  List<Detection> get visible => detectionsFor(frame.value?.sequence ?? 0);

  void _openCamera() {
    _status = CameraStatus.connecting;
    _cameraError = '';
    notifyListeners();

    _feed = _frames.start().listen((event) {
      switch (event) {
        case FeedOpened(:final width, :final height):
          _captureWidth = width;
          _captureHeight = height;
          notifyListeners();
        case FeedFrame(frame: final next):
          _onFrame(next);
        case FeedFailed(:final message):
          _status = CameraStatus.failed;
          _cameraError = message;
          notifyListeners();
      }
    });
  }

  void _onFrame(CameraFrame next) {
    final previous = frame.value;
    frame.value = next;
    previous?.planes.dispose();

    _framesThisSecond++;
    final now = DateTime.now();
    final elapsed = now.difference(_secondStarted).inMilliseconds;
    final first = _status != CameraStatus.streaming;
    _status = CameraStatus.streaming;
    // The rate is recomputed once a second, which is also the only time a
    // frame rebuilds anything beyond the picture.
    if (elapsed >= 1000 || first) {
      _fps = _framesThisSecond * 1000 / (elapsed == 0 ? 1 : elapsed);
      _framesThisSecond = 0;
      _secondStarted = now;
      notifyListeners();
    }
  }

  Future<void> retry() async {
    await _feed?.cancel();
    await _frames.stop();
    _openCamera();
  }

  Future<void> _startVision() async {
    _visionBusy = true;
    notifyListeners();
    try {
      await _vision.start(every: every, threshold: _threshold);
      _detecting = true;
      _visionError = '';
    } catch (e) {
      // Not fatal: video without boxes is a far better failure than no video.
      _detecting = false;
      _visionError = 'Dịch vụ nhận diện chưa sẵn sàng';
    }
    _visionBusy = false;
    notifyListeners();
  }

  Future<void> setDetection(bool on) async {
    _visionWanted = on;
    if (on && !_detecting) {
      await _startVision();
      return;
    }
    if (!on && _detecting) {
      _detecting = false;
      _latest = null;
      notifyListeners();
      try {
        await _vision.stop();
      } catch (_) {}
    }
  }

  void setThreshold(double value) {
    _threshold = value;
    notifyListeners();
    // The slider moves continuously; the service only needs where it stops.
    _thresholdDebounce?.cancel();
    _thresholdDebounce = Timer(const Duration(milliseconds: 250), () {
      if (_detecting) _vision.setThreshold(value).catchError((Object _) {});
    });
  }

  void _onDetections(DetectionSet set) {
    if (!_detecting) return;
    _latest = set;
    notifyListeners();
  }

  /// Releases the camera and the detector; the application exits after.
  Future<void> close() async {
    _thresholdDebounce?.cancel();
    if (_detecting) {
      try {
        await _vision.stop().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    await _feed?.cancel();
    await _frames.stop();
  }

  @override
  void dispose() {
    _thresholdDebounce?.cancel();
    _detections.cancel();
    _feed?.cancel();
    frame.value?.planes.dispose();
    frame.dispose();
    _vision.dispose();
    super.dispose();
  }
}
