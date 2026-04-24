import 'package:flutter/material.dart';

import '../main.dart';
import 'capture_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _baseUrlCtrl = TextEditingController(text: 'http://10.0.2.2:8000');
  final _regionCtrl = TextEditingController(text: 'demo-park');
  final _userCtrl = TextEditingController(text: 'demo-user');

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _regionCtrl.dispose();
    _userCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasCamera = availableCamerasList.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Cameraworld')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _baseUrlCtrl,
              decoration: const InputDecoration(labelText: 'API base URL'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _regionCtrl,
              decoration: const InputDecoration(labelText: 'Region id'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userCtrl,
              decoration: const InputDecoration(labelText: 'User id'),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: hasCamera
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CapturePage(
                            baseUrl: _baseUrlCtrl.text,
                            regionId: _regionCtrl.text,
                            userId: _userCtrl.text,
                          ),
                        ),
                      )
                  : null,
              icon: const Icon(Icons.videocam),
              label: Text(hasCamera ? 'Start capture' : 'No camera detected'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Walk a full 360° arc around the subject, keeping 70% overlap '
              'between frames. The guide ring shows coverage.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
