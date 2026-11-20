import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/notes_widgets.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/group_member_directory.dart';

import 'support/fixtures.dart';

Widget _app(Widget child) => MaterialApp(
      theme: BluejayTheme.build(),
      home: Scaffold(body: child),
    );

void main() {

  test('filterNotes by owner and text', () {
    expect(filterNotes(sampleNotes, filter: NotesFilter.shared).map((n) => n.id),
        ['n3']);
    expect(filterNotes(sampleNotes, filter: NotesFilter.mine).length, 4);
    expect(filterNotes(sampleNotes, query: 'BLUEBERR').single.id, 'n2');
  });

  test('delete consequences name who loses the note', () {
    expect(noteDeleteConsequences(sharedCount: 0, createdByMe: true).length, 1);
    expect(noteDeleteConsequences(sharedCount: 2, createdByMe: true),
        contains('2 people it\'s shared with lose it too'));
    expect(noteDeleteConsequences(sharedCount: 1, createdByMe: false).length, 3);
  });

  testWidgets('note card shows title, untitled fallback and sharing',
      (t) async {
    await t.pumpWidget(_app(Column(children: [
      SizedBox(height: 196, child: NoteCard(note: sampleNotes[0], onTap: () {}, now: now)),
      SizedBox(height: 196, child: NoteCard(note: sampleNotes[3], onTap: () {}, now: now)),
      SizedBox(height: 196, child: NoteCard(note: sampleNotes[2], onTap: () {}, now: now)),
    ])));
    expect(find.text('Q4 planning'), findsOneWidget);
    expect(find.text('Shared · 2'), findsOneWidget);
    expect(find.text('(Untitled)'), findsOneWidget);
    expect(find.text('Shared with you'), findsOneWidget);
  });

  testWidgets('board filters by chip and search, and opens notes', (t) async {
    t.view.physicalSize = const Size(1280, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    NoteSummary? opened;
    await t.pumpWidget(_app(NotesBoard(
        notes: sampleNotes, now: now, onOpen: (n) => opened = n, onCreate: () {})));
    expect(find.byType(NoteCard), findsNWidgets(5));
    await t.tap(find.text('Shared with me'));
    await t.pumpAndSettle();
    expect(find.byType(NoteCard), findsOneWidget);
    await t.tap(find.text('All'));
    await t.enterText(find.byType(TextField), 'zzz');
    await t.pumpAndSettle();
    expect(find.text('No notes match'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'groc');
    await t.pumpAndSettle();
    await t.tap(find.text('Groceries'));
    expect(opened?.id, 'n2');
  });

  testWidgets('shared filter hidden when nothing is shared with you',
      (t) async {
    await t.pumpWidget(_app(NotesBoard(
        notes: [sampleNotes[0]], onOpen: (_) {}, onCreate: () {})));
    expect(find.text('Shared with me'), findsNothing);
  });

  testWidgets('empty state creates a note', (t) async {
    var created = false;
    await t.pumpWidget(_app(NotesEmpty(onCreate: () => created = true)));
    await t.tap(find.text('New note'));
    expect(created, isTrue);
  });

  testWidgets('save status labels', (t) async {
    for (final (state, label) in [
      (NoteSaveState.saved, 'Saved'),
      (NoteSaveState.unsaved, 'Unsaved changes'),
      (NoteSaveState.saving, 'Saving…'),
      (NoteSaveState.isNew, 'Not saved yet'),
    ]) {
      await t.pumpWidget(_app(NoteSaveStatus(state: state)));
      await t.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('delete sits in the overflow menu, red and last', (t) async {
    var deleted = false;
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: NoteEditorPage(
        isNew: false,
        saving: false,
        dirty: true,
        onSave: () {},
        onDelete: () => deleted = true,
        body: const SizedBox(),
      ),
    ));
    expect(find.text('Delete note'), findsNothing);
    await t.tap(find.byType(BjOverflowMenu));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete note'));
    await t.pumpAndSettle();
    expect(deleted, isTrue);
  });

  testWidgets('new notes have no delete action', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: NoteEditorPage(
        isNew: true,
        saving: false,
        dirty: false,
        onSave: () {},
        body: const SizedBox(),
      ),
    ));
    expect(find.text('New Note'), findsOneWidget);
    expect(find.byType(BjOverflowMenu), findsNothing);
  });

  testWidgets('unsaved dialog returns the chosen action', (t) async {
    NoteExitAction? result;
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showNoteUnsavedDialog(context),
          child: const Text('go'),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save and exit'));
    await t.pumpAndSettle();
    expect(result, NoteExitAction.saveAndExit);
  });

  testWidgets('shared-with line', (t) async {
    await t.pumpWidget(_app(const NoteSharedWith(emails: [])));
    expect(find.text('Only you'), findsOneWidget);
    await t.pumpWidget(_app(const NoteSharedWith(
        emails: ['a@x.com', 'b@x.com', 'c@x.com'])));
    expect(find.text('Shared with a, b +1'), findsOneWidget);
  });

  testWidgets('shared-with line uses display names', (t) async {
    ActiveGroupService.instance.activeGroupId = 'g';
    addTearDown(() => ActiveGroupService.instance.activeGroupId = null);
    final dir = GroupMemberDirectory()
      ..primeCache('g', const [
        GroupMember(
            groupId: 'g', uid: 'p', email: 'priya@x.com', displayName: 'Priya Nair'),
      ]);
    await t.pumpWidget(_app(NoteSharedWith(
        uids: const ['p', 'gone'],
        emails: const ['priya@x.com', 'sam@x.com'],
        directory: dir)));
    await t.pump();
    expect(find.text('Shared with Priya Nair and sam'), findsOneWidget);
  });
}
