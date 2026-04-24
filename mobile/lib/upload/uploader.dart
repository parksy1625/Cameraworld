import 'dart:io';

import 'api_client.dart';

class UploadResult {
  UploadResult({required this.storageKey, required this.assetId});
  final String storageKey;
  final String assetId;
}

/// Upload a single asset: presign -> PUT -> register.
class Uploader {
  Uploader({required this.api, required this.captureId});

  final ApiClient api;
  final String captureId;

  Future<UploadResult> uploadFile({
    required File file,
    required String kind, // "photo" or "video"
    required String contentType,
    double? lat,
    double? lon,
    double? altitude,
    double? heading,
    DateTime? capturedAt,
  }) async {
    final filename = file.uri.pathSegments.last;

    final presign = await api.presignAsset(
      captureId: captureId,
      kind: kind,
      contentType: contentType,
      filename: filename,
    );
    final storageKey = presign['storage_key'] as String;
    final uploadUrl = presign['upload_url'] as String;

    await api.putToPresigned(
      uploadUrl: uploadUrl,
      file: file,
      contentType: contentType,
    );

    final asset = await api.registerAsset(
      captureId: captureId,
      kind: kind,
      storageKey: storageKey,
      contentType: contentType,
      sizeBytes: await file.length(),
      lat: lat,
      lon: lon,
      altitude: altitude,
      heading: heading,
      capturedAt: capturedAt,
    );

    return UploadResult(storageKey: storageKey, assetId: asset['id'] as String);
  }
}
