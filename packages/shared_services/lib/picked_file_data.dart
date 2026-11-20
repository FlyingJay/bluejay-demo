import 'dart:typed_data';

/// A file the user picked, with its contents already read.
///
/// [bytes] is null when the file was chosen but couldn't be read; [readProblem]
/// then says why, in words that can be shown as-is. Callers should show it
/// rather than silently ignoring the pick.
class PickedFileData {
  const PickedFileData({
    required this.name,
    required this.size,
    this.bytes,
    this.readProblem,
  });

  final String name;

  /// Size in bytes, as reported by the platform. Known even when [bytes]
  /// couldn't be read.
  final int size;

  final Uint8List? bytes;
  final String? readProblem;

  bool get isReadable => bytes != null;
}

/// The message shown when a picked file's contents couldn't be read.
///
/// [errorName] is the browser's `DOMException` name when there is one.
/// Browsers report `NotReadableError` (or `NotFoundError`) when the file
/// isn't really on disk yet — an iCloud Drive, OneDrive or Dropbox file that
/// is only a placeholder — or when another app changed or locked it after it
/// was chosen. Safari in particular hits this with cloud-synced files.
String fileReadProblemMessage(String? errorName) {
  switch (errorName) {
    case 'NotReadableError':
    case 'NotFoundError':
      return 'This file couldn\'t be opened. If it\'s stored in iCloud Drive, OneDrive or another synced '
          'folder, make sure it\'s downloaded to this computer (or copy it to your Desktop), close it in '
          'any other app, and choose it again.';
    case 'SecurityError':
      return 'Your browser didn\'t allow this file to be read. Copy it to your Desktop and choose it again.';
    default:
      return 'This file couldn\'t be read. Choose it again, or copy it to your Desktop first and choose the copy.';
  }
}
