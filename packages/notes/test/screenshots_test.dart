// Renders the Notes screens as PNGs with the real bundled fonts, for
// design review. Off by default (pixels depend on the host's font
// rendering). Run with:
//
//   BJ_DESIGN_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
//
// Output: test/screenshots/out/*.png (git-ignored).

import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:bluejay_design/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/notes_widgets.dart';

import 'support/fixtures.dart';

final _enabled = Platform.environment['BJ_DESIGN_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  const fonts = '../../assets/fonts';
  await loadBjFonts(fonts);
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await (FontLoader('MaterialIcons')
        ..addFont(file('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')))
      .load();
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  Widget list(Widget body) => BjPage(
        title: 'My Notes',
        body: body,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {},
          icon: const Icon(Icons.add_rounded),
          label: const Text('New note'),
        ),
      );

  final sizes = {'phone': const Size(390, 844), 'desktop': const Size(1280, 860)};
  final screens = <String, Widget Function()>{
    'notes': () => list(NotesBoard(
        notes: sampleNotes, now: now, onOpen: (_) {}, onCreate: () {})),
    'notes_empty': () => list(NotesEmpty(onCreate: () {})),
    'notes_loading': () => list(const NotesSkeleton()),
    'notes_error': () => list(BjStateView.error(
        title: 'Couldn\'t load your notes',
        error: 'permission-denied',
        onRetry: () {})),
    'editor': () => const EditorHarness(),
    'editor_unsaved': () => const EditorHarness(dirty: true),
    'editor_new': () => const EditorHarness(isNew: true),
    'editor_loading': () => const EditorHarness(loading: true),
    'delete_confirm': () => _ConfirmHost(
          consequences:
              noteDeleteConsequences(sharedCount: 2, createdByMe: true),
        ),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} ${size.key}', (t) async {
        t.view.physicalSize = size.value * 2;
        t.view.devicePixelRatio = 2;
        FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BluejayTheme.build(),
          home: screen.value(),
        ));
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('screenshots/out/${screen.key}_${size.key}.png'),
        );
        t.view.reset();
      }, skip: !_enabled);
    }
  }
}

class _ConfirmHost extends StatefulWidget {
  const _ConfirmHost({required this.consequences});
  final List<String> consequences;

  @override
  State<_ConfirmHost> createState() => _ConfirmHostState();
}

class _ConfirmHostState extends State<_ConfirmHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => showBjConfirm(
          context,
          title: 'Delete this note?',
          message: '"Q4 planning" will be deleted.',
          consequences: widget.consequences,
          confirmLabel: 'Delete note',
          destructive: true,
        ));
  }

  @override
  Widget build(BuildContext context) => const EditorHarness();
}
