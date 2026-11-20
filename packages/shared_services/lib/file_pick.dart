// Picking files and reading their contents in one step.
//
// `pickFilesWithBytes({allowedExtensions, allowMultiple})` returns null when
// the user cancels, and otherwise one `PickedFileData` per chosen file, each
// with its bytes or a `readProblem` to show.
//
// On web this reads files itself and retries failed reads: file_picker's web
// reader makes one attempt and reports a failure only as `bytes == null`,
// which Safari produces for cloud-synced files whose first read happens while
// the file is still being fetched. Elsewhere it wraps file_picker.
export 'picked_file_data.dart';
export 'file_pick_web.dart' if (dart.library.io) 'file_pick_io.dart';
