import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/scoped_storage.dart';
import 'package:shared_services/service_locator.dart';
import 'package:url_launcher/url_launcher.dart';

/// "Preview" and "Download" buttons for a file in Firebase Storage, e.g. a
/// document attached to an application or policy.
///
/// Preview opens the file in a new tab (web) or the platform viewer, where
/// PDFs and images render inline; Download saves it under [fileName] (see
/// [PlatformService.downloadFile]). Pass the stored [downloadUrl] when the
/// record has one; otherwise it is resolved from [storagePath], which needs
/// the viewer to have Storage read access to it. Renders nothing when
/// neither is set.
class StoredFileActions extends StatelessWidget {
  const StoredFileActions({
    super.key,
    required this.fileName,
    this.downloadUrl,
    this.storagePath,
    this.color,
    this.showPreview = true,
  });

  final String fileName;
  final String? downloadUrl;
  final String? storagePath;

  /// Button foreground colour; defaults to the theme's primary colour.
  final Color? color;

  /// Whether to offer Preview; off for formats a browser can't show inline.
  final bool showPreview;

  bool get _hasSource =>
      (downloadUrl?.trim().isNotEmpty ?? false) ||
      (storagePath?.trim().isNotEmpty ?? false);

  Future<String> _resolveUrl() async {
    final url = downloadUrl?.trim() ?? '';
    if (url.isNotEmpty) return url;
    return ScopedStorage.refForPath(storagePath!.trim()).getDownloadURL();
  }

  Future<void> _preview(BuildContext context) async {
    try {
      final opened = await launchUrl(
        Uri.parse(await _resolveUrl()),
        webOnlyWindowName: '_blank',
      );
      if (!opened) throw Exception('no app can open it');
    } catch (e) {
      if (context.mounted) BjSnack.error(context, 'Couldn\'t open $fileName. Please try again.');
    }
  }

  Future<void> _download(BuildContext context) async {
    try {
      final url = await _resolveUrl();
      if (!context.mounted) return;
      await getPlatformService().downloadFile(context, url, fileName);
    } catch (e) {
      if (context.mounted) BjSnack.error(context, 'Couldn\'t download $fileName. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSource) return const SizedBox.shrink();
    final style = TextButton.styleFrom(
      foregroundColor: color,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    return Wrap(
      spacing: 4,
      children: [
        if (showPreview)
        TextButton.icon(
          style: style,
          onPressed: () => _preview(context),
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('Preview'),
        ),
        TextButton.icon(
          style: style,
          onPressed: () => _download(context),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('Download'),
        ),
      ],
    );
  }
}
