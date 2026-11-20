/// Read-only display of a ticket's attachments (Improve Apps bug reports and
/// ideas): a swipeable image carousel that opens a zoomable fullscreen
/// viewer, plus chips for non-image files. Only https URLs on our own
/// Storage hosts are ever shown, so a ticket can't make a viewer's browser
/// load an arbitrary third-party URL.
///
/// Used by Dev Pipeline's request sheet (moved here from Improve Apps
/// Admin); other ticket screens can adopt it instead of their own copies.
library;

import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'clickable_url.dart';
import 'fullscreen_image_viewer.dart';

/// Hosts a ticket attachment may be loaded from.
const Set<String> trustedAttachmentHosts = {
  'firebasestorage.googleapis.com',
  'storage.googleapis.com',
};

const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
  '.heif',
};

/// Whether [url] is an https URL on one of [trustedAttachmentHosts].
bool isTrustedAttachmentUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty || uri.scheme != 'https') return false;
  return trustedAttachmentHosts.contains(uri.host.toLowerCase());
}

/// One file attached to a ticket.
class TicketAttachment {
  final String url;
  final String name;
  final String? contentType;
  final int? sizeBytes;
  final DateTime? uploadedAt;

  const TicketAttachment({
    required this.url,
    this.name = '',
    this.contentType,
    this.sizeBytes,
    this.uploadedAt,
  });

  /// Parses a Firestore attachment map, or the same shape from a callable
  /// result (where `uploadedAt` is an ISO string).
  factory TicketAttachment.fromMap(Map<Object?, Object?> data) {
    final uploadedAt = data['uploadedAt'];
    return TicketAttachment(
      url: (data['url'] is String ? data['url'] as String : '').trim(),
      name: (data['name'] is String ? data['name'] as String : '').trim(),
      contentType: data['contentType'] is String ? data['contentType'] as String : null,
      sizeBytes: data['sizeBytes'] is num ? (data['sizeBytes'] as num).toInt() : null,
      uploadedAt: uploadedAt is Timestamp
          ? uploadedAt.toDate()
          : (uploadedAt is String ? DateTime.tryParse(uploadedAt) : null),
    );
  }

  /// `name`, or `Attachment` when it has none.
  String get displayName => name.isEmpty ? 'Attachment' : name;

  bool get isTrusted => isTrustedAttachmentUrl(url);

  /// By content type, else by the file extension of its name or URL.
  bool get isImage {
    if ((contentType ?? '').toLowerCase().startsWith('image/')) return true;
    bool looksLikeImage(String value) {
      final path = value.split('?').first.toLowerCase();
      return _imageExtensions.any(path.endsWith);
    }

    return looksLikeImage(name) || looksLikeImage(Uri.decodeFull(url));
  }
}

/// A ticket document's attachments: its `attachments` list, else the legacy
/// `imageUrls`/`imageUrl` screenshots. Untrusted URLs are dropped.
List<TicketAttachment> ticketAttachmentsFromData(Map<Object?, Object?> data) {
  final raw = data['attachments'];
  var attachments = (raw is List ? raw : const [])
      .whereType<Map>()
      .map((m) => TicketAttachment.fromMap(Map<Object?, Object?>.from(m)))
      .where((a) => a.url.isNotEmpty)
      .toList();
  if (attachments.isEmpty) {
    final imageUrls = data['imageUrls'];
    final legacy = imageUrls is List ? imageUrls : [data['imageUrl']];
    attachments = legacy
        .whereType<String>()
        .where((url) => url.trim().isNotEmpty)
        .map((url) => TicketAttachment(url: url.trim(), name: 'Screenshot', contentType: 'image/*'))
        .toList();
  }
  return attachments.where((a) => a.isTrusted).toList();
}

/// Images as a carousel, other files as chips. Untrusted attachments are
/// filtered out here too; renders nothing when none remain.
class TicketAttachmentGallery extends StatelessWidget {
  final List<TicketAttachment> attachments;

  /// Height of the inline carousel.
  final double imageHeight;

  const TicketAttachmentGallery({
    super.key,
    required this.attachments,
    this.imageHeight = 160,
  });

  @override
  Widget build(BuildContext context) {
    final safe = attachments.where((a) => a.isTrusted).toList();
    final images = safe.where((a) => a.isImage).toList();
    final files = safe.where((a) => !a.isImage).toList();
    if (safe.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (images.isNotEmpty) TicketAttachmentCarousel(attachments: images, height: imageHeight),
        if (images.isNotEmpty && files.isNotEmpty) const SizedBox(height: BjSpace.sm),
        if (files.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final file in files)
                ActionChip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(file.displayName),
                  tooltip: file.url,
                  onPressed: () => _showAttachmentLink(context, file),
                ),
            ],
          ),
      ],
    );
  }
}

Future<void> _showAttachmentLink(BuildContext context, TicketAttachment attachment) {
  return showBjSheet<void>(
    context,
    title: attachment.displayName,
    subtitle: 'This file opens outside the app.',
    builder: (sheetContext) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BjCard(
          padding: const EdgeInsets.all(BjSpace.md),
          child: buildClickableText(sheetContext, attachment.url),
        ),
        const SizedBox(height: BjSpace.md),
        const BjInlineNote('Tap the link to open it.',
            icon: Icons.open_in_new_rounded),
      ],
    ),
  );
}

/// Swipeable (and mouse-draggable) image strip with page dots; tapping an
/// image opens [TicketAttachmentFullscreenViewer].
class TicketAttachmentCarousel extends StatefulWidget {
  final List<TicketAttachment> attachments;
  final double height;

  const TicketAttachmentCarousel({
    super.key,
    required this.attachments,
    this.height = 160,
  });

  @override
  State<TicketAttachmentCarousel> createState() => _TicketAttachmentCarouselState();
}

class _TicketAttachmentCarouselState extends State<TicketAttachmentCarousel> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _openFullscreen(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TicketAttachmentFullscreenViewer(
          attachments: widget.attachments,
          initialIndex: index,
        ),
      ),
    );
  }

  Widget _image(int index) {
    final attachment = widget.attachments[index];
    return ClipRRect(
      borderRadius: BjRadius.all(BjRadius.lg),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openFullscreen(index),
          child: Image.network(
            attachment.url,
            fit: BoxFit.cover,
            width: double.infinity,
            semanticLabel: attachment.name.isEmpty ? 'Attachment image' : attachment.name,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : BjSkeleton(height: widget.height, radius: BjRadius.lg),
            errorBuilder: (_, __, ___) => Container(
              height: widget.height,
              color: BjNeutral.surfaceMuted,
              child: const Center(
                child: Icon(Icons.broken_image_rounded, color: BjNeutral.inkSubtle),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.attachments.length == 1) {
      return SizedBox(height: widget.height, child: _image(0));
    }
    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.attachments.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (_, index) => _image(index),
          ),
        ),
        const SizedBox(height: 8),
        ImagePageDots(
          count: widget.attachments.length,
          current: _currentPage,
          activeColor: context.bj.accent,
          inactiveColor: BjNeutral.borderStrong,
          onTap: (index) => _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        ),
      ],
    );
  }
}

/// Black fullscreen pager with pinch/scroll zoom over a ticket's images.
class TicketAttachmentFullscreenViewer extends StatelessWidget {
  final List<TicketAttachment> attachments;
  final int initialIndex;

  const TicketAttachmentFullscreenViewer({
    super.key,
    required this.attachments,
    this.initialIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    return FullscreenImageViewer(
      images: [
        for (final a in attachments) FullscreenImage(url: a.url, label: a.name),
      ],
      initialIndex: initialIndex,
    );
  }
}
