// Renders the Storage screen with fake files as PNGs, using the real
// bundled fonts, for design review. Off by default (pixels depend on the
// host's font rendering). Run with:
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
import 'package:storage/src/models.dart';
import 'package:storage/src/widgets/dialogs.dart';
import 'package:storage/src/widgets/file_row.dart';
import 'package:storage/src/widgets/file_tab_body.dart';
import 'package:storage/src/widgets/storage_layout.dart';
import 'package:storage/src/widgets/upload_button.dart';
import 'package:storage/src/widgets/usage_card.dart';

import 'support/fakes.dart';

final _enabled = Platform.environment['BJ_DESIGN_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const fonts = '../../assets/fonts';
  await loadBjFonts(fonts);
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  await (FontLoader('MaterialIcons')
        ..addFont(file(
            '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')))
      .load();
}

Widget _tab(List<SharedFile>? files,
        {required String title, bool shared = false}) =>
    FileTabBody(
      files: files,
      onRefresh: () async {},
      title: title,
      subtitle: 'Newest first',
      emptyMessage: 'You have not uploaded any files yet.',
      emptyIcon: Icons.cloud_upload_rounded,
      emptyAction: FilledButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.upload_rounded, size: 18),
        label: const Text('Upload a file'),
      ),
      rowBuilder: (f) => FileRow(
        file: f,
        isOwner: !shared && f.userId == me,
        showSharer: shared,
        actions: FileRowActions(
            onOpen: () {},
            onDownload: () {},
            onCopyLink: () {},
            onShare: () {},
            onDelete: () {}),
      ),
    );

Widget _screen({
  int tab = 1,
  List<SharedFile>? files,
  bool admin = true,
  bool uploading = false,
}) =>
    DefaultTabController(
      length: 3,
      initialIndex: tab,
      child: StorageLayout(
        onRefresh: () {},
        usage: StorageUsageCard(
          userSummary:
              const StorageUsageSummary(totalBytes: 366000000, totalFiles: 6),
          groupSummary: admin
              ? const StorageUsageSummary(
                  totalBytes: 1420000000, totalFiles: 41)
              : null,
        ),
        tabs: [
          _tab(sampleFiles.where((f) => f.isPublic).toList(),
              title: 'Public files'),
          _tab(files, title: 'Your files'),
          _tab(files, title: 'Shared with you', shared: true),
        ],
        uploadButton: UploadButton(
            isUploading: uploading, progress: 0.64, onPressed: () {}),
      ),
    );

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {
    'phone': const Size(390, 844),
    'desktop': const Size(1280, 860)
  };

  Future<void> shoot(WidgetTester t, String size, String name, Widget home,
      {Future<void> Function()? after}) async {
    t.view.physicalSize = sizes[size]! * 2;
    t.view.devicePixelRatio = 2;
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: BluejayTheme.build(),
      home: home,
    ));
    await t.pump(const Duration(seconds: 2));
    if (after != null) await after();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('screenshots/out/${name}_$size.png'));
    t.view.reset();
  }

  for (final size in sizes.keys) {
    testWidgets('my files $size', (t) async {
      await shoot(t, size, 'my_files', _screen(files: sampleFiles));
    }, skip: !_enabled);

    testWidgets('shared $size', (t) async {
      await shoot(
          t,
          size,
          'shared',
          _screen(
              tab: 2,
              admin: false,
              uploading: true,
              files: sampleFiles
                  .map((f) => fakeFile(
                      id: f.id,
                      fileName: f.fileName,
                      displayName: f.displayName,
                      size: f.size,
                      isPublic: f.isPublic,
                      userId: 'u9',
                      userEmail: 'sam@sunnyside.ca',
                      createdAt: f.createdAt.toDate()))
                  .toList()));
    }, skip: !_enabled);

    testWidgets('empty $size', (t) async {
      await shoot(t, size, 'empty', _screen(files: const [], admin: false));
    }, skip: !_enabled);

    testWidgets('loading $size', (t) async {
      await shoot(t, size, 'loading', _screen(files: null));
    }, skip: !_enabled);

    testWidgets('delete dialog $size', (t) async {
      await shoot(t, size, 'delete', Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => confirmDeleteFile(
            context, fakeFile(isPublic: true, sharedWithIds: ['u2', 'u3'])));
        return _screen(files: sampleFiles);
      }), after: () => t.pumpAndSettle());
    }, skip: !_enabled);

    testWidgets('upload dialog $size', (t) async {
      await shoot(t, size, 'upload', Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) =>
            showUploadDetailsDialog(context,
                initialName: 'Claims 2026',
                originalFileName: 'Claims 2026.xlsx'));
        return _screen(files: sampleFiles);
      }), after: () => t.pumpAndSettle());
    }, skip: !_enabled);

    testWidgets('details dialog $size', (t) async {
      await shoot(t, size, 'details', Builder(builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) =>
            showFileDetailsDialog(context,
                file: sampleFiles.first, onCopyLink: () {}, onDownload: () {}));
        return _screen(files: sampleFiles);
      }), after: () => t.pumpAndSettle());
    }, skip: !_enabled);
  }
}
