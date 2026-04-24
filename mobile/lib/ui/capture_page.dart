import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../capture/capture_guide.dart';
import '../capture/capture_session.dart';
import '../main.dart';
import '../upload/api_client.dart';
import '../upload/uploader.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    required this.baseUrl,
    required this.regionId,
    required this.userId,
  });

  final String baseUrl;
  final String regionId;
  final String userId;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  CameraController? _controller;
  CaptureSession? _session;
  late final ApiClient _api;
  Uploader? _uploader;
  String? _captureId;
  final _guide = CaptureGuide();
  int _uploaded = 0;
  bool _busy = false;
  String? _status;
  StreamSubscription<MagnetometerEvent>? _magSub;

  @override
  void initState() {
    super.initState();
    _api = ApiClient(baseUrl: widget.baseUrl);
    _bootstrap();
    _magSub = magnetometerEvents.listen((e) {
      final headingDeg = (math.atan2(e.y, e.x) * 180 / math.pi + 360) % 360;
      _guide.markHeading(headingDeg);
    });
  }

  Future<void> _bootstrap() async {
    final camera = availableCamerasList.first;
    final controller = CameraController(camera, ResolutionPreset.high);
    await controller.initialize();

    final capture = await _api.createCapture(
      regionId: widget.regionId,
      userId: widget.userId,
    );

    if (!mounted) return;
    setState(() {
      _controller = controller;
      _session = CaptureSession(controller: controller);
      _captureId = capture['id'] as String;
      _uploader = Uploader(api: _api, captureId: _captureId!);
      _status = 'Capture ${_captureId!.substring(0, 8)} ready';
    });
  }

  Future<void> _snap() async {
    final session = _session;
    final uploader = _uploader;
    if (session == null || uploader == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Capturing…';
    });
    try {
      final asset = await session.takePhoto();
      setState(() => _status = 'Uploading…');
      await uploader.uploadFile(
        file: asset.file,
        kind: asset.kind,
        contentType: asset.contentType,
        lat: asset.position?.latitude,
        lon: asset.position?.longitude,
        altitude: asset.position?.altitude,
        heading: asset.position?.heading,
        capturedAt: asset.capturedAt,
      );
      setState(() {
        _uploaded += 1;
        _status = 'Uploaded $_uploaded';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_captureId == null) return;
    setState(() => _status = 'Submitting job…');
    try {
      final job = await _api.submit(_captureId!);
      if (!mounted) return;
      setState(() => _status = 'Queued job ${job['id']}');
    } catch (e) {
      setState(() => _status = 'Submit error: $e');
    }
  }

  @override
  void dispose() {
    _magSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Capture')),
      body: c == null || !c.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                CameraPreview(c),
                Positioned(
                  top: 16,
                  right: 16,
                  child: ListenableBuilder(
                    listenable: _guide,
                    builder: (_, __) => CaptureGuideRing(guide: _guide),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Column(
                    children: [
                      Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          _status ?? '',
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          FloatingActionButton(
                            heroTag: 'snap',
                            onPressed: _busy ? null : _snap,
                            child: const Icon(Icons.camera_alt),
                          ),
                          FloatingActionButton.extended(
                            heroTag: 'submit',
                            onPressed: _busy ? null : _submit,
                            icon: const Icon(Icons.cloud_upload),
                            label: const Text('Submit'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
