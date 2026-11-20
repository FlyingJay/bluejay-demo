// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'mime_type_helper.dart';
import 'platform_service.dart';
import 'save_bytes_web.dart';
import 'scoped_storage.dart';

class WebPlatformService implements PlatformService {
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
    await storageRef.putData(await file.readAsBytes(), mergedMetadata);
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
    await storageRef.putData(file.bytes!, mergedMetadata);
  }

  @override
  Future<void> downloadFile(
      BuildContext context, String downloadUrl, String fileName) async {
    final messenger = ScaffoldMessenger.of(context);
    // Fetch and save under [fileName] so "Download" downloads, rather than
    // opening the file in a tab under its storage object name. Falls back to
    // opening the URL if the fetch is refused (e.g. a host without CORS).
    try {
      final response = await http.get(Uri.parse(downloadUrl));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final contentType =
            response.headers['content-type'] ?? 'application/octet-stream';
        _saveBlob(html.Blob([response.bodyBytes], contentType), fileName);
        return;
      }
    } catch (_) {
      // Fall through to opening the URL.
    }
    try {
      await launchUrl(Uri.parse(downloadUrl));
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Could not open file: $e')));
    }
  }

  @override
  Future<void> downloadAuthenticatedFile(
    BuildContext context,
    Uri downloadUri,
    String fileName, {
    Map<String, String> headers = const {},
  }) async {
    final response = await http.get(downloadUri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(extractDownloadError(response));
    }

    final contentType =
        response.headers['content-type'] ?? 'application/octet-stream';
    _saveBlob(html.Blob([response.bodyBytes], contentType), fileName);
  }

  @override
  Future<void> downloadBytes(
    BuildContext context,
    Uint8List bytes,
    String fileName, {
    String mimeType = 'application/octet-stream',
  }) =>
      saveBytes(context, bytes, fileName, mimeType: mimeType);

  void _saveBlob(html.Blob blob, String fileName) {
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: objectUrl)
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.children.add(anchor);
    anchor.click();
    anchor.remove();
    // Revoke after the click has been handled.
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      html.Url.revokeObjectUrl(objectUrl);
    });
  }

  @override
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}

PlatformService getPlatformService() => WebPlatformService();
