import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {BjAccent? accent}) => MaterialApp(
      theme: BluejayTheme.build(accent: accent),
      home: Scaffold(body: child),
    );

void main() {
  test('theme carries the BjTheme extension and the exact accent', () {
    final accent = BjAccent(primary: BjSwatches.rose.color);
    final theme = BluejayTheme.build(accent: accent);
    expect(theme.extension<BjTheme>()!.accent, accent.primary);
    expect(theme.colorScheme.primary, accent.primary);
    expect(theme.colorScheme.secondary, accent.secondary);
  });

  testWidgets('BjSnapshotView shows loading, error and empty states', (t) async {
    await t.pumpWidget(_app(BjSnapshotView<List<int>>(
      snapshot: const AsyncSnapshot.waiting(),
      builder: (d) => Text('${d.length} items'),
    )));
    expect(find.byType(BjSkeletonList), findsOneWidget);

    var retried = false;
    await t.pumpWidget(_app(BjSnapshotView<List<int>>(
      snapshot: AsyncSnapshot.withError(ConnectionState.active, 'boom'),
      onRetry: () => retried = true,
      builder: (d) => Text('${d.length} items'),
    )));
    await t.pumpAndSettle();
    expect(find.text('Something went wrong'), findsOneWidget);
    await t.tap(find.text('Try again'));
    expect(retried, isTrue);

    await t.pumpWidget(_app(BjSnapshotView<List<int>>(
      snapshot: const AsyncSnapshot.withData(ConnectionState.active, []),
      isEmpty: (d) => d.isEmpty,
      empty: const BjStateView.empty(icon: Icons.inbox, title: 'Nothing yet'),
      builder: (d) => Text('${d.length} items'),
    )));
    await t.pumpAndSettle();
    expect(find.text('Nothing yet'), findsOneWidget);
  });

  testWidgets('showBjConfirm lists consequences and returns the choice', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(_app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    final result = showBjConfirm(ctx,
        title: 'Delete list?',
        consequences: ['All 12 items are deleted'],
        confirmLabel: 'Delete',
        destructive: true);
    await t.pumpAndSettle();
    expect(find.text('All 12 items are deleted'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('BjListRow puts destructive actions last in its menu', (t) async {
    await t.pumpWidget(_app(BjListRow(
      title: 'Groceries',
      actions: [
        BjMenuAction(label: 'Delete', icon: Icons.delete, destructive: true, onSelected: () {}),
        BjMenuAction(label: 'Rename', icon: Icons.edit, onSelected: () {}),
      ],
    )));
    await t.tap(find.byIcon(Icons.more_horiz_rounded));
    await t.pumpAndSettle();
    final rename = t.getTopLeft(find.text('Rename')).dy;
    final delete = t.getTopLeft(find.text('Delete')).dy;
    expect(rename, lessThan(delete));
  });

  testWidgets('accent picker only reports accessible colors', (t) async {
    final reported = <Color>[];
    await t.pumpWidget(_app(SingleChildScrollView(
      child: BjAccentPicker(onChanged: (p, s) => reported.add(p)),
    )));
    await t.tap(find.bySemanticsLabel('Teal color').first);
    await t.pumpAndSettle();
    expect(reported.last, BjSwatches.teal.color);

    await t.tap(find.bySemanticsLabel('Custom color').first);
    await t.pumpAndSettle();
    final count = reported.length;
    await t.enterText(find.widgetWithText(TextField, 'Hex').first, '#FDE047');
    await t.pumpAndSettle();
    expect(reported.length, count, reason: 'light yellow must not be reported');
    expect(find.textContaining('Too light'), findsOneWidget);

    await t.tap(find.text('Use nearest readable shade'));
    await t.pumpAndSettle();
    expect(reported.length, count + 1);
    expect(isAccessibleAccent(reported.last), isTrue);
  });

  testWidgets('BjContent and BjScrollBody line up at every width', (t) async {
    for (final w in [390.0, 800.0, 1280.0, 1800.0]) {
      t.view.physicalSize = Size(w, 900);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(_app(Column(children: [
        const BjContent(child: SizedBox(key: Key('a'), height: 10, width: double.infinity)),
        Expanded(child: BjScrollBody(children: const [
          SizedBox(key: Key('b'), height: 10, width: double.infinity),
        ])),
      ])));
      expect(t.getTopLeft(find.byKey(const Key('a'))).dx,
          t.getTopLeft(find.byKey(const Key('b'))).dx, reason: 'width $w');
      expect(t.getSize(find.byKey(const Key('a'))).width,
          t.getSize(find.byKey(const Key('b'))).width, reason: 'width $w');
    }
    t.view.reset();
  });

  testWidgets('BjContent in a bottom bar keeps its height and leaves the body room', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: const BjPage(
        title: 'New invoice',
        body: SizedBox.expand(key: Key('body')),
        bottomBar: BjContent(child: Row(children: [Expanded(child: Text('Total')), SizedBox(height: 48)])),
      ),
    ));
    expect(t.getSize(find.byType(BjContent)).height, 48);
    expect(t.getSize(find.byKey(const Key('body'))).height, greaterThan(700));
    expect(t.getTopLeft(find.text('Total')).dy, greaterThan(800));
    t.view.reset();
  });

  testWidgets('BjSheetActions: Cancel pops, primary shows busy', (t) async {
    var saved = 0;
    Widget sheet({bool busy = false}) => _app(Builder(
          builder: (c) => TextButton(
            onPressed: () => showBjSheet<void>(c,
                title: 'New list',
                builder: (_) => BjSheetActions(
                    primaryLabel: 'Create',
                    busy: busy,
                    onPrimary: () => saved++)),
            child: const Text('open'),
          ),
        ));
    await t.pumpWidget(sheet());
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('Create'));
    expect(saved, 1);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Create'), findsNothing);

    await t.pumpWidget(sheet(busy: true));
    await t.tap(find.text('open'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.tap(find.text('Create'));
    expect(saved, 1, reason: 'busy ignores taps');
  });

  testWidgets('BjSheetActions share the width on phones, sit right on desktop',
      (t) async {
    for (final (w, shared) in [(390.0, true), (1280.0, false)]) {
      t.view.physicalSize = Size(w, 800);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(_app(BjSheetActions(
          primaryLabel: 'Save', onPrimary: () {}, onCancel: () {})));
      final cancel = t.getSize(find.widgetWithText(OutlinedButton, 'Cancel'));
      final save = t.getSize(find.widgetWithText(FilledButton, 'Save'));
      expect((cancel.width - save.width).abs() < 1, shared, reason: 'width $w');
      expect(t.getTopRight(find.widgetWithText(FilledButton, 'Save')).dx, w);
    }
    t.view.reset();
  });

  testWidgets('BjProgressFab shows progress and ignores taps meanwhile',
      (t) async {
    var taps = 0;
    await t.pumpWidget(_app(BjProgressFab(
      icon: Icons.upload_rounded,
      label: 'Upload',
      busy: true,
      progress: 0.42,
      busyLabel: (p) => 'Uploading $p%',
      onPressed: () => taps++,
    )));
    expect(find.text('Uploading 42%'), findsOneWidget);
    await t.tap(find.text('Uploading 42%'));
    expect(taps, 0);
    final ring = t.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator));
    expect(ring.value, 0.42);
  });

  testWidgets('BjResponsiveGrid fits columns by tile width, equal heights',
      (t) async {
    expect(BjResponsiveGrid.columnsFor(300), 1);
    expect(BjResponsiveGrid.columnsFor(700), 2);
    expect(BjResponsiveGrid.columnsFor(1100), 3);
    expect(BjResponsiveGrid.columnsFor(1100, maxColumns: 2), 2);
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(_app(SingleChildScrollView(
      child: BjResponsiveGrid(children: [
        const SizedBox(key: Key('a'), height: 40),
        const SizedBox(key: Key('b'), height: 90),
        const SizedBox(key: Key('c'), height: 10),
        Column(key: const Key('d'), children: const [Text('x'), Spacer()]),
      ]),
    )));
    expect(t.getTopLeft(find.byKey(const Key('a'))).dy,
        t.getTopLeft(find.byKey(const Key('c'))).dy);
    expect(t.getSize(find.byKey(const Key('a'))).height, 90);
    expect(t.getTopLeft(find.byKey(const Key('d'))).dy,
        greaterThan(t.getTopLeft(find.byKey(const Key('a'))).dy));
    t.view.reset();
  });

  testWidgets('BjResponsiveGrid.rows matches the page content column',
      (t) async {
    t.view.physicalSize = const Size(900, 900);
    t.view.devicePixelRatio = 1;
    late List<Widget> rows;
    await t.pumpWidget(_app(Builder(builder: (c) {
      rows = BjResponsiveGrid.rows(
          c, List.generate(5, (i) => Text('$i')),
          minTileWidth: 420, maxColumns: 2);
      return const SizedBox();
    })));
    expect(rows, hasLength(3), reason: '2 columns at 900 wide');
    t.view.physicalSize = const Size(899, 900);
    await t.pumpWidget(_app(Builder(builder: (c) {
      rows = BjResponsiveGrid.rows(
          c, List.generate(5, (i) => Text('$i')),
          minTileWidth: 420, maxColumns: 2);
      return const SizedBox();
    })));
    expect(rows, hasLength(5));
    t.view.reset();
  });

  testWidgets('BjOptionCards picks one and starts unchosen', (t) async {
    String? value;
    await t.pumpWidget(_app(StatefulBuilder(
      builder: (c, set) => BjOptionCards<String>(
        value: value,
        onChanged: (v) => set(() => value = v),
        options: const [
          BjOption(value: 'pub', title: 'Public', icon: Icons.public),
          BjOption(value: 'priv', title: 'Private', description: 'Just you'),
        ],
      ),
    )));
    expect(t.widgetList<BjOptionCard>(find.byType(BjOptionCard))
        .where((c) => c.selected), isEmpty);
    await t.tap(find.text('Private'));
    await t.pump();
    expect(value, 'priv');
    expect(t.widget<BjOptionCard>(find.byType(BjOptionCard).last).selected,
        isTrue);
  });

  testWidgets('BjOptionCards works inside an AlertDialog', (t) async {
    await t.pumpWidget(_app(AlertDialog(
      content: BjOptionCards<int>(
        value: 1,
        onChanged: (_) {},
        options: const [
          BjOption(value: 1, title: 'One'),
          BjOption(value: 2, title: 'Two'),
        ],
      ),
      actions: [
        BjSheetActions(primaryLabel: 'OK', onPrimary: () {}, onCancel: () {}),
      ],
    )));
    expect(t.takeException(), isNull);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('BjDetailTable lines values up in one column', (t) async {
    await t.pumpWidget(_app(const BjDetailTable(rows: [
      BjKeyValue(label: 'Type', value: 'PDF'),
      BjKeyValue(label: 'Uploaded by', child: Text('jay')),
    ])));
    expect(t.getTopLeft(find.text('PDF')).dx, t.getTopLeft(find.text('jay')).dx);
  });

  testWidgets('BjDuePill turns red only once overdue and not done', (t) async {
    final now = DateTime(2026, 11, 10);
    final danger = BjTheme.fromAccent(BjAccent.standard).tone(BjTone.danger);
    Future<BjStatusPill> pill(DateTime? due, {bool done = false}) async {
      await t.pumpWidget(_app(BjDuePill(due: due, done: done, now: now)));
      return t.widget<BjStatusPill>(find.byType(BjStatusPill));
    }

    expect((await pill(null)).label, 'No due date');
    expect((await pill(DateTime(2026, 11, 10))).label, 'Due 2026-11-10');
    final late = await pill(DateTime(2026, 11, 9));
    expect(late.label, 'Overdue 2026-11-09');
    expect(late.tone, BjTone.danger);
    expect(danger.foreground, isNotNull);
    expect((await pill(DateTime(2026, 11, 9), done: true)).tone,
        BjTone.neutral);
  });

  testWidgets('BjTagChip tints and checks when selected', (t) async {
    var taps = 0;
    const color = Color(0xFF9CCC65);
    await t.pumpWidget(_app(BjTagChip(
        label: 'Produce', color: color, selected: true, onTap: () => taps++)));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final label = t.widget<Text>(find.text('Produce'));
    expect(contrastRatio(label.style!.color!, bjTint(color)),
        greaterThanOrEqualTo(4.5));
    await t.tap(find.text('Produce'));
    expect(taps, 1);
  });

  testWidgets('disabled BjMenuAction is shown but not selectable', (t) async {
    var picked = 0;
    await t.pumpWidget(_app(BjOverflowMenu(actions: [
      BjMenuAction(
          label: 'Create change request',
          icon: Icons.rate_review_outlined,
          enabled: false,
          onSelected: () => picked++),
    ])));
    await t.tap(find.byIcon(Icons.more_horiz_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Create change request'));
    await t.pumpAndSettle();
    expect(picked, 0);
  });

  testWidgets('BjFilterBar groups: label beside chips wide, above narrow',
      (t) async {
    Widget bar() => _app(BjFilterBar(groups: [
          BjFilterGroup(label: 'Status', filters: [
            FilterChip(label: const Text('Active'), onSelected: (_) {}),
          ]),
          const BjFilterGroup(
              label: 'Tags', filters: [], placeholder: BjInlineNote('No tags')),
        ]));
    for (final (w, beside) in [(1000.0, true), (390.0, false)]) {
      t.view.physicalSize = Size(w, 800);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(bar());
      final label = t.getTopLeft(find.text('Status'));
      final chip = t.getTopLeft(find.text('Active'));
      expect(chip.dx > label.dx + 40, beside, reason: 'width $w');
      expect(find.text('No tags'), findsOneWidget);
    }
    t.view.reset();
  });

  testWidgets('BjHeroCard compact uses a smaller title', (t) async {
    await t.pumpWidget(_app(const Column(children: [
      BjHeroCard(key: Key('full'), title: 'Full'),
      BjHeroCard(key: Key('compact'), title: 'Small', compact: true),
    ])));
    final full = t.widget<Text>(find.text('Full')).style!.fontSize!;
    final small = t.widget<Text>(find.text('Small')).style!.fontSize!;
    expect(small, lessThan(full));
  });

  testWidgets('BjPinnedTabs line up with the content column', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(_app(DefaultTabController(
      length: 2,
      child: NestedScrollView(
        headerSliverBuilder: (_, __) => const [
          BjPinnedTabs(tabs: [BjTab('One', icon: Icons.public), BjTab('Two')]),
        ],
        body: BjScrollBody(children: const [
          SizedBox(key: Key('row'), height: 10, width: double.infinity),
        ]),
      ),
    )));
    final tabs = t.getTopLeft(find.byType(BjSegmentedTabs).first);
    final content = t.getTopLeft(find.byKey(const Key('row')));
    expect(find.byType(BjSegmentedTabs), findsOneWidget);
    // The control's own left edge.
    final control = t.getTopLeft(find.descendant(
        of: find.byType(BjSegmentedTabs), matching: find.byType(Container)).first);
    expect(control.dx, content.dx);
    expect(tabs.dx, lessThanOrEqualTo(content.dx));
    t.view.reset();
  });

  testWidgets('BjSnack works without BluejayTheme', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    BjSnack.success(ctx, 'Saved');
    await t.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(t.takeException(), isNull);
    t.view.reset();
  });

  testWidgets('BjStatusPill ellipsizes in a narrow row', (t) async {
    await t.pumpWidget(_app(const SizedBox(
      width: 80,
      child: Row(children: [
        Flexible(child: BjStatusPill(label: 'A very long status label', icon: Icons.info)),
      ]),
    )));
    expect(t.takeException(), isNull);
  });
}
