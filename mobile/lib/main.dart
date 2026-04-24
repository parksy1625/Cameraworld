import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'ui/home_page.dart';

List<CameraDescription> availableCamerasList = <CameraDescription>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    availableCamerasList = await availableCameras();
  } catch (_) {
    // availableCameras throws on unsupported platforms (e.g. desktop test runs).
    availableCamerasList = <CameraDescription>[];
  }
  runApp(const CameraworldApp());
}

class CameraworldApp extends StatelessWidget {
  const CameraworldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cameraworld',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
      ),
      home: const HomePage(),
    );
  }
}
