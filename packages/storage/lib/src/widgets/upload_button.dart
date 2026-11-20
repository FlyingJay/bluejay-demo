import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';

/// The upload FAB. While an upload runs it shows a progress ring and the
/// percentage, and can't be pressed again.
class UploadButton extends StatelessWidget {
  const UploadButton({
    super.key,
    required this.isUploading,
    required this.progress,
    required this.onPressed,
  });

  final bool isUploading;

  /// 0 to 1.
  final double progress;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => BjProgressFab(
        icon: Icons.upload_rounded,
        label: 'Upload',
        tooltip: 'Upload a file',
        busy: isUploading,
        progress: progress,
        busyLabel: (percent) => 'Uploading $percent%',
        onPressed: onPressed,
      );
}
