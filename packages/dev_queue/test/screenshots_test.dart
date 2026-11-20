// Renders the queue screens as PNGs with the real bundled fonts, for
// design review. Off by default (pixels depend on the host's font
// rendering). Run with:
//
//   BJ_DESIGN_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
//
// Output: test/screenshots/out/*.png (git-ignored).

import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:bluejay_design/testing.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
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

/// Runs [open] over a blank queue page once it is on screen, so a sheet or
/// dialog renders the way users see it.
class _OverlayHost extends StatefulWidget {
  final void Function(BuildContext context) open;

  const _OverlayHost({required this.open});

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.open(context));
  }

  @override
  Widget build(BuildContext context) => const BjPage(title: 'Your queue', body: SizedBox.shrink());
}

/// The chip in each look, the status pills and the size chips.
class _StatusGallery extends StatelessWidget {
  const _StatusGallery();

  @override
  Widget build(BuildContext context) {
    return BjPage(
      title: 'Queue status',
      body: BjScrollBody(
        children: [
          const BjSectionHeader(title: 'Queue chip'),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [for (final copy in sampleChipCopies) DevQueueChipView(copy: copy, onTap: () {})],
          ),
          const BjSectionHeader(title: 'Status on a ticket'),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [for (final status in sampleStatuses()) DevStatusPill(status)],
          ),
          const BjSectionHeader(title: 'Dense rows'),
          Wrap(
            spacing: BjSpace.sm,
            runSpacing: BjSpace.sm,
            children: [
              for (final status in sampleStatuses().take(4)) DevStatusPill(status, showDetail: false),
              const DevQueueTextChip('Small'),
              const DevQueueTextChip('Fix', emphasis: true),
            ],
          ),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {'phone': const Size(390, 2000), 'desktop': const Size(1280, 1400)};
  final screens = <String, Future<Widget> Function()>{
    'queue': () async => DevQueueScreen(currentUser: FakeUser(), service: (await seededQueue()).service, now: fixtureNow),
    'queue_empty': () async => DevQueueScreen(currentUser: FakeUser(), service: emptyQueue().service, now: fixtureNow),
    'queue_loading': () async =>
        DevQueueScreen(currentUser: FakeUser(), service: PendingQueueService(FakeQueue()), now: fixtureNow),
    'queue_error': () async =>
        DevQueueScreen(currentUser: FakeUser(), service: FailingQueueService(FakeQueue()), now: fixtureNow),
    'statuses': () async => const _StatusGallery(),
    'sheet_regression': () async {
      final q = FakeQueue();
      return _OverlayHost(open: (context) => showDevQueueRegressionSheet(context, liveItem(), q.service));
    },
    'sheet_edit': () async {
      final q = await seededQueue();
      await q.firestore
          .collection('feature_requests')
          .doc('q2')
          .set({'title': 'Weekly digest of new tasks', 'description': 'Every Monday, email me the tasks added last week.'});
      final item = DevQueueItem.fromMap('feature__q2', {
        ...itemFields(state: 'queued', code: 'up_next', label: 'Up next', title: 'Weekly digest of new tasks'),
        'itemType': 'feature',
        'itemId': 'q2',
      });
      return _OverlayHost(open: (context) => showDevQueueEditSheet(context, item, q.service));
    },
    'confirm_withdraw': () async =>
        _OverlayHost(open: (context) => confirmDevQueueWithdraw(context, started: true)),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} ${size.key}', (t) async {
        t.view.physicalSize = size.value * 2;
        t.view.devicePixelRatio = 2;
        FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
        final home = await t.runAsync(screen.value);
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BluejayTheme.build(),
          home: home,
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
