import 'dart:io';

import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';

/// Wraps a CameraController and captures photo/video with attached GPS.
class CaptureSession {
  CaptureSession({required this.controller});

  final CameraController controller;

  Future<Position?> _currentPosition() async {
    try {
      final ok = await Geolocator.isLocationServiceEnabled();
      if (!ok) return null;
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<CapturedAsset> takePhoto() async {
    if (!controller.value.isInitialized) {
      throw StateError('camera not initialised');
    }
    final xfile = await controller.takePicture();
    final pos = await _currentPosition();
    return CapturedAsset(
      file: File(xfile.path),
      kind: 'photo',
      contentType: 'image/jpeg',
      position: pos,
      capturedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> startVideo() async {
    if (controller.value.isRecordingVideo) return;
    await controller.startVideoRecording();
  }

  Future<CapturedAsset> stopVideo() async {
    final xfile = await controller.stopVideoRecording();
    final pos = await _currentPosition();
    return CapturedAsset(
      file: File(xfile.path),
      kind: 'video',
      contentType: 'video/mp4',
      position: pos,
      capturedAt: DateTime.now().toUtc(),
    );
  }
}

class CapturedAsset {
  CapturedAsset({
    required this.file,
    required this.kind,
    required this.contentType,
    required this.position,
    required this.capturedAt,
  });

  final File file;
  final String kind;
  final String contentType;
  final Position? position;
  final DateTime capturedAt;
}
