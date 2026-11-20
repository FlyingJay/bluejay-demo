import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/src/file_kind.dart';
import 'package:storage/src/format.dart';
import 'package:storage/src/models.dart';
import 'package:storage/src/widgets/dialogs.dart';
import 'package:storage/src/widgets/file_row.dart';
import 'package:storage/src/widgets/file_tab_body.dart';
import 'package:storage/src/widgets/upload_button.dart';
import 'package:storage/src/widgets/usage_card.dart';

import 'support/fakes.dart';

FileRowActions _actions(List<String> log) => FileRowActions(
      onOpen: () => log.add('open'),
      onDownload: () => log.add('download'),
      onCopyLink: () => log.add('copy'),
      onShare: () => log.add('share'),
      onDelete: () => log.add('delete'),
    );

Widget _row(SharedFile file, {required bool isOwner, List<String>? log}) =>
    themed(Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: FileRow(
          file: file,
          isOwner: isOwner,
          showSharer: false,
          actions: _actions(log ?? []),
        ),
      ),
    ));

void main() {
  group('FileRow', () {
    testWidgets('shows name, uploader, visibility, size, date and shares',
        (t) async {
      await t.pumpWidget(_row(
          fakeFile(isPublic: true, sharedWithIds: ['u2', 'u3']),
          isOwner: true));
      expect(find.text('Quarterly report'), findsOneWidget);
      expect(find.textContaining('Uploaded by jay · Nov 3'), findsOneWidget);
      expect(find.text('Public'), findsOneWidget);
      expect(find.text('2.00 MB'), findsOneWidget);
      expect(find.text('Shared with 2'), findsOneWidget);
      expect(find.byIcon(Icons.picture_as_pdf_rounded), findsOneWidget);
    });

    testWidgets('private files show a Private pill', (t) async {
      await t.pumpWidget(_row(fakeFile(), isOwner: true));
      expect(find.text('Private'), findsOneWidget);
      expect(find.text('Public'), findsNothing);
    });

    testWidgets(
        'owner menu: details, copy, download, share, then delete in red',
        (t) async {
      final log = <String>[];
      await t
          .pumpWidget(_row(fakeFile(isPublic: true), isOwner: true, log: log));
      await t.tap(find.byIcon(Icons.more_horiz_rounded));
      await t.pumpAndSettle();

      const order = [
        'File details',
        'Copy link',
        'Download',
        'Share',
        'Delete'
      ];
      final ys = [
        for (final label in order)
          t
              .getTopLeft(find.descendant(
                  of: find.byType(PopupMenuItem<BjMenuAction>),
                  matching: find.text(label)))
              .dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: '${order[i]} order');
      }
      expect(find.byType(PopupMenuDivider), findsOneWidget);

      final danger =
          BjTheme.fromAccent(BjAccent.standard).tone(BjTone.danger).foreground;
      final deleteText = t.widget<Text>(find.descendant(
          of: find.byType(PopupMenuItem<BjMenuAction>),
          matching: find.text('Delete')));
      expect(deleteText.style?.color, danger);

      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(log, ['delete']);
    });

    testWidgets('non-owner private file: no copy link, share or delete',
        (t) async {
      await t
          .pumpWidget(_row(fakeFile(userId: 'someone-else'), isOwner: false));
      await t.tap(find.byIcon(Icons.more_horiz_rounded));
      await t.pumpAndSettle();
      final menu = find.byType(PopupMenuItem<BjMenuAction>);
      expect(menu, findsNWidgets(2));
      expect(find.descendant(of: menu, matching: find.text('File details')),
          findsOneWidget);
      expect(find.descendant(of: menu, matching: find.text('Download')),
          findsOneWidget);
      expect(find.text('Copy link'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('tapping the row opens details; the button downloads',
        (t) async {
      final log = <String>[];
      await t.pumpWidget(_row(fakeFile(), isOwner: true, log: log));
      await t.tap(find.text('Quarterly report'));
      await t.tap(find.byTooltip('Download'));
      await t.pumpAndSettle();
      expect(log, ['open', 'download']);
    });

    testWidgets('phones keep Download in the menu only', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_row(fakeFile(), isOwner: true));
      expect(find.byTooltip('Download'), findsNothing);
    });

    testWidgets('published copies have no uploader line', (t) async {
      await t.pumpWidget(
          _row(fakeFile(userEmail: '', userId: ''), isOwner: false));
      expect(find.textContaining('Uploaded by'), findsNothing);
    });
  });

  group('FileTabBody states', () {
    Widget body({List<SharedFile>? files, Object? error, Widget? action}) =>
        themed(Scaffold(
          body: FileTabBody(
            files: files,
            error: error,
            onRefresh: () async {},
            title: 'Your files',
            emptyMessage: 'You have not uploaded any files yet.',
            emptyAction: action,
            rowBuilder: (f) => Text(f.displayName ?? f.fileName),
          ),
        ));

    testWidgets('loading shows skeleton rows', (t) async {
      await t.pumpWidget(body());
      expect(find.byType(BjSkeletonList), findsOneWidget);
    });

    testWidgets('error shows a friendly message and a retry', (t) async {
      await t.pumpWidget(body(error: Exception('boom')));
      await t.pump(const Duration(seconds: 1));
      expect(find.text("Couldn't load files"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('empty shows the message and the first step', (t) async {
      await t.pumpWidget(body(
          files: const [],
          action: FilledButton(
              onPressed: () {}, child: const Text('Upload a file'))));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('You have not uploaded any files yet.'), findsOneWidget);
      expect(find.text('Upload a file'), findsOneWidget);
    });

    testWidgets('files show under a counted section header', (t) async {
      await t.pumpWidget(body(files: sampleFiles.take(3).toList()));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Your files'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Office party photos'), findsOneWidget);
    });
  });

  group('delete confirmation', () {
    test('lists shared recipients and the public link only when they apply',
        () {
      expect(deleteConsequences(fakeFile()), hasLength(1));
      final all = deleteConsequences(
          fakeFile(isPublic: true, sharedWithIds: ['a', 'b', 'c']));
      expect(all, hasLength(3));
      expect(all[1], contains('The 3 people you shared it with lose access'));
      expect(all[2], contains('public link stops working'));
      expect(deleteConsequences(fakeFile(sharedWithIds: ['a']))[1],
          contains('The person you shared it with'));
    });

    testWidgets('dialog shows consequences and resolves true on delete',
        (t) async {
      bool? result;
      await t.pumpWidget(themed(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await confirmDeleteFile(
                context, fakeFile(sharedWithIds: ['u2'])),
            child: const Text('go'),
          ),
        ),
      )));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Delete "Quarterly report"?'), findsOneWidget);
      expect(find.textContaining('loses access right away'), findsOneWidget);
      await t.tap(find.text('Delete file'));
      await t.pumpAndSettle();
      expect(result, isTrue);
    });
  });

  group('upload details dialog', () {
    testWidgets('upload stays disabled until a visibility is picked',
        (t) async {
      UploadDetails? result;
      await t.pumpWidget(themed(Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showUploadDetailsDialog(
                context,
                initialName: 'notes',
                originalFileName: 'notes.txt'),
            child: const Text('go'),
          ),
        ),
      )));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      FilledButton upload() => t.widget<FilledButton>(find.ancestor(
          of: find.text('Upload'),
          matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(upload().onPressed, isNull);
      await t.tap(find.text('Private'));
      await t.pump();
      expect(upload().onPressed, isNotNull);
      await t.tap(find.text('Upload'));
      await t.pumpAndSettle();
      expect(result?.name, 'notes');
      expect(result?.isPublic, isFalse);
    });
  });

  group('misc', () {
    test('file kinds come from the extension', () {
      expect(FileKind.fromName('a.PDF'), FileKind.pdf);
      expect(FileKind.fromName('photo.final.jpeg'), FileKind.image);
      expect(FileKind.fromName('data.xlsx'), FileKind.spreadsheet);
      expect(FileKind.fromName('noext'), FileKind.other);
      expect(FileKind.fromName('weird.'), FileKind.other);
    });

    test('formatting', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1536), '1.50 KB');
      expect(filesLabel(1), '1 file');
      expect(filesLabel(2), '2 files');
      expect(formatDateShort(DateTime(2026, 11, 3), now: DateTime(2026, 12)),
          'Nov 3');
      expect(formatDateShort(DateTime(2025, 11, 3), now: DateTime(2026, 12)),
          'Nov 3, 2025');
      expect(formatDateTime(DateTime(2026, 1, 2, 3, 4)), '2026-01-02 03:04');
    });

    testWidgets('usage card shows the group share for admins', (t) async {
      await t.pumpWidget(themed(const Scaffold(
        body: StorageUsageCard(
          userSummary: StorageUsageSummary(totalBytes: 250, totalFiles: 3),
          groupSummary: StorageUsageSummary(totalBytes: 1000, totalFiles: 9),
        ),
      )));
      await t.pumpAndSettle();
      expect(find.text('250.00 B stored'), findsOneWidget);
      expect(find.text('3 files · Unlimited storage'), findsOneWidget);
      expect(find.textContaining('25%'), findsOneWidget);
      expect(find.byType(BjProgressBar), findsOneWidget);
    });

    testWidgets('upload button shows progress and ignores taps meanwhile',
        (t) async {
      var taps = 0;
      await t.pumpWidget(themed(Scaffold(
        floatingActionButton: UploadButton(
            isUploading: true, progress: 0.42, onPressed: () => taps++),
      )));
      expect(find.text('Uploading 42%'), findsOneWidget);
      await t.tap(find.text('Uploading 42%'));
      expect(taps, 0);
    });
  });
}
