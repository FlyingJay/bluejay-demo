// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'picked_file_data.dart';

/// Pauses before each retry of a failed read. The first failed read of a
/// cloud-synced file usually starts the download, so a later read can succeed.
const List<Duration> _readRetryDelays = [
  Duration(milliseconds: 500),
  Duration(milliseconds: 1500),
  Duration(seconds: 3),
];

/// See file_pick.dart.
Future<List<PickedFileData>?> pickFilesWithBytes({
  List<String> allowedExtensions = const [],
  bool allowMultiple = false,
}) async {
  final files = await _chooseFiles(allowedExtensions: allowedExtensions, allowMultiple: allowMultiple);
  if (files == null || files.isEmpty) return null;
  return [for (final file in files) await _readWithRetries(file)];
}

/// Opens the browser's file dialog. Null when the user cancels.
Future<List<html.File>?> _chooseFiles({
  required List<String> allowedExtensions,
  required bool allowMultiple,
}) async {
  final input = html.FileUploadInputElement()
    ..accept = allowedExtensions.map((e) => '.$e').join(',')
    ..multiple = allowMultiple
    ..style.display = 'none';
  // The input stays in the page until the dialog closes.
  html.document.body!.append(input);

  final chosen = Completer<List<html.File>?>();
  void finish() {
    if (chosen.isCompleted) return;
    final files = input.files;
    chosen.complete(files == null || files.isEmpty ? null : List.of(files));
  }

  final subscriptions = <StreamSubscription<html.Event>>[
    input.onChange.listen((_) => finish()),
    input.on['cancel'].listen((_) => finish()),
    // Browsers without a `cancel` event refocus the window when the dialog
    // closes, before `change` fires for a pick. Wait before deciding.
    html.window.onFocus.listen((_) {
      Future<void>.delayed(const Duration(seconds: 1), finish);
    }),
  ];
  input.click();
  try {
    return await chosen.future;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    input.remove();
  }
}

Future<PickedFileData> _readWithRetries(html.File file) async {
  String? errorName;
  for (var attempt = 0; attempt <= _readRetryDelays.length; attempt++) {
    if (attempt > 0) await Future<void>.delayed(_readRetryDelays[attempt - 1]);
    try {
      final bytes = await _read(file);
      return PickedFileData(name: file.name, size: file.size, bytes: bytes);
    } on _ReadFailure catch (failure) {
      errorName = failure.errorName;
      // The browser denied access outright; waiting won't change that.
      if (errorName == 'SecurityError') break;
    }
  }
  return PickedFileData(name: file.name, size: file.size, readProblem: fileReadProblemMessage(errorName));
}

Future<Uint8List> _read(html.File file) {
  final reader = html.FileReader();
  final done = Completer<Uint8List>();
  reader.onLoad.first.then((_) {
    final result = reader.result;
    if (result is Uint8List) {
      done.complete(result);
    } else if (result is ByteBuffer) {
      done.complete(result.asUint8List());
    } else if (!done.isCompleted) {
      done.completeError(const _ReadFailure(null));
    }
  });
  reader.onError.first.then((_) {
    if (!done.isCompleted) done.completeError(_ReadFailure(reader.error?.name));
  });
  reader.readAsArrayBuffer(file);
  return done.future;
}

class _ReadFailure implements Exception {
  const _ReadFailure(this.errorName);

  final String? errorName;
}
