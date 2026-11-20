// Presentational widgets for Notes. No Firestore or FirebaseAuth here:
// screens map documents onto [NoteSummary] and pass callbacks in, so every
// widget renders in tests with fake data.

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_services/member_identity.dart';
import 'package:shared_ui/initials_avatar.dart';
import 'package:shared_ui/member_identity_widgets.dart';

/// One note in the grid.
class NoteSummary {
  const NoteSummary({
    required this.id,
    this.title = '',
    this.content = '',
    this.lastEdited,
    this.sharedWithMe = false,
    this.sharedCount = 0,
  });

  final String id;
  final String title;
  final String content;
  final DateTime? lastEdited;

  /// Someone else created it and shared it with you.
  final bool sharedWithMe;

  /// How many people you've shared it with (your own notes).
  final int sharedCount;

  String get displayTitle => title.isEmpty ? '(Untitled)' : title;
}

/// Which notes the grid shows.
enum NotesFilter { all, mine, shared }

extension NotesFilterLabel on NotesFilter {
  String get label => switch (this) {
        NotesFilter.all => 'All',
        NotesFilter.mine => 'My notes',
        NotesFilter.shared => 'Shared with me',
      };
}

/// [notes] narrowed by [filter] and a case-insensitive [query] over title
/// and content.
List<NoteSummary> filterNotes(List<NoteSummary> notes,
    {NotesFilter filter = NotesFilter.all, String query = ''}) {
  final q = query.trim().toLowerCase();
  return notes.where((n) {
    if (filter == NotesFilter.mine && n.sharedWithMe) return false;
    if (filter == NotesFilter.shared && !n.sharedWithMe) return false;
    if (q.isEmpty) return true;
    return n.title.toLowerCase().contains(q) ||
        n.content.toLowerCase().contains(q);
  }).toList();
}

/// "Today 4:30 PM", "Yesterday", or "Nov 3, 2026".
String formatEdited(DateTime date, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final days = DateTime(n.year, n.month, n.day)
      .difference(DateTime(date.year, date.month, date.day))
      .inDays;
  if (days == 0) return 'Today ${DateFormat.jm().format(date)}';
  if (days == 1) return 'Yesterday';
  return DateFormat.yMMMd().format(date);
}

/// A note as a card: title, a few lines of the text, when it was edited
/// and whether it's shared.
class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.note, required this.onTap, this.now});

  final NoteSummary note;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final untitled = note.title.isEmpty;
    return BjCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.displayTitle,
            style: text.titleMedium?.copyWith(
                color: untitled ? BjNeutral.inkSubtle : BjNeutral.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: BjSpace.sm),
          Expanded(
            child: Text(
              note.content.isEmpty ? 'No text yet' : note.content,
              style: text.bodyMedium?.copyWith(
                color: note.content.isEmpty
                    ? BjNeutral.inkSubtle
                    : BjNeutral.inkMuted,
                height: 1.45,
                fontStyle: note.content.isEmpty ? FontStyle.italic : null,
              ),
              maxLines: 5,
              overflow: TextOverflow.fade,
            ),
          ),
          const SizedBox(height: BjSpace.md),
          Row(children: [
            if (note.lastEdited != null)
              Expanded(
                child: Text(
                  formatEdited(note.lastEdited!, now: now),
                  style: text.labelSmall?.copyWith(color: BjNeutral.inkSubtle),
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            if (note.sharedWithMe)
              const BjStatusPill(
                  label: 'Shared with you',
                  tone: BjTone.info,
                  icon: Icons.people_alt_outlined)
            else if (note.sharedCount > 0)
              BjStatusPill(
                  label: 'Shared · ${note.sharedCount}',
                  tone: BjTone.accent,
                  icon: Icons.share_outlined),
          ]),
        ],
      ),
    );
  }
}

/// Notes as a responsive card grid with search and a mine/shared filter.
class NotesBoard extends StatefulWidget {
  const NotesBoard({
    super.key,
    required this.notes,
    required this.onOpen,
    required this.onCreate,
    this.now,
  });

  final List<NoteSummary> notes;
  final ValueChanged<NoteSummary> onOpen;
  final VoidCallback onCreate;
  final DateTime? now;

  @override
  State<NotesBoard> createState() => _NotesBoardState();
}

class _NotesBoardState extends State<NotesBoard> {
  String _query = '';
  NotesFilter _filter = NotesFilter.all;

  @override
  Widget build(BuildContext context) {
    final shown = filterNotes(widget.notes, filter: _filter, query: _query);
    final hasShared = widget.notes.any((n) => n.sharedWithMe);
    final cards = [
      for (final n in shown)
        SizedBox(
          height: 196,
          child: NoteCard(
              key: ValueKey(n.id),
              note: n,
              now: widget.now,
              onTap: () => widget.onOpen(n)),
        ),
    ];
    return BjScrollBody(children: [
      BjFilterBar(
        searchHint: 'Search notes',
        onSearchChanged: (v) => setState(() => _query = v),
        filters: [
          for (final f in NotesFilter.values)
            if (f != NotesFilter.shared || hasShared)
              ChoiceChip(
                label: Text(f.label),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
        ],
      ),
      BjSectionHeader(
        title: _filter == NotesFilter.all ? 'All notes' : _filter.label,
        count: shown.length,
      ),
      if (shown.isEmpty)
        BjStateView.empty(
          icon: Icons.search_off_rounded,
          title: 'No notes match',
          message: _query.isEmpty
              ? 'Nothing in this filter yet.'
              : 'Try a different word, or clear the search.',
          compact: true,
        )
      else
        ...BjResponsiveGrid.rows(context, cards,
            minTileWidth: 240, maxColumns: 4),
    ]);
  }
}

/// No notes at all yet.
class NotesEmpty extends StatelessWidget {
  const NotesEmpty({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return BjStateView.empty(
      icon: Icons.sticky_note_2_outlined,
      title: 'Create your first note',
      message: 'Jot down ideas, lists and meeting notes. Share any note with '
          'people in this group.',
      action: FilledButton.icon(
        onPressed: onCreate,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New note'),
      ),
    );
  }
}

/// First load: card-shaped placeholders in the grid.
class NotesSkeleton extends StatelessWidget {
  const NotesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (var i = 0; i < 6; i++)
        const SizedBox(
          height: 196,
          child: BjCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BjSkeleton(width: 140, height: 18),
                SizedBox(height: BjSpace.md),
                BjSkeleton(),
                SizedBox(height: BjSpace.sm),
                BjSkeleton(),
                SizedBox(height: BjSpace.sm),
                BjSkeleton(width: 160),
              ],
            ),
          ),
        ),
    ];
    return BjScrollBody(children: [
      const BjSkeleton(height: 44, radius: BjRadius.pill),
      ...BjResponsiveGrid.rows(context, cards, minTileWidth: 240, maxColumns: 4),
    ]);
  }
}

// ─── Editor ────────────────────────────────────────────────────────────

/// Whether the editor's text matches what's stored.
enum NoteSaveState { saved, unsaved, saving, isNew }

/// A small pill saying whether your edits are saved.
class NoteSaveStatus extends StatelessWidget {
  const NoteSaveStatus({super.key, required this.state});

  final NoteSaveState state;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = switch (state) {
      NoteSaveState.saved => ('Saved', BjTone.success, Icons.check_rounded),
      NoteSaveState.unsaved =>
        ('Unsaved changes', BjTone.warning, Icons.edit_outlined),
      NoteSaveState.saving =>
        ('Saving…', BjTone.info, Icons.cloud_upload_outlined),
      NoteSaveState.isNew => ('Not saved yet', BjTone.neutral, Icons.edit_note),
    };
    return AnimatedSwitcher(
      duration: BjMotion.medium,
      child: BjStatusPill(
          key: ValueKey(state), label: label, tone: tone, icon: icon),
    );
  }
}

/// Who a note is shared with, as avatars plus a count.
///
/// [uids] and [emails] are the note's `sharedWithIds` and
/// `sharedWithEmails`, index for index. Each person shows by their display
/// name from the group member directory, falling back to their email's
/// local part.
class NoteSharedWith extends StatefulWidget {
  const NoteSharedWith({
    super.key,
    required this.emails,
    this.uids = const [],
    this.onAdd,
    this.directory,
  });

  final List<String> emails;
  final List<String> uids;
  final VoidCallback? onAdd;

  /// Defaults to [GroupMemberDirectory.instance].
  final GroupMemberDirectory? directory;

  @override
  State<NoteSharedWith> createState() => _NoteSharedWithState();
}

class _NoteSharedWithState extends State<NoteSharedWith> {
  List<MemberIdentity> _people = const [];
  int _generation = 0;

  GroupMemberDirectory get _dir =>
      widget.directory ?? GroupMemberDirectory.instance;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  @override
  void didUpdateWidget(NoteSharedWith old) {
    super.didUpdateWidget(old);
    if (!listEquals(old.emails, widget.emails) ||
        !listEquals(old.uids, widget.uids) ||
        old.directory != widget.directory) {
      _lookup();
    }
  }

  String? _uidAt(int i) => i < widget.uids.length ? widget.uids[i] : null;

  void _lookup() {
    final generation = ++_generation;
    final count = widget.emails.length > widget.uids.length
        ? widget.emails.length
        : widget.uids.length;
    String? emailAt(int i) => i < widget.emails.length ? widget.emails[i] : null;
    _people = [
      for (var i = 0; i < count; i++)
        _dir.peekIdentity(uid: _uidAt(i), email: emailAt(i)),
    ];
    if (_people.every((p) => p.isResolved)) return;
    Future.wait([
      for (var i = 0; i < count; i++)
        _dir.identify(uid: _uidAt(i), email: emailAt(i)),
    ]).then((found) {
      if (!mounted || generation != _generation) return;
      setState(() => _people = found);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final names = [for (final p in _people) p.label];
    final label = names.isEmpty
        ? 'Only you'
        : names.length <= 2
            ? 'Shared with ${names.join(' and ')}'
            : 'Shared with ${names.take(2).join(', ')} +${names.length - 2}';
    return Row(children: [
      if (names.isEmpty)
        const Icon(Icons.lock_outline_rounded,
            size: 18, color: BjNeutral.inkSubtle)
      else
        SizedBox(
          width: 28.0 + 20 * (names.take(4).length - 1),
          height: 28,
          child: Stack(children: [
            // Right to left, so each avatar overlaps the one after it.
            for (var i = names.take(4).length - 1; i >= 0; i--)
              Positioned(
                left: 20.0 * i,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                      color: BjNeutral.surface, shape: BoxShape.circle),
                  child: Padding(
                    padding: const EdgeInsets.all(1),
                    child: _people[i].hasPhoto
                        ? MemberAvatar.identity(_people[i], radius: 13)
                        : InitialsAvatar(name: names[i], size: 26),
                  ),
                ),
              ),
          ]),
        ),
      const SizedBox(width: BjSpace.sm),
      Flexible(
        child: Text(label,
            style: text.bodySmall?.copyWith(color: BjNeutral.inkMuted),
            overflow: TextOverflow.ellipsis),
      ),
      if (widget.onAdd != null) ...[
        const SizedBox(width: BjSpace.xs),
        TextButton(onPressed: widget.onAdd, child: const Text('Share')),
      ],
    ]);
  }
}

/// The writing surface: a white "paper" card with a big title field, the
/// sharing and save status, and the body text filling the rest.
class NoteEditorBody extends StatelessWidget {
  const NoteEditorBody({
    super.key,
    required this.titleController,
    required this.contentController,
    required this.saveState,
    required this.sharedWithEmails,
    this.sharedWithIds = const [],
    this.lastEdited,
    this.onShare,
    this.autofocus = true,
    this.now,
  });

  final TextEditingController titleController;
  final TextEditingController contentController;
  final NoteSaveState saveState;
  final List<String> sharedWithEmails;

  /// The note's `sharedWithIds`, index for index with [sharedWithEmails].
  final List<String> sharedWithIds;
  final DateTime? lastEdited;
  final VoidCallback? onShare;
  final bool autofocus;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final compact = BjBreakpoint.isCompact(width);
    final plain = const InputDecoration(
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    );
    return BjContent(
      maxWidth: BjBreakpoint.formWidth,
      child: Padding(
        padding: EdgeInsets.only(
            top: BjSpace.xs, bottom: compact ? BjSpace.md : BjSpace.xl),
        child: Container(
          decoration: BoxDecoration(
            color: BjNeutral.surface,
            borderRadius: BjRadius.all(BjRadius.xl),
            border: Border.all(color: BjNeutral.border),
            boxShadow: bj.shadowMd,
          ),
          padding: EdgeInsets.fromLTRB(
              compact ? BjSpace.lg : BjSpace.xxl,
              compact ? BjSpace.lg : BjSpace.xl,
              compact ? BjSpace.lg : BjSpace.xxl,
              BjSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: BjSpace.sm,
                runSpacing: BjSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  NoteSaveStatus(state: saveState),
                  if (lastEdited != null)
                    Text('Edited ${formatEdited(lastEdited!, now: now)}',
                        style: text.labelSmall
                            ?.copyWith(color: BjNeutral.inkSubtle)),
                ],
              ),
              const SizedBox(height: BjSpace.md),
              TextField(
                controller: titleController,
                decoration: plain.copyWith(hintText: 'Title'),
                style: text.headlineSmall,
                textCapitalization: TextCapitalization.sentences,
                maxLines: null,
              ),
              const SizedBox(height: BjSpace.md),
              NoteSharedWith(
                  emails: sharedWithEmails,
                  uids: sharedWithIds,
                  onAdd: onShare),
              const Divider(height: BjSpace.xl),
              Expanded(
                child: TextField(
                  controller: contentController,
                  autofocus: autofocus,
                  decoration: plain.copyWith(hintText: 'Start writing…'),
                  style: text.bodyLarge?.copyWith(height: 1.6),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: null, // Allows multiline input
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for the editor while the note loads.
class NoteEditorSkeleton extends StatelessWidget {
  const NoteEditorSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const BjContent(
      maxWidth: BjBreakpoint.formWidth,
      child: BjCard(
        padding: EdgeInsets.all(BjSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BjSkeleton(width: 90, height: 20, radius: BjRadius.pill),
            SizedBox(height: BjSpace.lg),
            BjSkeleton(width: 260, height: 28),
            SizedBox(height: BjSpace.xl),
            BjSkeleton(),
            SizedBox(height: BjSpace.sm),
            BjSkeleton(),
            SizedBox(height: BjSpace.sm),
            BjSkeleton(width: 200),
          ],
        ),
      ),
    );
  }
}

/// What to do with unsaved edits when leaving.
enum NoteExitAction { cancel, discard, saveAndExit }

/// Asks whether to save, discard or keep editing before leaving.
Future<NoteExitAction?> showNoteUnsavedDialog(BuildContext context) {
  return showDialog<NoteExitAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Center(
          child: BjIconWell(
              icon: Icons.edit_note_rounded, tone: BjTone.warning, size: 52)),
      title: const Text('Save your changes?', textAlign: TextAlign.center),
      content: const Text(
        'This note has edits that aren\'t saved yet. Discarding them keeps '
        'the last saved version.',
        textAlign: TextAlign.center,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(NoteExitAction.cancel),
          child: const Text('Keep editing'),
        ),
        TextButton(
          style: TextButton.styleFrom(
              foregroundColor: ctx.bj.tone(BjTone.danger).foreground),
          onPressed: () => Navigator.of(ctx).pop(NoteExitAction.discard),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(NoteExitAction.saveAndExit),
          child: const Text('Save and exit'),
        ),
      ],
    ),
  );
}

/// What deleting a note takes away, for the confirm dialog.
List<String> noteDeleteConsequences({
  required int sharedCount,
  required bool createdByMe,
}) =>
    [
      'The title and text are deleted for good',
      if (sharedCount > 0)
        '$sharedCount ${sharedCount == 1 ? 'person' : 'people'} it\'s shared '
            'with lose it too',
      if (!createdByMe) 'Whoever shared it with you loses it as well',
    ];

/// The editor page: title, a Save button that carries the unsaved
/// dot, and Delete in the overflow menu, last and red.
class NoteEditorPage extends StatelessWidget {
  const NoteEditorPage({
    super.key,
    required this.isNew,
    required this.saving,
    required this.dirty,
    required this.onSave,
    required this.body,
    this.onDelete,
  });

  final bool isNew;
  final bool saving;
  final bool dirty;
  final VoidCallback onSave;

  /// Null for a note that isn't saved yet.
  final VoidCallback? onDelete;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: isNew ? 'New Note' : 'Edit Note',
      maxWidth: BjBreakpoint.formWidth,
      actions: [
        Badge(
          isLabelVisible: dirty && !saving,
          smallSize: 10,
          child: BjBusyButton(
            label: 'Save',
            icon: Icons.check_rounded,
            busy: saving,
            onPressed: onSave,
          ),
        ),
        if (onDelete != null)
          BjOverflowMenu(actions: [
            BjMenuAction(
              label: 'Delete note',
              icon: Icons.delete_outline_rounded,
              destructive: true,
              enabled: !saving,
              onSelected: onDelete!,
            ),
          ]),
      ],
      body: body,
    );
  }
}
