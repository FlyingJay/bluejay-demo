import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui/member_identity_widgets.dart';

import '../file_kind.dart';
import '../format.dart';
import '../models.dart';
import 'file_row.dart';

/// What the user picked before an upload starts.
typedef UploadDetails = ({String name, bool isPublic});

/// Asks for the new file's name and who can see it. Resolves to null when
/// cancelled. Upload stays disabled until a visibility is picked and the
/// name isn't blank, so neither is ever chosen by default.
Future<UploadDetails?> showUploadDetailsDialog(
  BuildContext context, {
  required String initialName,
  required String originalFileName,
}) {
  return showDialog<UploadDetails>(
    context: context,
    builder: (_) => _UploadDetailsDialog(
      initialName: initialName,
      originalFileName: originalFileName,
    ),
  );
}

class _UploadDetailsDialog extends StatefulWidget {
  const _UploadDetailsDialog({
    required this.initialName,
    required this.originalFileName,
  });

  final String initialName;
  final String originalFileName;

  @override
  State<_UploadDetailsDialog> createState() => _UploadDetailsDialogState();
}

class _UploadDetailsDialogState extends State<_UploadDetailsDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  bool? _isPublic;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _isPublic != null && _name.text.trim().isNotEmpty;

  void _submit() {
    if (!_ready) return;
    Navigator.pop<UploadDetails>(
        context, (name: _name.text, isPublic: _isPublic!));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      icon: Center(
        child: FileKindIcon(
            kind: FileKind.fromName(widget.originalFileName), size: 52),
      ),
      title: const Text('Upload a file', textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.originalFileName,
                  style: text.bodySmall,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: BjSpace.lg),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'File name',
                  hintText: 'Enter a name for this file',
                ),
              ),
              const SizedBox(height: BjSpace.lg),
              Text('Who can see it?', style: text.titleSmall),
              const SizedBox(height: BjSpace.sm),
              BjOptionCards<bool>(
                value: _isPublic,
                onChanged: (v) => setState(() => _isPublic = v),
                options: const [
                  BjOption(
                    value: true,
                    title: 'Public',
                    icon: Icons.public_rounded,
                    tone: BjTone.info,
                    description:
                        'In the Public tab. Anyone signed in to Bluejay can open its link.',
                  ),
                  BjOption(
                    value: false,
                    title: 'Private',
                    icon: Icons.lock_rounded,
                    tone: BjTone.neutral,
                    description:
                        'Stays in this group, for you and anyone you share it with.',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _ready ? _submit : null,
          icon: const Icon(Icons.upload_rounded, size: 18),
          label: const Text('Upload'),
        ),
      ],
    );
  }
}

/// A file's details: type, size, uploader, date, visibility and how its
/// link works, with Download as the main action.
Future<void> showFileDetailsDialog(
  BuildContext context, {
  required SharedFile file,
  required VoidCallback onCopyLink,
  required VoidCallback onDownload,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      final kind = FileKind.fromName(file.fileName);
      return AlertDialog(
        icon: Center(child: FileKindIcon(kind: kind, size: 52)),
        title: Text(file.displayName ?? file.fileName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: VisibilityPill(isPublic: file.isPublic)),
                const SizedBox(height: BjSpace.lg),
                BjDetailTable(rows: [
                  BjKeyValue(label: 'Type', value: kind.label),
                  BjKeyValue(label: 'Size', value: formatBytes(file.size)),
                  if (file.userId.isNotEmpty || file.userEmail.isNotEmpty)
                    BjKeyValue(
                      label: 'Uploaded by',
                      child: MemberName(uid: file.userId, email: file.userEmail),
                    ),
                  BjKeyValue(
                      label: 'Uploaded',
                      value: formatDateTime(file.createdAt.toDate())),
                  if (file.fileName.isNotEmpty &&
                      file.fileName != file.displayName)
                    BjKeyValue(label: 'Original name', value: file.fileName),
                ]),
                const SizedBox(height: BjSpace.lg),
                BjCard(
                  padding: const EdgeInsets.all(BjSpace.md),
                  tone: file.isPublic ? BjTone.info : BjTone.neutral,
                  child: Row(children: [
                    Icon(
                        file.isPublic ? Icons.link_rounded : Icons.lock_rounded,
                        size: 18,
                        color: context.bj
                            .tone(file.isPublic ? BjTone.info : BjTone.neutral)
                            .foreground),
                    const SizedBox(width: BjSpace.sm),
                    Expanded(
                      child: Text(
                        file.isPublic
                            ? "Anyone signed in to Bluejay can open this file's link."
                            : 'Private files must be downloaded from inside Bluejay.',
                        style: text.bodySmall?.copyWith(color: BjNeutral.ink),
                      ),
                    ),
                    if (file.isPublic)
                      IconButton(
                        tooltip: 'Copy link',
                        onPressed: onCopyLink,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                      ),
                  ]),
                ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              onDownload();
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Download'),
          ),
        ],
      );
    },
  );
}

/// What deleting [file] loses, for the delete confirmation. Matches what
/// the storageDeleteFile function does: it deletes the stored object and
/// the file's doc, and the doc's delete triggers the public namespace
/// re-sync, which removes the published copy and its public_files entry.
List<String> deleteConsequences(SharedFile file) {
  final shared = file.sharedWithIds.length;
  return [
    'The file and its stored copy are deleted for good. This can\'t be undone.',
    if (shared > 0)
      shared == 1
          ? 'The person you shared it with loses access right away.'
          : 'The $shared people you shared it with lose access right away.',
    if (file.isPublic)
      'Its public link stops working and it leaves the Public tab.',
  ];
}

/// Confirms deleting [file], listing what will be lost.
Future<bool> confirmDeleteFile(BuildContext context, SharedFile file) =>
    showBjConfirm(
      context,
      title: 'Delete "${file.displayName ?? file.fileName}"?',
      consequences: deleteConsequences(file),
      confirmLabel: 'Delete file',
      destructive: true,
    );

/// Asks for a folder's name: a new folder's, or a new name for one
/// ([initialName]). Resolves to the trimmed name, or null when cancelled.
Future<String?> showFolderNameDialog(
  BuildContext context, {
  String initialName = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _FolderNameDialog(initialName: initialName),
    );

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({required this.initialName});

  final String initialName;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _renaming => widget.initialName.isNotEmpty;

  void _submit() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.create_new_folder_outlined),
        title: Text(_renaming ? 'Rename folder' : 'New folder'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Folder name'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : _submit,
            child: Text(_renaming ? 'Rename' : 'Create'),
          ),
        ],
      );
}

/// Where to move an item: the top level of your files, or one of
/// [targets] (each shown by its [pathOf]). Resolves to the folder's id, ''
/// for the top level, or null when cancelled.
Future<String?> showMoveToFolderSheet(
  BuildContext context, {
  required String itemName,
  required List<SharedFile> targets,
  required String Function(SharedFile folder) pathOf,
  required bool atTopLevel,
}) =>
    showBjSheet<String>(
      context,
      title: 'Move "$itemName" to',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!atTopLevel)
            BjListRow(
              leading: const BjIconWell(icon: Icons.home_outlined),
              title: 'Your files',
              subtitle: 'The top level',
              onTap: () => Navigator.pop(ctx, ''),
            ),
          for (final folder in targets) ...[
            const SizedBox(height: BjSpace.sm),
            BjListRow(
              leading: const BjIconWell(icon: Icons.folder_rounded),
              title: pathOf(folder),
              onTap: () => Navigator.pop(ctx, folder.id),
            ),
          ],
          if (targets.isEmpty && atTopLevel)
            const Padding(
              padding: EdgeInsets.all(BjSpace.md),
              child: Text('Make a folder first, then move files into it.'),
            ),
        ],
      ),
    );

/// What deleting folder [folder] loses: the [items] of yours inside it go
/// with it, and those it is shared with lose them.
List<String> deleteFolderConsequences(SharedFile folder, int items) {
  final shared = folder.sharedWithIds.length;
  return [
    items == 0
        ? 'The folder is deleted. It\'s empty.'
        : items == 1
            ? 'The folder and the 1 item in it are deleted for good. This can\'t be undone.'
            : 'The folder and the $items items in it are deleted for good. This can\'t be undone.',
    if (shared > 0)
      shared == 1
          ? 'The person you shared it with loses access right away.'
          : 'The $shared people you shared it with lose access right away.',
  ];
}

/// Confirms deleting [folder] and the [items] of yours inside it.
Future<bool> confirmDeleteFolder(BuildContext context, SharedFile folder, int items) =>
    showBjConfirm(
      context,
      title: 'Delete "${folder.name}"?',
      consequences: deleteFolderConsequences(folder, items),
      confirmLabel: 'Delete folder',
      destructive: true,
    );
