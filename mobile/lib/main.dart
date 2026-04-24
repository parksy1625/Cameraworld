// camo — single-file Flutter app.
// Tab 1: upload personal photos/videos to the Cameraworld backend.
// Tab 2: view the 3D map built from those uploads (CesiumJS via WebView).
//
// All logic is intentionally contained in this one file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const CamoApp());

// ─── shared state ────────────────────────────────────────────────────────────

/// App-wide settings & active capture id. Single instance lives for the
/// lifetime of the app; both tabs read/write it.
///
/// `lastSuccessJobId` is bumped whenever the Upload tab sees a job reach
/// `succeeded`; the Map tab listens and reloads its WebView so the newly
/// accumulated 3D map replaces whatever was on screen.
class CamoState extends ChangeNotifier {
  static final instance = CamoState._();
  CamoState._();

  String apiBase = 'http://10.0.2.2:8000';
  String viewerBase = 'http://10.0.2.2:5173';
  String regionId = 'my-region';
  String userId = 'me';
  String? captureId;
  String? lastSuccessJobId;

  void markSuccess(String jobId) {
    if (lastSuccessJobId == jobId) return;
    lastSuccessJobId = jobId;
    notifyListeners();
  }

  static const _kApi = 'camo.apiBase';
  static const _kViewer = 'camo.viewerBase';
  static const _kRegion = 'camo.regionId';
  static const _kUser = 'camo.userId';
  static const _kCapture = 'camo.captureId';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    apiBase = p.getString(_kApi) ?? apiBase;
    viewerBase = p.getString(_kViewer) ?? viewerBase;
    regionId = p.getString(_kRegion) ?? regionId;
    userId = p.getString(_kUser) ?? userId;
    captureId = p.getString(_kCapture);
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kApi, apiBase);
    await p.setString(_kViewer, viewerBase);
    await p.setString(_kRegion, regionId);
    await p.setString(_kUser, userId);
    if (captureId != null) {
      await p.setString(_kCapture, captureId!);
    } else {
      await p.remove(_kCapture);
    }
    notifyListeners();
  }
}

// ─── API client ──────────────────────────────────────────────────────────────

class _Api {
  _Api(this.baseUrl);
  final String baseUrl;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<String> createCapture({required String regionId, required String userId}) async {
    final r = await http.post(
      _u('/captures'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'region_id': regionId, 'user_id': userId}),
    );
    _ok(r, 201);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  Future<(String storageKey, String uploadUrl)> presign({
    required String captureId,
    required String kind,
    required String contentType,
    required String filename,
  }) async {
    final r = await http.post(
      _u('/captures/$captureId/assets/presign'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'kind': kind, 'content_type': contentType, 'filename': filename}),
    );
    _ok(r, 200);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['storage_key'] as String, j['upload_url'] as String);
  }

  Future<void> putToPresigned(String uploadUrl, File file, String contentType) async {
    final r = await http.put(
      Uri.parse(uploadUrl),
      headers: {'content-type': contentType},
      body: await file.readAsBytes(),
    );
    _ok(r, 200, also: {204});
  }

  Future<void> registerAsset({
    required String captureId,
    required String kind,
    required String storageKey,
    required String contentType,
    required int sizeBytes,
    double? lat,
    double? lon,
    double? altitude,
    double? heading,
    DateTime? capturedAt,
  }) async {
    final r = await http.post(
      _u('/captures/$captureId/assets'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'kind': kind,
        'storage_key': storageKey,
        'content_type': contentType,
        'size_bytes': sizeBytes,
        'lat': lat,
        'lon': lon,
        'altitude': altitude,
        'heading': heading,
        'captured_at': capturedAt?.toIso8601String(),
      }),
    );
    _ok(r, 201);
  }

  Future<Map<String, dynamic>> submit(String captureId) async {
    final r = await http.post(_u('/captures/$captureId/submit'));
    _ok(r, 202);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> listJobs(String captureId) async {
    final r = await http.get(_u('/captures/$captureId/jobs'));
    _ok(r, 200);
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<List<dynamic>> listAssets(String captureId) async {
    final r = await http.get(_u('/captures/$captureId/assets'));
    _ok(r, 200);
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>?> reconstruction(String captureId) async {
    final r = await http.get(_u('/captures/$captureId/reconstruction'));
    if (r.statusCode == 404) return null;
    _ok(r, 200);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  void _ok(http.Response r, int expected, {Set<int> also = const {}}) {
    if (r.statusCode != expected && !also.contains(r.statusCode)) {
      throw HttpException('API ${r.statusCode}: ${r.body}', uri: r.request?.url);
    }
  }
}

Future<Position?> _tryPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return null;
    }
    return await Geolocator.getCurrentPosition();
  } catch (_) {
    return null;
  }
}

// ─── root app ────────────────────────────────────────────────────────────────

class CamoApp extends StatelessWidget {
  const CamoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'camo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const _CamoHome(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _CamoHome extends StatefulWidget {
  const _CamoHome();
  @override
  State<_CamoHome> createState() => _CamoHomeState();
}

class _CamoHomeState extends State<_CamoHome> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    CamoState.instance.load().then((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('camo'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.cloud_upload), text: 'Upload'),
              Tab(icon: Icon(Icons.public), text: '3D Map'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () async {
                await showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const _SettingsSheet(),
                );
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        body: const TabBarView(
          children: [_UploadTab(), _MapTab()],
        ),
      ),
    );
  }
}

// ─── settings sheet ──────────────────────────────────────────────────────────

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _api;
  late final TextEditingController _viewer;
  late final TextEditingController _region;
  late final TextEditingController _user;

  @override
  void initState() {
    super.initState();
    final s = CamoState.instance;
    _api = TextEditingController(text: s.apiBase);
    _viewer = TextEditingController(text: s.viewerBase);
    _region = TextEditingController(text: s.regionId);
    _user = TextEditingController(text: s.userId);
  }

  @override
  void dispose() {
    _api.dispose();
    _viewer.dispose();
    _region.dispose();
    _user.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(controller: _api, decoration: const InputDecoration(labelText: 'API base URL')),
          const SizedBox(height: 8),
          TextField(controller: _viewer, decoration: const InputDecoration(labelText: 'Viewer base URL')),
          const SizedBox(height: 8),
          TextField(controller: _region, decoration: const InputDecoration(labelText: 'Region id')),
          const SizedBox(height: 8),
          TextField(controller: _user, decoration: const InputDecoration(labelText: 'User id')),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final s = CamoState.instance;
                    s.captureId = null;
                    await s.save();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Reset capture'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    final s = CamoState.instance;
                    s.apiBase = _api.text.trim();
                    s.viewerBase = _viewer.text.trim();
                    s.regionId = _region.text.trim();
                    s.userId = _user.text.trim();
                    await s.save();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── tab 1 : upload ──────────────────────────────────────────────────────────

class _UploadTab extends StatefulWidget {
  const _UploadTab();
  @override
  State<_UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<_UploadTab> {
  final _picker = ImagePicker();
  final List<_UploadItem> _items = <_UploadItem>[];
  bool _busy = false;
  String _status = '';

  // Cumulative state fetched from backend
  int _accumulated = 0;
  Map<String, dynamic>? _activeJob;
  Timer? _jobPoll;

  _Api get _api => _Api(CamoState.instance.apiBase);

  @override
  void initState() {
    super.initState();
    _refreshAccumulated();
  }

  @override
  void dispose() {
    _jobPoll?.cancel();
    super.dispose();
  }

  Future<void> _refreshAccumulated() async {
    final id = CamoState.instance.captureId;
    if (id == null) {
      setState(() => _accumulated = 0);
      return;
    }
    try {
      final assets = await _api.listAssets(id);
      if (!mounted) return;
      setState(() => _accumulated = assets.length);
      await _refreshJob();
    } catch (_) {
      // Backend may be unreachable on first launch — ignore silently.
    }
  }

  Future<void> _refreshJob() async {
    final id = CamoState.instance.captureId;
    if (id == null) return;
    final jobs = await _api.listJobs(id);
    final latest = jobs.isNotEmpty ? jobs.first as Map<String, dynamic> : null;
    if (!mounted) return;
    setState(() => _activeJob = latest);

    if (latest != null) {
      final status = latest['status'] as String;
      if (status == 'queued' || status == 'running') {
        _schedulePoll();
      } else {
        _jobPoll?.cancel();
        if (status == 'succeeded') {
          CamoState.instance.markSuccess(latest['id'] as String);
        }
      }
    }
  }

  void _schedulePoll() {
    _jobPoll?.cancel();
    _jobPoll = Timer(const Duration(seconds: 3), () async {
      try {
        await _refreshJob();
      } catch (_) {
        _schedulePoll();
      }
    });
  }

  Future<String> _ensureCapture() async {
    final s = CamoState.instance;
    if (s.captureId != null) return s.captureId!;
    final id = await _api.createCapture(regionId: s.regionId, userId: s.userId);
    s.captureId = id;
    await s.save();
    return id;
  }

  Future<void> _pickPhotos() async {
    final picked = await _picker.pickMultiImage();
    if (picked.isEmpty) return;
    setState(() {
      for (final x in picked) {
        _items.add(_UploadItem(File(x.path), kind: 'photo', contentType: 'image/jpeg'));
      }
    });
  }

  Future<void> _pickFromCamera({required bool video}) async {
    final x = video
        ? await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 5))
        : await _picker.pickImage(source: ImageSource.camera);
    if (x == null) return;
    setState(() {
      _items.add(_UploadItem(
        File(x.path),
        kind: video ? 'video' : 'photo',
        contentType: video ? 'video/mp4' : 'image/jpeg',
      ));
    });
  }

  Future<void> _pickVideoFromGallery() async {
    final x = await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    setState(() {
      _items.add(_UploadItem(File(x.path), kind: 'video', contentType: 'video/mp4'));
    });
  }

  Future<void> _uploadAll() async {
    if (_items.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Preparing…';
    });
    try {
      final captureId = await _ensureCapture();
      final pos = await _tryPosition();
      for (var i = 0; i < _items.length; i++) {
        final it = _items[i];
        if (it.uploaded) continue;
        setState(() {
          _status = 'Uploading ${i + 1}/${_items.length}…';
          it.progress = 0.01;
        });
        final filename = it.file.uri.pathSegments.last;
        final (storageKey, uploadUrl) = await _api.presign(
          captureId: captureId,
          kind: it.kind,
          contentType: it.contentType,
          filename: filename,
        );
        await _api.putToPresigned(uploadUrl, it.file, it.contentType);
        await _api.registerAsset(
          captureId: captureId,
          kind: it.kind,
          storageKey: storageKey,
          contentType: it.contentType,
          sizeBytes: await it.file.length(),
          lat: pos?.latitude,
          lon: pos?.longitude,
          altitude: pos?.altitude,
          heading: pos?.heading,
          capturedAt: DateTime.now().toUtc(),
        );
        setState(() {
          it.uploaded = true;
          it.progress = 1.0;
        });
      }
      setState(() {
        _status = '업로드 완료';
        _items.removeWhere((i) => i.uploaded);
      });
      await _refreshAccumulated();
    } catch (e) {
      setState(() => _status = '에러: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final captureId = CamoState.instance.captureId;
    if (captureId == null) {
      setState(() => _status = '최소 5개 이상 업로드 후 다시 시도');
      return;
    }
    setState(() {
      _busy = true;
      _status = '3D 재구성 작업 생성 중…';
    });
    try {
      final job = await _api.submit(captureId);
      setState(() {
        _activeJob = job;
        _status = '작업 생성됨 — 누적 자산 $_accumulated개로 3D 지도 갱신';
      });
      _schedulePoll();
    } catch (e) {
      setState(() => _status = '제출 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final captureId = CamoState.instance.captureId;
    final uploadedCount = _items.where((i) => i.uploaded).length;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccumulationBanner(
            captureId: captureId,
            accumulated: _accumulated,
            queued: _items.length,
          ),
          const SizedBox(height: 8),
          _JobProgress(job: _activeJob),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickPhotos,
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick photos'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickFromCamera(video: false),
                icon: const Icon(Icons.photo_camera),
                label: const Text('Photo'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickFromCamera(video: true),
                icon: const Icon(Icons.videocam),
                label: const Text('Video'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickVideoFromGallery,
                icon: const Icon(Icons.video_library),
                label: const Text('Pick video'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text(
                      'Pick photos or videos from camera / gallery.\n'
                      'Walk around your subject for a full 360°.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                : ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      return ListTile(
                        leading: Icon(it.kind == 'video' ? Icons.videocam : Icons.image),
                        title: Text(it.file.uri.pathSegments.last),
                        subtitle: it.uploaded
                            ? const Text('uploaded')
                            : (it.progress > 0
                                ? LinearProgressIndicator(value: it.progress)
                                : const Text('pending')),
                        trailing: it.uploaded
                            ? const Icon(Icons.check, color: Colors.green)
                            : IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: _busy
                                    ? null
                                    : () => setState(() => _items.removeAt(i)),
                              ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Text(_status, style: const TextStyle(color: Colors.black87)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || _items.isEmpty ? null : _uploadAll,
                  icon: const Icon(Icons.cloud_upload),
                  label: Text('업로드 ${_items.length - uploadedCount}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _busy || captureId == null || _accumulated < 5
                      ? null
                      : _submit,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(_activeJob != null &&
                          (_activeJob!['status'] == 'succeeded' ||
                              _activeJob!['status'] == 'failed')
                      ? '3D 재생성'
                      : '3D 만들기'),
                ),
              ),
            ],
          ),
          if (_accumulated < 5 && captureId != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '누적 자산 5개 이상이면 3D 지도를 만들 수 있어요.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _UploadItem {
  _UploadItem(this.file, {required this.kind, required this.contentType});
  final File file;
  final String kind;
  final String contentType;
  bool uploaded = false;
  double progress = 0;
}

// ─── tab 2 : 3d map ──────────────────────────────────────────────────────────

class _MapTab extends StatefulWidget {
  const _MapTab();
  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> {
  WebViewController? _web;
  Map<String, dynamic>? _rec;
  Map<String, dynamic>? _latestJob;
  String _status = '';
  bool _loading = false;
  Timer? _poll;
  String? _loadedForSuccessId;

  _Api get _api => _Api(CamoState.instance.apiBase);

  @override
  void initState() {
    super.initState();
    CamoState.instance.addListener(_onStateChange);
    _refresh();
  }

  @override
  void dispose() {
    CamoState.instance.removeListener(_onStateChange);
    _poll?.cancel();
    super.dispose();
  }

  void _onStateChange() {
    final successId = CamoState.instance.lastSuccessJobId;
    if (successId != null && successId != _loadedForSuccessId) {
      _loadedForSuccessId = successId;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final captureId = CamoState.instance.captureId;
    if (captureId == null) {
      setState(() {
        _status = '업로드 탭에서 먼저 파일을 올려주세요.';
        _rec = null;
        _latestJob = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final jobs = await _api.listJobs(captureId);
      final latest = jobs.isNotEmpty ? jobs.first as Map<String, dynamic> : null;
      final rec = await _api.reconstruction(captureId);
      setState(() {
        _latestJob = latest;
        _rec = rec;
        if (rec != null) {
          _status = '누적 3D 지도 준비됨';
          _loadViewer(captureId);
        } else if (latest != null) {
          final stage = latest['stage'];
          _status = '작업 ${latest['status']}${stage != null ? ' · $stage' : ''}';
          _schedulePoll();
        } else {
          _status = '아직 생성된 3D 지도가 없어요.';
        }
      });
    } catch (e) {
      setState(() => _status = '에러: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(const Duration(seconds: 5), _refresh);
  }

  void _loadViewer(String captureId) {
    final base = CamoState.instance.viewerBase;
    // Cache-bust so the viewer re-fetches after each new reconstruction.
    final bust = DateTime.now().millisecondsSinceEpoch;
    final url = '$base/?capture=$captureId&v=$bust';
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..loadRequest(Uri.parse(url));
    setState(() => _web = controller);
  }

  @override
  Widget build(BuildContext context) {
    final captureId = CamoState.instance.captureId;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  captureId == null
                      ? _status
                      : '캡처 ${captureId.substring(0, 8)}… · $_status',
                  style: const TextStyle(color: Colors.black87),
                ),
              ),
              IconButton(
                icon: _loading
                    ? const SizedBox(
                        height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                onPressed: _loading ? null : _refresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: _rec == null || _web == null
              ? _NoMapPlaceholder(
                  job: _latestJob,
                  onRetry: _refresh,
                )
              : WebViewWidget(controller: _web!),
        ),
      ],
    );
  }
}

class _NoMapPlaceholder extends StatelessWidget {
  const _NoMapPlaceholder({required this.job, required this.onRetry});
  final Map<String, dynamic>? job;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final j = job;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public_off, size: 64, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              j == null
                  ? '아직 3D 지도가 없어요.\n업로드 탭에서 파일을 올리고 "3D 만들기"를 눌러주세요.'
                  : '3D 지도 생성 중…\n상태: ${j['status']}'
                      '${j['stage'] != null ? ' · ${j['stage']}' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('다시 확인'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── upload-tab helper widgets ───────────────────────────────────────────────

class _AccumulationBanner extends StatelessWidget {
  const _AccumulationBanner({
    required this.captureId,
    required this.accumulated,
    required this.queued,
  });
  final String? captureId;
  final int accumulated;
  final int queued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.layers, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              captureId == null
                  ? '첫 업로드를 올리면 캡처가 시작돼요.'
                  : '누적 자산 $accumulated개 · 대기중 $queued개\n'
                      '올릴수록 같은 캡처에 쌓여 3D 지도가 넓어져요.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

const List<(String id, String label)> _kStages = [
  ('extract_frames', '프레임 추출'),
  ('filter_quality', '품질 필터'),
  ('colmap_sfm', '카메라 정합 (SfM)'),
  ('colmap_mvs', '밀집 점군 (MVS)'),
  ('gaussian_splat', 'Gaussian Splats'),
  ('to_3dtiles', '3D 타일 변환'),
];

class _JobProgress extends StatelessWidget {
  const _JobProgress({required this.job});
  final Map<String, dynamic>? job;

  @override
  Widget build(BuildContext context) {
    final j = job;
    if (j == null) {
      return const SizedBox.shrink();
    }
    final status = j['status'] as String;
    final stage = j['stage'] as String?;
    final error = j['error'] as String?;

    if (status == 'succeeded') {
      return _banner(
        context,
        color: Colors.green.shade100,
        icon: Icons.check_circle,
        iconColor: Colors.green.shade700,
        title: '완료',
        subtitle: '3D 지도가 업데이트됐어요. 2번째 탭에서 확인하세요.',
      );
    }
    if (status == 'failed') {
      return _banner(
        context,
        color: Colors.red.shade50,
        icon: Icons.error_outline,
        iconColor: Colors.red.shade700,
        title: '실패',
        subtitle: error ?? '알 수 없는 오류',
      );
    }

    final currentIdx = _kStages.indexWhere((s) => s.$1 == stage);
    final isQueued = status == 'queued' || currentIdx < 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                isQueued
                    ? '대기 중…'
                    : '진행 중: ${_kStages[currentIdx].$2}  '
                        '(${currentIdx + 1}/${_kStages.length})',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < _kStages.length; i++)
                _StageChip(
                  label: _kStages[i].$2,
                  state: i < currentIdx
                      ? _StageState.done
                      : i == currentIdx
                          ? _StageState.active
                          : _StageState.pending,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _banner(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, color: iconColor)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _StageState { pending, active, done }

class _StageChip extends StatelessWidget {
  const _StageChip({required this.label, required this.state});
  final String label;
  final _StageState state;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (state) {
      _StageState.done => (Colors.green.shade600, Colors.white, Icons.check),
      _StageState.active => (Colors.blue.shade700, Colors.white, Icons.play_arrow),
      _StageState.pending => (Colors.grey.shade300, Colors.black54, Icons.circle_outlined),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: fg)),
        ],
      ),
    );
  }
}
