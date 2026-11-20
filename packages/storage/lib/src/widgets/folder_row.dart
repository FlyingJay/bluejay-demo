import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/member_identity_widgets.dart';

import '../models.dart';

/// What a folder row can do. Every callback is the screen's own handler;
/// the row only decides which ones to offer.
class FolderRowActions {
  const FolderRowActions({
    required this.onOpen,
    required this.onRename,
    required this.onMove,
    required this.onShare,
    required this.onDelete,
  });

  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onShare;
  final VoidCallback onDelete;
}

/// The overflow menu for a folder: open, then for its owner rename, move,
/// share (which shares everything in it) and delete (red, last).
List<BjMenuAction> folderMenuActions({
  required bool isOwner,
  required FolderRowActions actions,
}) =>
    [
      BjMenuAction(
          label: 'Open', icon: Icons.folder_open_rounded, onSelected: actions.onOpen),
      if (isOwner) ...[
        BjMenuAction(
            label: 'Rename', icon: Icons.edit_outlined, onSelected: actions.onRename),
        BjMenuAction(
            label: 'Move to folder',
            icon: Icons.drive_file_move_outlined,
            onSelected: actions.onMove),
        BjMenuAction(
            label: 'Share',
            icon: Icons.person_add_alt_rounded,
            onSelected: actions.onShare),
        BjMenuAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: actions.onDelete),
      ],
    ];

/// One folder: its name, how much is in it and, for its owner, who it is
/// shared with. Tapping it opens it.
class FolderRow extends StatelessWidget {
  const FolderRow({
    super.key,
    required this.folder,
    required this.itemCount,
    required this.isOwner,
    required this.showSharer,
    required this.actions,
  });

  final SharedFile folder;

  /// Items directly inside it.
  final int itemCount;
  final bool isOwner;

  /// On the Shared tab the subtitle names who shared it.
  final bool showSharer;
  final FolderRowActions actions;

  @override
  Widget build(BuildContext context) => MemberIdentityBuilder(
        uid: folder.userId,
        email: folder.userEmail,
        unknown: '',
        builder: (context, owner) => _row(owner.label),
      );

  Widget _row(String username) {
    final sharedCount = folder.sharedWithIds.length;
    return BjListRow(
      leading: const BjIconWell(icon: Icons.folder_rounded),
      title: folder.name,
      subtitle: [
        itemCount == 1 ? '1 item' : '$itemCount items',
        if (showSharer && username.isNotEmpty) 'Shared by $username',
      ].join(' · '),
      meta: [
        if (isOwner && sharedCount > 0)
          BjStatusPill(
            label: 'Shared with $sharedCount',
            tone: BjTone.accent,
            icon: Icons.group_rounded,
          ),
      ],
      onTap: actions.onOpen,
      actions: folderMenuActions(isOwner: isOwner, actions: actions),
    );
  }
}

/// Where a tab is in its folders: the tab's top level, then each folder
/// down to the open one, each a step back up. [onNewFolder] adds a folder
/// here (null where the player can't, as on the Shared tab).
class FolderBar extends StatelessWidget {
  const FolderBar({
    super.key,
    required this.rootLabel,
    required this.path,
    required this.onOpen,
    this.onNewFolder,
  });

  final String rootLabel;

  /// The folders from the top level down to the open one.
  final List<SharedFile> path;

  /// Opens a folder (null for the top level).
  final ValueChanged<String?> onOpen;
  final VoidCallback? onNewFolder;

  @override
  Widget build(BuildContext context) {
    final crumbs = <(String?, String)>[
      (null, rootLabel),
      for (final f in path) (f.id, f.name),
    ];
    return Row(
      children: [
        if (path.isNotEmpty)
          IconButton(
            tooltip: 'Back to ${crumbs[crumbs.length - 2].$2}',
            icon: const Icon(Icons.arrow_upward_rounded),
            onPressed: () => onOpen(crumbs[crumbs.length - 2].$1),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: [
                for (final (i, (id, label)) in crumbs.indexed) ...[
                  if (i > 0) const Icon(Icons.chevron_right_rounded, size: 18),
                  TextButton(
                    onPressed: i == crumbs.length - 1 ? null : () => onOpen(id),
                    child: Text(label),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (onNewFolder != null)
          OutlinedButton.icon(
            onPressed: onNewFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('New folder'),
          ),
      ],
    );
  }
}
