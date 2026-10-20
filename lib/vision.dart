// esca-visiond as this application sees it: start it, tune it, and take the
// boxes it publishes. vn.sparc.esca.Vision1 on the system bus.

import 'dart:async';

import 'package:dbus/dbus.dart';

class Detection {
  const Detection({
    required this.label,
    required this.classId,
    required this.score,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String label;
  final int classId;
  final double score;

  /// Normalised to the unrotated frame: 0 is the left or top edge, 1 the
  /// right or bottom, whatever the capture resolution.
  final double left, top, right, bottom;
}

class DetectionSet {
  const DetectionSet(
      {required this.frameSequence, required this.inferenceMs, required this.objects});

  /// The camera frame these boxes describe. Matched against the frame on
  /// screen to tell how far behind they are.
  final int frameSequence;
  final double inferenceMs;
  final List<Detection> objects;
}

abstract interface class VisionBackend {
  /// Throws when the service is not there; the caller shows video alone.
  Future<void> start({required int every, required double threshold});
  Future<void> setThreshold(double threshold);
  Future<void> stop();
  Stream<DetectionSet> get detections;
  Future<void> dispose();
}

class DBusVisionBackend implements VisionBackend {
  DBusVisionBackend() : _client = DBusClient.system() {
    _object =
        DBusRemoteObject(_client, name: _interface, path: DBusObjectPath('/vn/sparc/esca/Vision1'));
  }

  static const _interface = 'vn.sparc.esca.Vision1';

  // The system bus, explicitly: under Weston the default is the session bus.
  final DBusClient _client;
  late final DBusRemoteObject _object;

  Future<void> _call(String method, [List<DBusValue> args = const []]) async {
    final reply =
        await _object.callMethod(_interface, method, args, replySignature: DBusSignature('i'));
    if (reply.values.first.asInt32() != 0) {
      final error = await _object.callMethod(_interface, 'GetErrorMessage', const [],
          replySignature: DBusSignature('s'));
      throw StateError(error.values.first.asString());
    }
  }

  @override
  Future<void> start({required int every, required double threshold}) async {
    await _call('Start');
    await _call('SetEvery', [DBusUint32(every)]);
    await _call('SetThreshold', [DBusDouble(threshold)]);
  }

  @override
  Future<void> setThreshold(double threshold) => _call('SetThreshold', [DBusDouble(threshold)]);

  @override
  Future<void> stop() => _call('Stop');

  @override
  Stream<DetectionSet> get detections => DBusRemoteObjectSignalStream(
        object: _object,
        interface: _interface,
        name: 'Detections',
        signature: DBusSignature('ttda(sqddddd)'),
      ).map((s) => DetectionSet(
            frameSequence: s.values[0].asUint64(),
            inferenceMs: s.values[2].asDouble(),
            objects: [
              for (final entry in s.values[3].asArray())
                () {
                  final f = (entry as DBusStruct).children;
                  return Detection(
                    label: f[0].asString(),
                    classId: f[1].asUint16(),
                    score: f[2].asDouble(),
                    left: f[3].asDouble(),
                    top: f[4].asDouble(),
                    right: f[5].asDouble(),
                    bottom: f[6].asDouble(),
                  );
                }(),
            ],
          ));

  @override
  Future<void> dispose() => _client.close();
}
