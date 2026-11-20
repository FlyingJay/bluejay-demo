// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
// The web half of save_bytes.dart: an anchor download of a Blob URL.
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Saves [bytes] as [fileName] through a browser download. [context] is
/// unused on web (the mobile half anchors the share sheet to it).
Future<void> saveBytes(
  BuildContext context,
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final objectUrl = html.Url.createObjectUrlFromBlob(html.Blob([bytes], mimeType));
  final anchor = html.AnchorElement(href: objectUrl)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
  // Revoke after the click has been handled.
  Future<void>.delayed(const Duration(milliseconds: 100), () => html.Url.revokeObjectUrl(objectUrl));
}
