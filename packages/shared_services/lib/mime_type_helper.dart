/// Helper utility for determining MIME types from file extensions
class MimeTypeHelper {
  /// Maps a file extension to its corresponding MIME type
  /// Returns 'application/octet-stream' if the extension is not recognized
  static String getContentTypeFromExtension(String extension) {
    final ext = extension.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (ext.isEmpty) {
      return 'application/octet-stream';
    }
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'svg':
        return 'image/svg+xml';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'zip':
        return 'application/zip';
      case 'mp3':
        return 'audio/mpeg';
      case 'mp4':
        return 'video/mp4';
      case 'json':
        return 'application/json';
      case 'xml':
        return 'application/xml';
      default:
        return 'application/octet-stream';
    }
  }

  /// Detects the MIME type from either a filename/path or a raw extension.
  static String detect(String pathOrExtension) {
    final normalized = pathOrExtension.trim();
    if (normalized.isEmpty) {
      return 'application/octet-stream';
    }

    final withoutQuery = normalized.split('?').first;
    final lastSegment = withoutQuery.split('/').last;
    final extension = lastSegment.contains('.')
        ? lastSegment.split('.').last
        : lastSegment;
    return getContentTypeFromExtension(extension);
  }

  /// Content type for a picked image upload (e.g. an `XFile` from
  /// image_picker).
  ///
  /// Prefers the MIME type the picker reported (usually set on web), then the
  /// file name's extension (mobile, where the picker usually reports none).
  /// Falls back to `image/jpeg` only when neither identifies an image, since
  /// image_picker re-encodes to JPEG when it compresses.
  static String forImage({String? reportedMimeType, required String fileName}) {
    final reported = reportedMimeType?.trim().toLowerCase() ?? '';
    if (reported.startsWith('image/')) return reported;
    final detected = detect(fileName);
    if (detected.startsWith('image/')) return detected;
    return 'image/jpeg';
  }
}
