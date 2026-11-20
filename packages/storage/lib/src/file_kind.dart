import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// A file's broad type, from its extension, for the icon well on its row.
enum FileKind {
  image('Image', Icons.image_rounded, tone: BjTone.accent),
  pdf('PDF', Icons.picture_as_pdf_rounded, tone: BjTone.danger),
  document('Document', Icons.description_rounded, tone: BjTone.info),
  spreadsheet('Spreadsheet', Icons.table_chart_rounded, tone: BjTone.success),
  presentation('Slides', Icons.slideshow_rounded, tone: BjTone.warning),
  video('Video', Icons.movie_rounded, color: BjCategorical.violet),
  audio('Audio', Icons.music_note_rounded, color: BjCategorical.teal),
  archive('Archive', Icons.folder_zip_rounded, color: BjCategorical.amber),
  code('Code', Icons.code_rounded, tone: BjTone.neutral),
  other('File', Icons.insert_drive_file_rounded, tone: BjTone.neutral);

  const FileKind(this.label, this.icon, {this.tone, this.color});

  final String label;
  final IconData icon;

  /// The icon well's tone; [color] is used for kinds no tone fits.
  final BjTone? tone;
  final Color? color;

  static const _byExtension = {
    'png': image,
    'jpg': image,
    'jpeg': image,
    'gif': image,
    'webp': image,
    'heic': image,
    'heif': image,
    'bmp': image,
    'svg': image,
    'tif': image,
    'tiff': image,
    'pdf': pdf,
    'doc': document,
    'docx': document,
    'odt': document,
    'rtf': document,
    'txt': document,
    'md': document,
    'pages': document,
    'xls': spreadsheet,
    'xlsx': spreadsheet,
    'csv': spreadsheet,
    'ods': spreadsheet,
    'numbers': spreadsheet,
    'tsv': spreadsheet,
    'ppt': presentation,
    'pptx': presentation,
    'odp': presentation,
    'key': presentation,
    'mp4': video,
    'mov': video,
    'avi': video,
    'mkv': video,
    'webm': video,
    'm4v': video,
    'mp3': audio,
    'wav': audio,
    'm4a': audio,
    'aac': audio,
    'flac': audio,
    'ogg': audio,
    'zip': archive,
    'rar': archive,
    '7z': archive,
    'tar': archive,
    'gz': archive,
    'tgz': archive,
    'json': code,
    'xml': code,
    'html': code,
    'js': code,
    'dart': code,
    'py': code,
    'yaml': code,
    'yml': code,
    'sql': code,
  };

  /// The kind for a stored file name such as "report.final.PDF".
  static FileKind fromName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return other;
    return _byExtension[name.substring(dot + 1).toLowerCase()] ?? other;
  }
}

/// The type-aware icon well that leads a file row.
class FileKindIcon extends StatelessWidget {
  const FileKindIcon({super.key, required this.kind, this.size = 44});

  final FileKind kind;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: kind.label,
        child: BjIconWell(
          icon: kind.icon,
          size: size,
          // Accent uses the soft accent gradient (tone: null).
          tone: kind.tone == BjTone.accent ? null : kind.tone,
          color: kind.color,
        ),
      );
}
