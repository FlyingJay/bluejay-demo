import 'package:image_picker/image_picker.dart';

export 'package:image_picker/image_picker.dart' show XFile;

/// Picks a group logo from the device gallery: a JPEG at 60% quality, at
/// most 2048 px on its longer side (groupAdminSetLogo takes up to 4 MB and
/// 40 megapixels), or `null` if the user cancelled.
///
/// Picking only: Group Admin and the Groups app send the file to the
/// `groupAdminSetLogo` callable, the one way a group logo is written.
Future<XFile?> pickGroupLogo() => ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 60,
      maxWidth: 2048,
      maxHeight: 2048,
    );
