import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

abstract class PlatformService {
  // Uploads an image from image_picker. [metadata] must come from
  // ScopedStorage.buildMetadata() (the storage that produced [storageRef]):
  // its creatorId/groupId/appId are what storage rules check and what Usage
  // Meter attributes the bytes to, so an upload without them throws (see
  // requireUploadMetadata). Its contentType is used when set, otherwise the
  // type comes from MimeTypeHelper.forImage (picker-reported MIME type, then
  // file extension, then image/jpeg).
  Future<void> uploadImageFile(Reference storageRef, XFile file,
      {required SettableMetadata metadata});

  // Uploads a file from file_picker. [metadata] as for uploadImageFile; its
  // contentType is used when set, otherwise the file extension is used to
  // infer the content type.
  Future<void> uploadGenericFile(Reference storageRef, PlatformFile file,
      {required SettableMetadata metadata});

  // Downloads below are a browser download on web, and on mobile/desktop open
  // the platform share sheet (Save to Files, AirDrop, email, …) for a
  // temporary copy — see file_share_io.dart. Pass the [BuildContext] of the
  // control the user tapped: iPad anchors the share popover to it.

  Future<void> downloadFile(
      BuildContext context, String downloadUrl, String fileName);

  Future<void> downloadAuthenticatedFile(
    BuildContext context,
    Uri downloadUri,
    String fileName, {
    Map<String, String> headers = const {},
  });

  /// Saves in-memory [bytes] (e.g. a generated CSV) as [fileName]: a browser
  /// download on web, the platform share sheet on mobile/desktop.
  Future<void> downloadBytes(
    BuildContext context,
    Uint8List bytes,
    String fileName, {
    String mimeType = 'application/octet-stream',
  });

  // Copy text to clipboard
  Future<void> copyToClipboard(String text);
}

String extractDownloadError(
  http.BaseResponse response, {
  String? body,
}) {
  final responseBody = body ?? (response is http.Response ? response.body : '');

  try {
    final decoded = jsonDecode(responseBody);
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      if (error is String && error.trim().isNotEmpty) {
        return error.trim();
      }
    }
  } catch (_) {
    // Ignore invalid JSON and fall through to a generic message.
  }

  return 'Download failed (${response.statusCode}).';
}
