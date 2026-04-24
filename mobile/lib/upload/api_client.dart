import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thin client for the Cameraworld FastAPI backend.
class ApiClient {
  ApiClient({required this.baseUrl});

  final String baseUrl;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> createCapture({
    required String regionId,
    required String userId,
    double? latMin,
    double? latMax,
    double? lonMin,
    double? lonMax,
  }) async {
    final resp = await http.post(
      _u('/captures'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'region_id': regionId,
        'user_id': userId,
        'lat_min': latMin,
        'lat_max': latMax,
        'lon_min': lonMin,
        'lon_max': lonMax,
      }),
    );
    _expect(resp, 201);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> presignAsset({
    required String captureId,
    required String kind,
    required String contentType,
    required String filename,
  }) async {
    final resp = await http.post(
      _u('/captures/$captureId/assets/presign'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'kind': kind,
        'content_type': contentType,
        'filename': filename,
      }),
    );
    _expect(resp, 200);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> putToPresigned({
    required String uploadUrl,
    required File file,
    required String contentType,
  }) async {
    final resp = await http.put(
      Uri.parse(uploadUrl),
      headers: {'content-type': contentType},
      body: await file.readAsBytes(),
    );
    _expect(resp, 200, alsoAccept: {204});
  }

  Future<Map<String, dynamic>> registerAsset({
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
    final resp = await http.post(
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
    _expect(resp, 201);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> submit(String captureId) async {
    final resp = await http.post(_u('/captures/$captureId/submit'));
    _expect(resp, 202);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> listJobs(String captureId) async {
    final resp = await http.get(_u('/captures/$captureId/jobs'));
    _expect(resp, 200);
    return jsonDecode(resp.body) as List<dynamic>;
  }

  void _expect(http.Response r, int expected, {Set<int> alsoAccept = const {}}) {
    if (r.statusCode != expected && !alsoAccept.contains(r.statusCode)) {
      throw HttpException('API ${r.statusCode}: ${r.body}', uri: r.request?.url);
    }
  }
}
