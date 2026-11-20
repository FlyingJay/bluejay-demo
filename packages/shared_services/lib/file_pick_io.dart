import 'package:file_picker/file_picker.dart';

import 'picked_file_data.dart';

/// See file_pick.dart.
Future<List<PickedFileData>?> pickFilesWithBytes({
  List<String> allowedExtensions = const [],
  bool allowMultiple = false,
}) async {
  final result = await FilePicker.platform.pickFiles(
    type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: allowedExtensions.isEmpty ? null : allowedExtensions,
    allowMultiple: allowMultiple,
    withData: true,
  );
  if (result == null) return null;
  return [
    for (final file in result.files)
      PickedFileData(
        name: file.name,
        size: file.size,
        bytes: file.bytes,
        readProblem: file.bytes == null ? fileReadProblemMessage(null) : null,
      ),
  ];
}
