import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Getting a file *out* of the app on iOS and Android.
///
/// An app's documents directory isn't visible to the user on either
/// platform (iOS only exposes it to the Files app when `Info.plist` opts in,
/// which this app doesn't), so writing a file there and showing its path
/// leaves the user with nothing they can open. Every download or export on
/// mobile instead writes to a fresh temporary file and hands it to the
/// platform share sheet, which offers Save to Files, AirDrop, email, and any
/// other app that accepts the file.
///
/// This library imports `dart:io`, so only import it from code that never
/// loads on web (a `dart.library.io` conditional import, or the mobile
/// `PlatformService`).

/// [fileName] reduced to a single, safe file name.
///
/// Download names often come from storage paths or user-entered titles, so
/// any directory part is dropped (a name can never write outside its folder)
/// and characters the common filesystems reject are replaced. Long names keep
/// their end, which is where the extension is.
String safeShareFileName(String fileName, {String fallback = 'download'}) {
  final lastSegment = fileName.split(RegExp(r'[\\/]')).last;
  final cleaned = lastSegment.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return fallback;
  const maxLength = 120;
  return cleaned.length > maxLength ? cleaned.substring(cleaned.length - maxLength) : cleaned;
}

/// The on-screen rectangle of the widget that triggered a share. iPad
/// presents the share sheet as a popover anchored to this rectangle, and
/// fails without one. Read it before any `await`: the widget may be gone by
/// the time the share starts.
Rect? sharePositionOriginFor(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return null;
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

/// A new, empty file named [fileName] inside its own folder under the app's
/// temporary directory, so two exports with the same name never collide and
/// the OS can reclaim them later.
Future<File> createShareFile(String fileName) async {
  final base = await getTemporaryDirectory();
  final folder = Directory('${base.path}/shared_exports/${DateTime.now().microsecondsSinceEpoch}');
  await folder.create(recursive: true);
  return File('${folder.path}/${safeShareFileName(fileName)}');
}

/// Opens the platform share sheet for the file at [path].
Future<ShareResult> shareFileAtPath(
  String path, {
  String? mimeType,
  String? subject,
  Rect? sharePositionOrigin,
}) {
  return Share.shareXFiles(
    [XFile(path, mimeType: mimeType)],
    subject: subject,
    sharePositionOrigin: sharePositionOrigin,
  );
}

/// Writes [bytes] to a fresh temporary file named [fileName] and opens the
/// platform share sheet for it.
Future<ShareResult> shareBytesAsFile(
  List<int> bytes,
  String fileName, {
  String? mimeType,
  String? subject,
  Rect? sharePositionOrigin,
}) async {
  final file = await createShareFile(fileName);
  await file.writeAsBytes(bytes, flush: true);
  return shareFileAtPath(
    file.path,
    mimeType: mimeType,
    subject: subject,
    sharePositionOrigin: sharePositionOrigin,
  );
}
