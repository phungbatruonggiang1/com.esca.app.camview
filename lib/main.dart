import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'camera_feed.dart';
import 'camview_controller.dart';
import 'camview_screen.dart';
import 'kit/theme.dart';
import 'kit/widgets.dart';
import 'vision.dart';

void main() {
  // A sensor mounted sideways is set in appinfo.json's "env", which is
  // where esca-appmanagerd takes per-application settings from.
  final rotation = int.tryParse(Platform.environment['ESCA_CAMVIEW_ROTATE'] ?? '') ?? 0;

  final controller = CamviewController(
    frames: NativeFrameSource(),
    vision: DBusVisionBackend(),
    rotation: const {0, 90, 180, 270}.contains(rotation) ? rotation : 0,
  );
  runApp(CamviewApp(
    controller: controller,
    // The camera and the detector are let go before exiting, so the services
    // do not keep a client that is gone.
    onBack: () async {
      await controller.close();
      closeApplication();
    },
  ));
}

class CamviewApp extends StatelessWidget {
  const CamviewApp({super.key, required this.controller, required this.onBack});

  final CamviewController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera AI',
      debugShowCheckedModeBanner: false,
      theme: escaTheme(),
      home: CamviewScreen(controller: controller, onBack: onBack),
    );
  }
}
