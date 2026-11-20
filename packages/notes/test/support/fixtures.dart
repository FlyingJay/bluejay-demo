import 'package:flutter/material.dart';
import 'package:notes/notes_widgets.dart';

final now = DateTime(2026, 11, 10, 16, 30);

final sampleNotes = [
  NoteSummary(
    id: 'n1',
    title: 'Q4 planning',
    content: 'Goals: ship purchasable groups, onboard two insurance '
        'tenants, cut CI spend by a third.\n\nOwners: Jay, Maya.',
    lastEdited: now.subtract(const Duration(minutes: 40)),
    sharedCount: 2,
  ),
  NoteSummary(
    id: 'n2',
    title: 'Groceries',
    content: 'Oat milk\nBlueberries\nSourdough\nCoffee beans\nLemons',
    lastEdited: now.subtract(const Duration(days: 1)),
  ),
  NoteSummary(
    id: 'n3',
    title: 'Client call notes: Winnipeg',
    content: 'They want the claim intake form to save drafts, and a summary '
        'email after each submission. Follow up on SSO by Friday.',
    lastEdited: now.subtract(const Duration(days: 3)),
    sharedWithMe: true,
  ),
  NoteSummary(
    id: 'n4',
    content: 'Idea: a weekly digest of what changed in each app.',
    lastEdited: now.subtract(const Duration(days: 8)),
  ),
  NoteSummary(
    id: 'n5',
    title: 'Book list',
    lastEdited: now.subtract(const Duration(days: 30)),
  ),
];

/// The editor with fake text, laid out like NoteDetailScreen.
class EditorHarness extends StatefulWidget {
  const EditorHarness({
    super.key,
    this.isNew = false,
    this.dirty = false,
    this.loading = false,
    this.shared = const ['maya.chen@example.com', 'devon@example.com'],
  });

  final bool isNew;
  final bool dirty;
  final bool loading;
  final List<String> shared;

  @override
  State<EditorHarness> createState() => _EditorHarnessState();
}

class _EditorHarnessState extends State<EditorHarness> {
  late final _title =
      TextEditingController(text: widget.isNew ? '' : 'Q4 planning');
  late final _content = TextEditingController(
      text: widget.isNew
          ? ''
          : 'Goals\n• Ship purchasable groups\n• Onboard two insurance '
              'tenants\n• Cut CI spend by a third\n\nOwners: Jay, Maya.\n'
              'Review on the first Monday of each month.');

  @override
  Widget build(BuildContext context) {
    final state = widget.isNew
        ? NoteSaveState.isNew
        : widget.dirty
            ? NoteSaveState.unsaved
            : NoteSaveState.saved;
    return NoteEditorPage(
      isNew: widget.isNew,
      saving: false,
      dirty: widget.dirty,
      onSave: () {},
      onDelete: widget.isNew ? null : () {},
      body: widget.loading
          ? const NoteEditorSkeleton()
          : NoteEditorBody(
              titleController: _title,
              contentController: _content,
              saveState: state,
              sharedWithEmails: widget.isNew ? const [] : widget.shared,
              lastEdited: widget.isNew ? null : now.subtract(const Duration(minutes: 40)),
              onShare: () {},
              autofocus: false,
              now: now,
            ),
    );
  }
}
