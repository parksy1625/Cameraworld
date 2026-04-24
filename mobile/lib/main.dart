// camo — single-file Flutter app.
// Tab 1: upload personal photos/videos to the Cameraworld backend.
// Tab 2: view the 3D map built from those uploads (CesiumJS via WebView).
//
// All logic is intentionally contained in this one file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:exif/exif.dart' as exif_pkg;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:onnxruntime/onnxruntime.dart' as ort;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // ONNX Runtime requires a one-time environment init before any session load.
  try {
    ort.OrtEnv.instance.init();
  } catch (_) {
    // Safe to ignore — subsequent calls bail gracefully if init fails.
  }
  runApp(const CamoApp());
}

// Spatial arrangement used by the local point-cloud renderer.
// * outdoor — camera circles the subject; tiles face inward.
// * indoor  — viewer at the center; tiles wrap around a cylinder facing out.
enum _LayoutMode { outdoor, indoor }

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
  // Default to local mode so the app works out of the box on a phone
  // with no backend reachable. Flip in Settings to use the real API.
  bool localMode = true;
  // Controls how the local engine arranges per-image tiles in 3D space.
  // outdoor → walk-around-subject ring; indoor → panorama cylinder.
  _LayoutMode layoutMode = _LayoutMode.outdoor;

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
  static const _kLocal = 'camo.localMode';
  static const _kLayout = 'camo.layoutMode';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    apiBase = p.getString(_kApi) ?? apiBase;
    viewerBase = p.getString(_kViewer) ?? viewerBase;
    regionId = p.getString(_kRegion) ?? regionId;
    userId = p.getString(_kUser) ?? userId;
    captureId = p.getString(_kCapture);
    localMode = p.getBool(_kLocal) ?? true;
    final layout = p.getString(_kLayout);
    layoutMode = layout == 'indoor' ? _LayoutMode.indoor : _LayoutMode.outdoor;
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kApi, apiBase);
    await p.setString(_kViewer, viewerBase);
    await p.setString(_kRegion, regionId);
    await p.setString(_kUser, userId);
    await p.setBool(_kLocal, localMode);
    await p.setString(_kLayout, layoutMode == _LayoutMode.indoor ? 'indoor' : 'outdoor');
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

// ─── local-mode backend ──────────────────────────────────────────────────────
//
// A fully offline drop-in that mimics the shape of the REST API so the app can
// run on a phone with no backend reachable. Assets are copied into the app's
// documents directory. Each `submit` triggers real work per stage:
// extract/filter (image decode + blur), depth estimation, per-image point
// cloud generation, and accumulation. Stage strings mirror the server
// pipeline so Tab 1's progress chips stay meaningful.

// ─── depth engine ────────────────────────────────────────────────────────────
//
// Classical on-device pseudo-depth: combines luminance + Sobel edge energy
// to approximate per-pixel depth, normalized to [0, 1]. It's not semantic
// (a bright but far object will look close), but it produces real 3D points
// with correct color that accumulate into a coherent cloud as the user
// adds more photos. Swap in any depth-estimation model later — the
// the rest of the pipeline only cares about the depth map + rgb buffers.

class _DepthMap {
  _DepthMap(this.w, this.h, this.depth, this.rgb);
  final int w;
  final int h;
  final Float32List depth; // length w*h, in [0, 1]
  final Uint8List rgb;     // length w*h*3
}

// ─── model downloader ────────────────────────────────────────────────────────
//
// The APK ships with Depth Anything v2 Small (~25MB) — good quality, small
// size. On first launch we try to fetch the Base model (~100MB) in the
// background and cache it under the app's documents dir. If that succeeds
// the engine picker upgrades automatically on the next submit.
//
// Network failure is non-fatal: we keep the Small model. A re-try is
// available from the Settings sheet.

enum _ModelDownloadState { idle, downloading, done, failed }

class _ModelDownloader extends ChangeNotifier {
  static final instance = _ModelDownloader._();
  _ModelDownloader._();

  // Candidate URLs for Depth Anything v2 Base ONNX. First hit wins.
  // Order: user-pinned releases first (most reliable), then community
  // HuggingFace mirrors. Failures cascade to the next entry.
  static const List<String> baseUrls = [
    // User-pinned fallback — upload `depth_anything_v2_base.onnx` to a
    // release named `models` in your own repo for a guaranteed path.
    'https://github.com/parksy1625/Cameraworld/releases/download/models/depth_anything_v2_base.onnx',
    // HuggingFace onnx-community — these repos host exported ONNX weights
    // for the full Depth Anything v2 lineup.
    'https://huggingface.co/onnx-community/depth-anything-v2-base-hf/resolve/main/onnx/model.onnx',
    'https://huggingface.co/onnx-community/depth-anything-v2-base/resolve/main/onnx/model.onnx',
    // Quantized fallback (smaller, slightly lower quality).
    'https://huggingface.co/onnx-community/depth-anything-v2-base-hf/resolve/main/onnx/model_quantized.onnx',
  ];

  _ModelDownloadState state = _ModelDownloadState.idle;
  double progress = 0;
  String? error;

  static Future<File> baseFile() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(p.join(dir.path, 'depth_anything_v2_base.onnx'));
  }

  Future<void> ensureDownloaded({bool force = false}) async {
    if (state == _ModelDownloadState.downloading) return;
    final f = await baseFile();
    if (!force && f.existsSync() && await f.length() > 1024) {
      state = _ModelDownloadState.done;
      progress = 1.0;
      notifyListeners();
      return;
    }
    state = _ModelDownloadState.downloading;
    progress = 0;
    error = null;
    notifyListeners();

    for (final url in baseUrls) {
      try {
        debugPrint('camo: trying base model from $url');
        final req = http.Request('GET', Uri.parse(url));
        final resp = await http.Client().send(req).timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          debugPrint('camo: $url → ${resp.statusCode}');
          continue;
        }
        final total = resp.contentLength ?? 0;
        var received = 0;
        final tmp = File('${f.path}.part');
        final sink = tmp.openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            progress = received / total;
            notifyListeners();
          }
        }
        await sink.close();
        await tmp.rename(f.path);
        state = _ModelDownloadState.done;
        progress = 1.0;
        notifyListeners();
        debugPrint('camo: base model saved (${received ~/ 1024} KB)');
        return;
      } catch (e) {
        debugPrint('camo: base download failed from $url: $e');
      }
    }

    state = _ModelDownloadState.failed;
    error = 'All mirrors failed';
    notifyListeners();
  }

  Future<void> deleteCache() async {
    final f = await baseFile();
    if (f.existsSync()) await f.delete();
    state = _ModelDownloadState.idle;
    progress = 0;
    notifyListeners();
  }
}

abstract class _DepthEngine {
  /// Produce a depth map + downsampled rgb from an image file.
  Future<_DepthMap?> analyzeFile(String path, {int target = 128});

  /// Human-readable name for UI/status.
  String get name;

  /// Pick the best available engine. Priority:
  ///   1. Depth Anything v2 Base ONNX at-runtime file (downloaded on first launch).
  ///   2. Depth Anything v2 Small ONNX bundled asset.
  ///   3. Classical pseudo-depth — always available.
  /// Always succeeds so callers don't need to null-check.
  static Future<_DepthEngine> forCurrent() async {
    // 1) Downloaded Base
    final baseFile = await _ModelDownloader.baseFile();
    if (baseFile.existsSync() && await baseFile.length() > 1024) {
      final e = await _OnnxDepthEngine.fromFile(baseFile, label: 'depth-anything-v2-base');
      if (e != null) return e;
    }
    // 2) Bundled Small
    final small = await _OnnxDepthEngine.fromAsset(
      'assets/models/depth_anything_v2_small.onnx',
      label: 'depth-anything-v2-small',
    );
    if (small != null) return small;
    // 3) Classical fallback
    return const _ClassicalEngine();
  }
}

class _ClassicalEngine implements _DepthEngine {
  const _ClassicalEngine();
  @override
  String get name => 'classical';
  @override
  Future<_DepthMap?> analyzeFile(String path, {int target = 128}) async {
    return compute(_depthIsolate, _DepthJob(path, target));
  }
}

class _DepthJob {
  const _DepthJob(this.path, this.target);
  final String path;
  final int target;
}

// ── ONNX depth engine (Depth Anything v2, etc.) ───────────────────────────
// Loads any ONNX depth model whose input is NCHW RGB and output is a single
// channel depth map. The app ships with Depth Anything v2 Small and the
// runtime downloader fetches Base at first launch. ONNX (as opposed to
// TFLite) lets us use the widely-available onnx-community conversions of
// these models without fragile format juggling.
class _OnnxDepthEngine implements _DepthEngine {
  _OnnxDepthEngine._(this._session, this._inDim, this.name);
  final ort.OrtSession _session;
  final int _inDim;
  @override
  final String name;

  static Future<_OnnxDepthEngine?> fromAsset(String asset, {required String label}) async {
    try {
      final raw = await rootBundle.load(asset);
      return _make(raw.buffer.asUint8List(), label);
    } catch (e) {
      debugPrint('camo: $label asset not loadable ($e)');
      return null;
    }
  }

  static Future<_OnnxDepthEngine?> fromFile(File file, {required String label}) async {
    try {
      final bytes = await file.readAsBytes();
      return _make(bytes, label);
    } catch (e) {
      debugPrint('camo: $label file not loadable ($e)');
      return null;
    }
  }

  static _OnnxDepthEngine? _make(Uint8List bytes, String label) {
    try {
      final opts = ort.OrtSessionOptions();
      final session = ort.OrtSession.fromBuffer(bytes, opts);
      // Depth Anything v2 uses 518 as the canonical input; ONNX models
      // usually have dynamic H/W. We pick 518 to match the training size
      // for best quality. Smaller models (e.g. 308) still work — resize
      // is agnostic.
      const dim = 518;
      debugPrint('camo: $label ready (onnx, dim=$dim)');
      return _OnnxDepthEngine._(session, dim, label);
    } catch (e) {
      debugPrint('camo: $label ort session create failed: $e');
      return null;
    }
  }

  @override
  Future<_DepthMap?> analyzeFile(String path, {int target = 128}) async {
    ort.OrtValueTensor? inputOrt;
    ort.OrtRunOptions? runOpts;
    List<ort.OrtValue?>? outputs;
    try {
      final bytes = await File(path).readAsBytes();
      img.Image? src = img.decodeImage(bytes);
      if (src == null) return null;
      src = img.bakeOrientation(src);

      final D = _inDim;
      final resized = img.copyResize(src, width: D, height: D,
          interpolation: img.Interpolation.linear);

      // NCHW + ImageNet normalization (matches Depth Anything v2).
      const mean = [0.485, 0.456, 0.406];
      const stdv = [0.229, 0.224, 0.225];
      final input = Float32List(1 * 3 * D * D);
      for (var y = 0; y < D; y++) {
        for (var x = 0; x < D; x++) {
          final px = resized.getPixel(x, y);
          input[0 * D * D + y * D + x] = (px.r.toDouble() / 255.0 - mean[0]) / stdv[0];
          input[1 * D * D + y * D + x] = (px.g.toDouble() / 255.0 - mean[1]) / stdv[1];
          input[2 * D * D + y * D + x] = (px.b.toDouble() / 255.0 - mean[2]) / stdv[2];
        }
      }

      inputOrt = ort.OrtValueTensor.createTensorWithDataList(input, [1, 3, D, D]);
      final inputName = _session.inputNames.isNotEmpty ? _session.inputNames.first : 'pixel_values';
      runOpts = ort.OrtRunOptions();
      outputs = _session.run(runOpts, {inputName: inputOrt});

      // Output is [1, 1, D, D] or [1, D, D] — flatten into DxD floats.
      final flat = Float32List(D * D);
      _flattenTo(outputs.first?.value, flat, D);

      double lo = double.infinity, hi = -double.infinity;
      for (final v in flat) {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      final span = (hi - lo).abs() < 1e-6 ? 1.0 : (hi - lo);

      // Downsample to target grid + pull rgb from a separately resized copy.
      final small = img.copyResize(src, width: target, height: target,
          interpolation: img.Interpolation.linear);
      final w = small.width, h = small.height;
      final rgb = Uint8List(w * h * 3);
      final depth = Float32List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final px = small.getPixel(x, y);
          final o = (y * w + x);
          rgb[o * 3] = px.r.toInt();
          rgb[o * 3 + 1] = px.g.toInt();
          rgb[o * 3 + 2] = px.b.toInt();
          final mx = (x * D / w).floor().clamp(0, D - 1);
          final my = (y * D / h).floor().clamp(0, D - 1);
          depth[o] = ((flat[my * D + mx] - lo) / span).clamp(0.0, 1.0);
        }
      }
      return _DepthMap(w, h, depth, rgb);
    } catch (e, st) {
      debugPrint('camo: $name inference failed: $e\n$st');
      return null;
    } finally {
      inputOrt?.release();
      runOpts?.release();
      outputs?.forEach((o) => o?.release());
    }
  }

  /// ONNX Runtime returns nested Lists for multi-dim outputs. Walk them and
  /// write any leaf we find into a D×D grid, using the last two dims as
  /// the (y, x) index.
  static void _flattenTo(dynamic node, Float32List flat, int D, [List<int>? path]) {
    path ??= <int>[];
    if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _flattenTo(node[i], flat, D, [...path, i]);
      }
    } else if (node is num) {
      if (path.length >= 2) {
        final y = path[path.length - 2];
        final x = path[path.length - 1];
        if (y < D && x < D) flat[y * D + x] = node.toDouble();
      }
    }
  }
}
// Top-level function so it can run in an isolate via `compute`.
_DepthMap? _depthIsolate(_DepthJob job) {
  final bytes = File(job.path).readAsBytesSync();
  img.Image? src = img.decodeImage(bytes);
  if (src == null) return null;
  // Respect EXIF orientation so portrait shots aren't sideways.
  src = img.bakeOrientation(src);
  final scale = job.target / math.max(src.width, src.height);
  final w = (src.width * scale).round().clamp(16, job.target);
  final h = (src.height * scale).round().clamp(16, job.target);
  final small = img.copyResize(src, width: w, height: h, interpolation: img.Interpolation.linear);

  final rgb = Uint8List(w * h * 3);
  final lum = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = small.getPixel(x, y);
      final r = px.r.toInt();
      final g = px.g.toInt();
      final b = px.b.toInt();
      final o = (y * w + x);
      rgb[o * 3] = r;
      rgb[o * 3 + 1] = g;
      rgb[o * 3 + 2] = b;
      lum[o] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
    }
  }

  // Sobel edge magnitude per pixel.
  final edge = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final gx = -lum[(y - 1) * w + (x - 1)] + lum[(y - 1) * w + (x + 1)]
          + -2 * lum[y * w + (x - 1)] + 2 * lum[y * w + (x + 1)]
          + -lum[(y + 1) * w + (x - 1)] + lum[(y + 1) * w + (x + 1)];
      final gy = -lum[(y - 1) * w + (x - 1)] - 2 * lum[(y - 1) * w + x] - lum[(y - 1) * w + (x + 1)]
          + lum[(y + 1) * w + (x - 1)] + 2 * lum[(y + 1) * w + x] + lum[(y + 1) * w + (x + 1)];
      edge[y * w + x] = math.sqrt(gx * gx + gy * gy);
    }
  }

  // Pseudo-depth: dark & low-edge pixels → far, bright & high-edge → near.
  final depth = Float32List(w * h);
  var lo = double.infinity, hi = -double.infinity;
  for (var i = 0; i < depth.length; i++) {
    final d = 0.65 * lum[i] + 0.55 * math.min(edge[i], 1.0);
    depth[i] = d;
    if (d < lo) lo = d;
    if (d > hi) hi = d;
  }
  final span = (hi - lo).abs() < 1e-6 ? 1.0 : (hi - lo);
  for (var i = 0; i < depth.length; i++) {
    depth[i] = ((depth[i] - lo) / span).clamp(0.0, 1.0);
  }
  return _DepthMap(w, h, depth, rgb);
}

// ─── point cloud store ───────────────────────────────────────────────────────
//
// One growing Float32List per capture on disk. Interleaved [x,y,z,r,g,b]
// with r/g/b in [0,1]. Each image contributes up to ~6k points placed on a
// local tile that's rotated around the global Y axis by its index, so more
// photos → wider 3D map.

class _PointCloudStore {
  static final instance = _PointCloudStore._();
  _PointCloudStore._();

  final Map<String, int> _photoCount = {};

  Future<File> _pcFile(String captureId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'camo', captureId));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(p.join(dir.path, 'cloud.bin'));
  }

  Future<Float32List> read(String captureId) async {
    final f = await _pcFile(captureId);
    if (!await f.exists()) return Float32List(0);
    final bytes = await f.readAsBytes();
    return Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
  }

  Future<void> clear(String captureId) async {
    final f = await _pcFile(captureId);
    if (await f.exists()) await f.delete();
    _photoCount.remove(captureId);
  }

  Future<void> appendImage({
    required String captureId,
    required _DepthMap depth,
    required int imageIndex,
    required int totalImages,
    int stride = 1,
    _LayoutMode mode = _LayoutMode.outdoor,
  }) async {
    final w = depth.w, h = depth.h;
    final samples = ((w / stride).floor() * (h / stride).floor());
    final out = Float32List(samples * 6);
    var k = 0;

    // Back-projection intrinsics for both modes.
    final cx = w / 2.0;
    final cy = h / 2.0;
    final f = w.toDouble(); // ~60° FOV

    // Distribute photos evenly around a full circle. With few photos the
    // gaps are wide; with many (10+) the tiles start to knit together.
    final n = math.max(totalImages, 1);
    final theta = imageIndex * (2 * math.pi / n);
    final cosT = math.cos(theta), sinT = math.sin(theta);

    if (mode == _LayoutMode.outdoor) {
      // "Walk around the subject." Tiles face INWARD toward origin.
      final radius = 0.6; // tighter than before so 4 tiles feel cohesive
      final tileScale = 0.75;
      final centerX = radius * cosT;
      final centerZ = radius * sinT;
      for (var y = 0; y < h; y += stride) {
        for (var x = 0; x < w; x += stride) {
          final idx = y * w + x;
          final d = depth.depth[idx];
          final z = 0.1 + d * 3.0;      // deeper relief (0.1..3.1)
          final lx = ((x - cx) / f) * z;
          final ly = -((y - cy) / f) * z;
          final wx = centerX + cosT * lx - sinT * (z - 0.9) * tileScale;
          final wz = centerZ + sinT * lx + cosT * (z - 0.9) * tileScale;
          final wy = ly * tileScale;

          final c = idx * 3;
          out[k++] = wx.toDouble();
          out[k++] = wy.toDouble();
          out[k++] = wz.toDouble();
          out[k++] = depth.rgb[c] / 255.0;
          out[k++] = depth.rgb[c + 1] / 255.0;
          out[k++] = depth.rgb[c + 2] / 255.0;
        }
      }
    } else {
      // Indoor panorama: viewer at origin, tiles wrap around on a cylinder
      // facing OUTWARD. Depth pushes pixels away from the viewer into the
      // walls, so rooms render as an inside-out shell.
      const cylR = 1.0;      // cylinder radius
      const tileW = 0.85;    // tile half-width along the cylinder tangent
      const tileH = 0.65;    // tile half-height
      const depthScale = 0.8;
      for (var y = 0; y < h; y += stride) {
        for (var x = 0; x < w; x += stride) {
          final idx = y * w + x;
          final d = depth.depth[idx];
          final uNorm = (x - cx) / cx;       // -1..1
          final vNorm = (y - cy) / cy;       // -1..1
          final outward = cylR + d * depthScale;
          final tangentX = -sinT;
          final tangentZ = cosT;
          final wx = outward * cosT + uNorm * tileW * tangentX;
          final wz = outward * sinT + uNorm * tileW * tangentZ;
          final wy = -vNorm * tileH;

          final c = idx * 3;
          out[k++] = wx.toDouble();
          out[k++] = wy.toDouble();
          out[k++] = wz.toDouble();
          out[k++] = depth.rgb[c] / 255.0;
          out[k++] = depth.rgb[c + 1] / 255.0;
          out[k++] = depth.rgb[c + 2] / 255.0;
        }
      }
    }

    final f0 = await _pcFile(captureId);
    final sink = f0.openWrite(mode: FileMode.append);
    sink.add(out.buffer.asUint8List(0, k * 4));
    await sink.close();
    _photoCount[captureId] = (_photoCount[captureId] ?? 0) + 1;
  }

  int photoCount(String captureId) => _photoCount[captureId] ?? 0;
}

class _LocalStore extends ChangeNotifier {
  static final instance = _LocalStore._();
  _LocalStore._();

  static const _kAssets = 'camo.local.assets';
  static const _kJob = 'camo.local.job';

  final List<Map<String, dynamic>> assets = [];
  Map<String, dynamic>? job;
  Timer? _sim;
  bool _loaded = false;

  List<Map<String, dynamic>> assetsFor(String captureId) =>
      assets.where((a) => a['capture_id'] == captureId).toList();

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    final a = sp.getString(_kAssets);
    if (a != null) {
      final list = (jsonDecode(a) as List).cast<Map<String, dynamic>>();
      assets
        ..clear()
        ..addAll(list);
    }
    final j = sp.getString(_kJob);
    if (j != null) job = jsonDecode(j) as Map<String, dynamic>;
    // If the app was killed mid-run, revive the simulation from the saved
    // stage rather than stranding the user on a spinner.
    if (job != null &&
        (job!['status'] == 'queued' || job!['status'] == 'running')) {
      _resumeSim();
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAssets, jsonEncode(assets));
    if (job != null) {
      await sp.setString(_kJob, jsonEncode(job));
    } else {
      await sp.remove(_kJob);
    }
  }

  Future<String> addAsset({
    required String captureId,
    required File source,
    required String kind,
    required String contentType,
    double? lat,
    double? lon,
    double? altitude,
    double? heading,
    DateTime? capturedAt,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'camo', captureId));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final ext = p.extension(source.path);
    final dst = File(p.join(dir.path, '${id}_${p.basenameWithoutExtension(source.path)}$ext'));
    await source.copy(dst.path);
    final meta = <String, dynamic>{
      'id': id,
      'capture_id': captureId,
      'kind': kind,
      'content_type': contentType,
      'storage_key': dst.path,
      'size_bytes': await dst.length(),
      'lat': lat,
      'lon': lon,
      'altitude': altitude,
      'heading': heading,
      'captured_at': (capturedAt ?? DateTime.now().toUtc()).toIso8601String(),
    };
    assets.add(meta);
    await _persist();
    notifyListeners();
    return id;
  }

  Future<Map<String, dynamic>> submit(String captureId) async {
    job = {
      'id': 'local-${DateTime.now().millisecondsSinceEpoch}',
      'capture_id': captureId,
      'status': 'queued',
      'stage': null,
      'error': null,
      'created_at': DateTime.now().toIso8601String(),
      'started_at': null,
      'finished_at': null,
      '_stageIndex': -1,
    };
    await _persist();
    notifyListeners();
    // Kick off the real pipeline in the background — don't await here or the
    // UI button would hang until every photo has been processed.
    unawaited(_runPipeline(captureId));
    return job!;
  }

  static const List<String> _stages = [
    'extract_frames',
    'filter_quality',
    'colmap_sfm',
    'colmap_mvs',
    'gaussian_splat',
    'to_3dtiles',
  ];

  Future<void> _setStage(int idx) async {
    job!['status'] = 'running';
    job!['stage'] = _stages[idx];
    job!['_stageIndex'] = idx;
    job!['started_at'] ??= DateTime.now().toIso8601String();
    await _persist();
    notifyListeners();
  }

  Future<void> _runPipeline(String captureId) async {
    try {
      // Start fresh so re-submitting with more photos produces a coherent
      // growing cloud instead of doubling up.
      await _PointCloudStore.instance.clear(captureId);

      final photos = assets
          .where((a) => a['capture_id'] == captureId && a['kind'] == 'photo')
          .toList();

      // Stage 1 — extract_frames (photos are already frames).
      await _setStage(0);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Stage 2 — filter_quality (cheap; real work happens during depth).
      await _setStage(1);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Stage 3 — pose assignment (ring layout, not real SfM).
      await _setStage(2);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Stage 4 — depth + point cloud (the heavy one, runs per photo).
      await _setStage(3);
      final engine = await _DepthEngine.forCurrent();
      final layout = CamoState.instance.layoutMode;
      var processed = 0;
      for (final a in photos) {
        final path = a['storage_key'] as String;
        if (!File(path).existsSync()) continue;
        final depth = await engine.analyzeFile(path);
        if (depth == null) continue;
        await _PointCloudStore.instance.appendImage(
          captureId: captureId,
          depth: depth,
          imageIndex: processed,
          totalImages: photos.length,
          mode: layout,
        );
        processed++;
        // Expose progress in the stage string so the progress chip ticks.
        job!['stage'] = 'colmap_mvs · ${engine.name} · $processed/${photos.length}';
        notifyListeners();
      }

      // Stage 5 — gaussian_splat (skipped locally; mark visited).
      await _setStage(4);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Stage 6 — to_3dtiles (the point cloud file IS the tileset).
      await _setStage(5);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      job!['status'] = 'succeeded';
      job!['stage'] = null;
      job!['finished_at'] = DateTime.now().toIso8601String();
      await _persist();
      notifyListeners();
    } catch (e, st) {
      job!['status'] = 'failed';
      job!['error'] = '$e';
      job!['finished_at'] = DateTime.now().toIso8601String();
      await _persist();
      notifyListeners();
      debugPrint('local pipeline failed: $e\n$st');
    }
  }

  /// Re-drive the pipeline if the app was killed mid-run. Called from load().
  void _resumeSim() {
    if (job == null) return;
    final captureId = job!['capture_id'] as String?;
    if (captureId != null) unawaited(_runPipeline(captureId));
  }

  Future<void> reset() async {
    _sim?.cancel();
    assets.clear();
    job = null;
    await _persist();
    notifyListeners();
  }
}

// ─── EXIF GPS helpers ────────────────────────────────────────────────────────
//
// Reads lat/lon/altitude from an image file's EXIF tags. Works for both
// gallery picks (the original photo's EXIF is preserved) and on-camera
// captures via image_picker (Android/iOS both pass full metadata by default).
// No runtime permission needed — EXIF reading is just file I/O.

class _ExifGps {
  const _ExifGps({required this.lat, required this.lon, this.altitude, this.heading});
  final double lat;
  final double lon;
  final double? altitude;
  final double? heading;
}

double? _dmsToDecimal(dynamic values, String ref) {
  if (values == null) return null;
  try {
    // exif package returns `IfdTags` → `values` as List<Ratio>.
    final list = (values as dynamic).values as List;
    if (list.length < 3) return null;
    double part(dynamic r) =>
        r is num ? r.toDouble() : (r.numerator as num).toDouble() / (r.denominator as num).toDouble();
    final d = part(list[0]);
    final m = part(list[1]);
    final s = part(list[2]);
    var dec = d + m / 60.0 + s / 3600.0;
    final r = ref.toUpperCase();
    if (r == 'S' || r == 'W') dec = -dec;
    return dec;
  } catch (_) {
    return null;
  }
}

double? _ratioToDouble(dynamic values) {
  if (values == null) return null;
  try {
    final list = (values as dynamic).values as List;
    if (list.isEmpty) return null;
    final r = list.first;
    if (r is num) return r.toDouble();
    return (r.numerator as num).toDouble() / (r.denominator as num).toDouble();
  } catch (_) {
    return null;
  }
}

Future<_ExifGps?> _readExifGps(File file) async {
  try {
    final bytes = await file.readAsBytes();
    final tags = await exif_pkg.readExifFromBytes(bytes);
    if (tags.isEmpty) return null;
    final latRef = tags['GPS GPSLatitudeRef']?.printable ?? 'N';
    final lonRef = tags['GPS GPSLongitudeRef']?.printable ?? 'E';
    final lat = _dmsToDecimal(tags['GPS GPSLatitude'], latRef);
    final lon = _dmsToDecimal(tags['GPS GPSLongitude'], lonRef);
    if (lat == null || lon == null) return null;
    final alt = _ratioToDouble(tags['GPS GPSAltitude']);
    final heading = _ratioToDouble(tags['GPS GPSImgDirection']);
    return _ExifGps(lat: lat, lon: lon, altitude: alt, heading: heading);
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
    Future.wait([
      CamoState.instance.load(),
      _LocalStore.instance.load(),
    ]).then((_) {
      if (mounted) setState(() => _loaded = true);
      // Fire-and-forget: if the Base model isn't cached yet, pull it in
      // the background. Progress is surfaced in the Settings sheet; the
      // app remains fully usable on the bundled Small model meanwhile.
      _ModelDownloader.instance.ensureDownloaded();
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
  late bool _localMode;
  late _LayoutMode _layoutMode;

  @override
  void initState() {
    super.initState();
    final s = CamoState.instance;
    _api = TextEditingController(text: s.apiBase);
    _viewer = TextEditingController(text: s.viewerBase);
    _region = TextEditingController(text: s.regionId);
    _user = TextEditingController(text: s.userId);
    _localMode = s.localMode;
    _layoutMode = s.layoutMode;
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('로컬 테스트 모드'),
            subtitle: const Text(
              '백엔드 없이 폰 안에서 전체 흐름을 시뮬레이션합니다. '
              '3D 지도는 업로드한 사진으로 3D 링이 그려져요.',
              style: TextStyle(fontSize: 12),
            ),
            value: _localMode,
            onChanged: (v) => setState(() => _localMode = v),
          ),
          const Divider(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '촬영 모드',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          SegmentedButton<_LayoutMode>(
            segments: const [
              ButtonSegment(
                value: _LayoutMode.outdoor,
                icon: Icon(Icons.photo_camera_outlined),
                label: Text('외부 촬영'),
              ),
              ButtonSegment(
                value: _LayoutMode.indoor,
                icon: Icon(Icons.meeting_room_outlined),
                label: Text('실내 파노라마'),
              ),
            ],
            selected: <_LayoutMode>{_layoutMode},
            onSelectionChanged: (s) => setState(() => _layoutMode = s.first),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              '외부: 피사체 주위를 돌며 촬영 · 실내: 가운데 서서 둘러보며 촬영',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
          ListenableBuilder(
            listenable: _ModelDownloader.instance,
            builder: (_, __) {
              final d = _ModelDownloader.instance;
              String label;
              Color color = Colors.black87;
              Widget? trailing;
              switch (d.state) {
                case _ModelDownloadState.idle:
                  label = '고화질 모델(Base) — 대기 중';
                  trailing = TextButton(
                    onPressed: () => d.ensureDownloaded(force: true),
                    child: const Text('다운로드'),
                  );
                  break;
                case _ModelDownloadState.downloading:
                  final pct = (d.progress * 100).clamp(0, 100).toStringAsFixed(0);
                  label = '고화질 모델(Base) 다운로드 중… $pct%';
                  color = Colors.blue.shade700;
                  trailing = SizedBox(
                    width: 60,
                    child: LinearProgressIndicator(
                      value: d.progress == 0 ? null : d.progress,
                      minHeight: 4,
                    ),
                  );
                  break;
                case _ModelDownloadState.done:
                  label = '고화질 모델(Base) — 준비됨 ✓';
                  color = Colors.green.shade700;
                  trailing = TextButton(
                    onPressed: () async {
                      await d.deleteCache();
                    },
                    child: const Text('삭제'),
                  );
                  break;
                case _ModelDownloadState.failed:
                  label = '고화질 모델 받기 실패 — Small로 동작 중';
                  color = Colors.orange.shade800;
                  trailing = TextButton(
                    onPressed: () => d.ensureDownloaded(force: true),
                    child: const Text('다시 시도'),
                  );
                  break;
              }
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: TextStyle(fontSize: 12, color: color)),
                    ),
                    if (trailing != null) trailing,
                  ],
                ),
              );
            },
          ),
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
                    s.lastSuccessJobId = null;
                    await s.save();
                    await _LocalStore.instance.reset();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('캡처 초기화'),
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
                    s.localMode = _localMode;
                    s.layoutMode = _layoutMode;
                    await s.save();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('저장'),
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
    _LocalStore.instance.addListener(_onLocalChange);
    CamoState.instance.addListener(_onStateChange);
    _refreshAccumulated();
  }

  @override
  void dispose() {
    _LocalStore.instance.removeListener(_onLocalChange);
    CamoState.instance.removeListener(_onStateChange);
    _jobPoll?.cancel();
    super.dispose();
  }

  void _onLocalChange() {
    if (!CamoState.instance.localMode) return;
    _refreshAccumulated();
  }

  void _onStateChange() {
    // localMode flipped or captureId reset — recount.
    _refreshAccumulated();
  }

  Future<void> _refreshAccumulated() async {
    final id = CamoState.instance.captureId;
    if (id == null) {
      setState(() => _accumulated = 0);
      return;
    }
    try {
      final count = CamoState.instance.localMode
          ? _LocalStore.instance.assetsFor(id).length
          : (await _api.listAssets(id)).length;
      if (!mounted) return;
      setState(() => _accumulated = count);
      await _refreshJob();
    } catch (_) {
      // Backend may be unreachable on first launch — ignore silently.
    }
  }

  Future<void> _refreshJob() async {
    final id = CamoState.instance.captureId;
    if (id == null) return;
    Map<String, dynamic>? latest;
    if (CamoState.instance.localMode) {
      latest = _LocalStore.instance.job;
    } else {
      final jobs = await _api.listJobs(id);
      latest = jobs.isNotEmpty ? jobs.first as Map<String, dynamic> : null;
    }
    if (!mounted) return;
    setState(() => _activeJob = latest);

    if (latest != null) {
      final status = latest['status'] as String;
      if (status == 'queued' || status == 'running') {
        if (!CamoState.instance.localMode) _schedulePoll();
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
    final id = s.localMode
        ? 'local-${DateTime.now().millisecondsSinceEpoch}'
        : await _api.createCapture(regionId: s.regionId, userId: s.userId);
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
      final local = CamoState.instance.localMode;
      for (var i = 0; i < _items.length; i++) {
        final it = _items[i];
        if (it.uploaded) continue;
        setState(() {
          _status = '업로드 중 ${i + 1}/${_items.length}…';
          it.progress = 0.01;
        });
        if (local) {
          await _LocalStore.instance.addAsset(
            captureId: captureId,
            source: it.file,
            kind: it.kind,
            contentType: it.contentType,
          );
        } else {
          final filename = it.file.uri.pathSegments.last;
          // Pull GPS from EXIF so the server can anchor the reconstruction
          // on the real globe. Photos without GPS (most indoor shots) just
          // get nulls — the server still reconstructs, it just won't be
          // auto-placed on the map.
          final gps = it.kind == 'photo' ? await _readExifGps(it.file) : null;
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
            lat: gps?.lat,
            lon: gps?.lon,
            altitude: gps?.altitude,
            heading: gps?.heading,
            capturedAt: DateTime.now().toUtc(),
          );
        }
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
      final job = CamoState.instance.localMode
          ? await _LocalStore.instance.submit(captureId)
          : await _api.submit(captureId);
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
    _LocalStore.instance.addListener(_onLocal);
    _refresh();
  }

  @override
  void dispose() {
    CamoState.instance.removeListener(_onStateChange);
    _LocalStore.instance.removeListener(_onLocal);
    _poll?.cancel();
    super.dispose();
  }

  void _onLocal() {
    if (CamoState.instance.localMode) _refresh();
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
      Map<String, dynamic>? latest;
      Map<String, dynamic>? rec;
      if (CamoState.instance.localMode) {
        latest = _LocalStore.instance.job;
        if (latest != null && latest['status'] == 'succeeded') {
          rec = {'capture_id': captureId, 'local': true};
        }
      } else {
        final jobs = await _api.listJobs(captureId);
        latest = jobs.isNotEmpty ? jobs.first as Map<String, dynamic> : null;
        rec = await _api.reconstruction(captureId);
      }
      setState(() {
        _latestJob = latest;
        _rec = rec;
        if (rec != null) {
          _status = '누적 3D 지도 준비됨';
          if (!CamoState.instance.localMode) {
            _loadViewer(captureId);
          } else {
            _web = null;
          }
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

  Widget _buildBody(String? captureId) {
    if (_rec == null) {
      return _NoMapPlaceholder(job: _latestJob, onRetry: _refresh);
    }
    if (CamoState.instance.localMode && captureId != null) {
      return _LocalPointCloudViewer(captureId: captureId);
    }
    if (_web != null) return WebViewWidget(controller: _web!);
    return _NoMapPlaceholder(job: _latestJob, onRetry: _refresh);
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
          child: _buildBody(captureId),
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

// ─── local 3D point cloud viewer (WebGL in WebView) ──────────────────────────

class _LocalPointCloudViewer extends StatefulWidget {
  const _LocalPointCloudViewer({required this.captureId});
  final String captureId;

  @override
  State<_LocalPointCloudViewer> createState() => _LocalPointCloudViewerState();
}

class _LocalPointCloudViewerState extends State<_LocalPointCloudViewer> {
  WebViewController? _web;
  bool _htmlReady = false;
  int _ptsSent = 0;

  @override
  void initState() {
    super.initState();
    _boot();
    _LocalStore.instance.addListener(_onLocalChange);
  }

  @override
  void dispose() {
    _LocalStore.instance.removeListener(_onLocalChange);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _LocalPointCloudViewer old) {
    super.didUpdateWidget(old);
    if (old.captureId != widget.captureId) {
      _ptsSent = 0;
      _htmlReady = false;
      _boot();
    }
  }

  void _onLocalChange() {
    final job = _LocalStore.instance.job;
    if (job != null && job['status'] == 'succeeded') _pushPoints();
  }

  Future<void> _boot() async {
    final html = await rootBundle.loadString('assets/viewer.html');
    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xff0b1220))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _htmlReady = true;
          _pushPoints();
        },
      ))
      ..loadHtmlString(html);
    if (!mounted) return;
    setState(() => _web = ctrl);
  }

  Future<void> _pushPoints() async {
    if (!_htmlReady || _web == null) return;
    final pts = await _PointCloudStore.instance.read(widget.captureId);
    if (pts.isEmpty) return;
    final bytes = pts.buffer.asUint8List(0, pts.lengthInBytes);
    final b64 = base64Encode(bytes);
    await _web!.runJavaScript('window.camoLoadPoints("$b64");');
    if (!mounted) return;
    setState(() => _ptsSent = pts.length ~/ 6);
  }

  @override
  Widget build(BuildContext context) {
    if (_web == null) {
      return const ColoredBox(
        color: Color(0xff0b1220),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _web!)),
        Positioned(
          top: 8,
          right: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                '누적 ${_ptsSent.toString()} pts · 드래그 회전',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── local 3D map (offline test view — legacy thumbnail ring) ────────────────

class _LocalMap3D extends StatefulWidget {
  const _LocalMap3D({required this.assets});
  final List<Map<String, dynamic>> assets;

  @override
  State<_LocalMap3D> createState() => _LocalMap3DState();
}

class _LocalMap3DState extends State<_LocalMap3D> with SingleTickerProviderStateMixin {
  double _yaw = 0;
  double _pitch = -0.15;
  late final Ticker _tick;
  bool _autoSpin = true;

  @override
  void initState() {
    super.initState();
    _tick = createTicker((_) {
      if (_autoSpin && mounted) setState(() => _yaw += 0.003);
    })
      ..start();
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.assets.length;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0d1b2a), Color(0xFF1b2a41), Color(0xFF2a4365)],
        ),
      ),
      child: GestureDetector(
        onPanStart: (_) => _autoSpin = false,
        onPanUpdate: (d) {
          setState(() {
            _yaw += d.delta.dx * 0.01;
            _pitch = (_pitch + d.delta.dy * 0.005).clamp(-1.2, 0.3);
          });
        },
        onDoubleTap: () => setState(() => _autoSpin = !_autoSpin),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _floor(),
            for (var i = 0; i < n; i++) _photo(i, n, widget.assets[i]),
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '누적 $n장 · 드래그 회전 · 더블탭으로 자동회전',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _floor() {
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0015)
      ..rotateX(_pitch)
      ..rotateY(_yaw)
      ..translate(0.0, 140.0, 0.0)
      ..rotateX(-math.pi / 2);
    return Center(
      child: Transform(
        alignment: Alignment.center,
        transform: m,
        child: Container(
          width: 700,
          height: 700,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                Colors.tealAccent.withOpacity(0.25),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _photo(int i, int n, Map<String, dynamic> a) {
    final theta = 2 * math.pi * i / math.max(n, 1);
    final radius = 160 + n * 4.0;
    final x = radius * math.cos(theta);
    final z = radius * math.sin(theta);

    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0015)
      ..rotateX(_pitch)
      ..rotateY(_yaw)
      ..translate(x, 0.0, z)
      ..rotateY(-theta - math.pi / 2);

    final isVideo = a['kind'] == 'video';
    final path = a['storage_key'] as String?;
    return Center(
      child: Transform(
        alignment: Alignment.center,
        transform: m,
        child: Container(
          width: 120,
          height: 160,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.tealAccent, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: isVideo || path == null
              ? Container(
                  color: Colors.black87,
                  alignment: Alignment.center,
                  child: const Icon(Icons.movie, color: Colors.white, size: 36),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.broken_image, color: Colors.white54),
                  ),
                ),
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

const List<(String, String)> _kStages = [
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
