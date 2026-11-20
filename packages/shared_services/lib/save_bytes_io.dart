// The mobile and desktop half of save_bytes.dart: the platform share sheet.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'file_share_io.dart';

/// Saves [bytes] as [fileName] through the platform share sheet, anchored
/// to [context]'s widget (iPad needs the anchor). A failure shows a snack
/// bar on [context]'s messenger.
Future<void> saveBytes(
  BuildContext context,
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final origin = sharePositionOriginFor(context);
  try {
    await shareBytesAsFile(bytes, fileName, mimeType: mimeType, sharePositionOrigin: origin);
  } catch (e) {
    debugPrint('saveBytes($fileName): $e');
    messenger?.showSnackBar(const SnackBar(content: Text("Couldn't save the file. Try again.")));
  }
}
