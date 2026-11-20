import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'file_share_io.dart';
import 'mime_type_helper.dart';
import 'platform_service.dart';
import 'save_bytes_io.dart';
import 'scoped_storage.dart';

/// Content type for a download, from its file extension.
String _contentTypeFor(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return 'application/octet-stream';
  return MimeTypeHelper.getContentTypeFromExtension(
      fileName.substring(dot + 1));
}

class MobilePlatformService implements PlatformService {
  @override
  Future<void> uploadImageFile(Reference storageRef, XFile file,
      {required SettableMetadata metadata}) async {
    requireUploadMetadata(metadata);
    final mergedMetadata = SettableMetadata(
      contentType: metadata.contentType ??
          MimeTypeHelper.forImage(
              reportedMimeType: file.mimeType, fileName: file.name),
      customMetadata: metadata.customMetadata,
    );
    await storageRef.putFile(File(file.path), mergedMetadata);
  }

  @override
  Future<void> uploadGenericFile(Reference storageRef, PlatformFile file,
      {required SettableMetadata metadata}) async {
    final autoContentType = file.extension != null
        ? MimeTypeHelper.getContentTypeFromExtension(file.extension!)
        : 'application/octet-stream';
    requireUploadMetadata(metadata);
    final mergedMetadata = SettableMetadata(
      contentType: metadata.contentType ?? autoContentType,
      customMetadata: metadata.customMetadata,
    );
    await storageRef.putFile(File(file.path!), mergedMetadata);
  }

  // Downloads on mobile end in the platform share sheet (Save to Files,
  // AirDrop, email, …): see file_share_io.dart for why.

  @override
  Future<void> downloadFile(
      BuildContext context, String downloadUrl, String fileName) async {
    final messenger = ScaffoldMessenger.of(context);
    final origin = sharePositionOriginFor(context);
    try {
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(extractDownloadError(response));
      }
      await shareBytesAsFile(
        response.bodyBytes,
        fileName,
        mimeType: _contentTypeFor(fileName),
        sharePositionOrigin: origin,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  @override
  Future<void> downloadAuthenticatedFile(
    BuildContext context,
    Uri downloadUri,
    String fileName, {
    Map<String, String> headers = const {},
  }) async {
    final origin = sharePositionOriginFor(context);
    final client = http.Client();
    try {
      final request = http.Request('GET', downloadUri);
      request.headers.addAll(headers);
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(extractDownloadError(response, body: body));
      }

      // Streamed to disk rather than buffered: authenticated downloads can
      // be large exports.
      final File file = await createShareFile(fileName);
      final sink = file.openWrite();
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }

      await shareFileAtPath(
        file.path,
        mimeType: response.headers['content-type'] ?? _contentTypeFor(fileName),
        sharePositionOrigin: origin,
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<void> downloadBytes(
    BuildContext context,
    Uint8List bytes,
    String fileName, {
    String mimeType = 'application/octet-stream',
  }) =>
      saveBytes(context, bytes, fileName, mimeType: mimeType);

  @override
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}

PlatformService getPlatformService() => MobilePlatformService();
