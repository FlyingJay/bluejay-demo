import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page that scrolls down, holding a row of 30 chips that scrolls across.
Widget _page({
  required ScrollController row,
  required ScrollController page,
  ValueChanged<int>? onTap,
}) =>
    MaterialApp(
      scrollBehavior: const BjScrollBehavior(),
      home: Scaffold(
        body: ListView(
          controller: page,
          children: [
            SizedBox(
              height: 60,
              child: ListView.builder(
                key: const Key('row'),
                controller: row,
                scrollDirection: Axis.horizontal,
                itemCount: 30,
                itemBuilder: (context, i) => SizedBox(
                  width: 100,
                  child: TextButton(onPressed: () => onTap?.call(i), child: Text('chip $i')),
                ),
              ),
            ),
            for (var i = 0; i < 40; i++) SizedBox(height: 50, child: Text('line $i')),
          ],
        ),
      ),
    );

Future<void> _wheel(WidgetTester t, Offset at, double dy) async {
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  await t.sendEventToBinding(mouse.hover(at));
  await t.sendEventToBinding(mouse.scroll(Offset(0, dy)));
  await t.pump();
}

void main() {
  testWidgets('the mouse wheel scrolls a horizontal list sideways', (t) async {
    final row = ScrollController();
    final page = ScrollController();
    await t.pumpWidget(_page(row: row, page: page));
    await _wheel(t, t.getCenter(find.byKey(const Key('row'))), 120);
    expect(row.offset, 120);
    expect(page.offset, 0, reason: 'the page stays put while the row can move');
  });

  testWidgets('at the end of the row the wheel scrolls the page again', (t) async {
    final row = ScrollController();
    final page = ScrollController();
    await t.pumpWidget(_page(row: row, page: page));
    row.jumpTo(row.position.maxScrollExtent);
    await t.pump();
    await _wheel(t, t.getCenter(find.byKey(const Key('row'))), 120);
    expect(page.offset, greaterThan(0));
  });

  testWidgets('dragging with the mouse scrolls a horizontal list', (t) async {
    final row = ScrollController();
    final page = ScrollController();
    await t.pumpWidget(_page(row: row, page: page));
    final start = t.getCenter(find.byKey(const Key('row')));
    final gesture = await t.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.up();
    await t.pumpAndSettle();
    expect(row.offset, greaterThanOrEqualTo(180));
  });

  testWidgets('a mouse click still taps what is in the list', (t) async {
    final row = ScrollController();
    final page = ScrollController();
    int? tapped;
    await t.pumpWidget(_page(row: row, page: page, onTap: (i) => tapped = i));
    await t.tap(find.text('chip 1'), kind: PointerDeviceKind.mouse);
    await t.pump();
    expect(tapped, 1);
    expect(row.offset, 0);
  });

  testWidgets('a vertical list keeps mouse drags for text selection', (t) async {
    final row = ScrollController();
    final page = ScrollController();
    await t.pumpWidget(_page(row: row, page: page));
    final gesture = await t.startGesture(t.getCenter(find.text('line 10')), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, -200));
    await gesture.up();
    await t.pumpAndSettle();
    expect(page.offset, 0);
  });

  testWidgets('on desktop, with scrollbars, a list is wrapped once', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final row = ScrollController();
    final page = ScrollController();
    await t.pumpWidget(_page(row: row, page: page));
    final wrappers = find.descendant(
      of: find.byKey(const Key('row')),
      matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_MouseHorizontalScroll'),
    );
    expect(wrappers, findsOneWidget);
    await _wheel(t, t.getCenter(find.byKey(const Key('row'))), 120);
    expect(row.offset, 120);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('pagers keep their own wheel handling but drag with the mouse', (t) async {
    final pages = PageController();
    await t.pumpWidget(MaterialApp(
      scrollBehavior: const BjScrollBehavior(),
      home: PageView(
        controller: pages,
        children: [for (var i = 0; i < 3; i++) Center(child: Text('page $i'))],
      ),
    ));
    await _wheel(t, t.getCenter(find.byType(PageView)), 120);
    expect(pages.offset, 0);
    await t.drag(find.byType(PageView), const Offset(-500, 0), kind: PointerDeviceKind.mouse);
    await t.pumpAndSettle();
    expect(pages.page, 1);
  });
}
