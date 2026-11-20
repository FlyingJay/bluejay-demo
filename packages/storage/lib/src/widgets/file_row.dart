import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/member_identity_widgets.dart';

import '../file_kind.dart';
import '../format.dart';
import '../models.dart';

/// What a file row can do. Every callback is the screen's own handler; the
/// row only decides which ones to offer.
class FileRowActions {
  const FileRowActions({
    required this.onOpen,
    required this.onDownload,
    required this.onCopyLink,
    required this.onShare,
    required this.onDelete,
    this.onMove,
  });

  final VoidCallback onOpen;

  /// Moves the file into a folder; null where it can't be moved.
  final VoidCallback? onMove;
  final VoidCallback onDownload;
  final VoidCallback onCopyLink;
  final VoidCallback onShare;
  final VoidCallback onDelete;
}

/// The public/private label shown on every file.
class VisibilityPill extends StatelessWidget {
  const VisibilityPill({super.key, required this.isPublic});

  final bool isPublic;

  @override
  Widget build(BuildContext context) => isPublic
      ? const BjStatusPill(
          label: 'Public', tone: BjTone.info, icon: Icons.public_rounded)
      : const BjStatusPill(
          label: 'Private', tone: BjTone.neutral, icon: Icons.lock_rounded);
}

/// The overflow menu for [file], in a fixed order: details, copy link
/// (public files only), download, move to folder and share (owner only),
/// then delete (owner only, red, last).
List<BjMenuAction> fileMenuActions(
  SharedFile file, {
  required bool isOwner,
  required FileRowActions actions,
}) =>
    [
      BjMenuAction(
          label: 'File details',
          icon: Icons.info_outline_rounded,
          onSelected: actions.onOpen),
      if (file.isPublic)
        BjMenuAction(
            label: 'Copy link',
            icon: Icons.link_rounded,
            onSelected: actions.onCopyLink),
      BjMenuAction(
          label: 'Download',
          icon: Icons.download_rounded,
          onSelected: actions.onDownload),
      if (isOwner && actions.onMove != null)
        BjMenuAction(
            label: 'Move to folder',
            icon: Icons.drive_file_move_outlined,
            onSelected: actions.onMove!),
      if (isOwner)
        BjMenuAction(
            label: 'Share',
            icon: Icons.person_add_alt_rounded,
            onSelected: actions.onShare),
      if (isOwner)
        BjMenuAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: actions.onDelete),
    ];

/// One file: type icon, name, who uploaded or shared it, then visibility,
/// size and date at a glance. Download is one tap on wider screens;
/// everything else is in the overflow menu. Tapping the row opens the file's details.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.file,
    required this.isOwner,
    required this.showSharer,
    required this.actions,
  });

  final SharedFile file;
  final bool isOwner;

  /// On the Shared tab the subtitle names who shared the file.
  final bool showSharer;
  final FileRowActions actions;

  @override
  Widget build(BuildContext context) => MemberIdentityBuilder(
        uid: file.userId,
        email: file.userEmail,
        unknown: '',
        builder: (context, owner) => _row(context, owner.label),
      );

  Widget _row(BuildContext context, String username) {
    final sharedCount = file.sharedWithIds.length;
    // Phones keep Download in the menu so the name and pills get the room.
    final compact = BjBreakpoint.isCompact(MediaQuery.sizeOf(context).width);
    return BjListRow(
      leading: FileKindIcon(kind: FileKind.fromName(file.fileName)),
      title: file.displayName ?? file.fileName,
      subtitle: [
        if (username.isNotEmpty)
          showSharer ? 'Shared by $username' : 'Uploaded by $username',
        formatDateShort(file.createdAt.toDate()),
      ].join(' · '),
      meta: [
        VisibilityPill(isPublic: file.isPublic),
        BjStatusPill(
            label: formatBytes(file.size), icon: Icons.data_usage_rounded),
        if (isOwner && sharedCount > 0)
          BjStatusPill(
            label: 'Shared with $sharedCount',
            tone: BjTone.accent,
            icon: Icons.group_rounded,
          ),
      ],
      onTap: actions.onOpen,
      trailing: compact
          ? null
          : IconButton.filledTonal(
              tooltip: 'Download',
              onPressed: actions.onDownload,
              icon: const Icon(Icons.download_rounded),
            ),
      actions: fileMenuActions(file, isOwner: isOwner, actions: actions),
    );
  }
}
