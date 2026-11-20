import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/live_window.dart';
import 'package:shared_ui/load_more.dart';

Widget _host(Widget child) => MaterialApp(
      theme: BluejayTheme.build(),
      home: Scaffold(body: child),
    );

void main() {
  group('LoadMoreButton', () {
    testWidgets('a button while more remain, a spinner while loading',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(LoadMoreButton(
        hasMore: true,
        onLoadMore: () => taps++,
        label: 'Load earlier messages',
      )));
      await tester.tap(find.text('Load earlier messages'));
      expect(taps, 1);

      await tester.pumpWidget(_host(LoadMoreButton(
          hasMore: true, loading: true, onLoadMore: () => taps++)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Load more'), findsNothing);

      await tester.pumpWidget(
          _host(LoadMoreButton(hasMore: false, onLoadMore: () => taps++)));
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('PagedListView', () {
    testWidgets('scrolling near the end asks for the next page',
        (tester) async {
      var loads = 0;
      await tester.pumpWidget(_host(PagedListView(
        itemCount: 60,
        hasMore: true,
        onLoadMore: () => loads++,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('item $i')),
      )));
      expect(loads, 0);
      await tester.drag(find.byType(ListView), const Offset(0, -2600));
      await tester.pumpAndSettle();
      expect(loads, greaterThan(0));
      expect(find.text('Load more'), findsOneWidget);
    });

    testWidgets('no loader and no loads once everything is shown',
        (tester) async {
      var loads = 0;
      await tester.pumpWidget(_host(PagedListView(
        itemCount: 60,
        hasMore: false,
        onLoadMore: () => loads++,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('item $i')),
      )));
      await tester.drag(find.byType(ListView), const Offset(0, -2600));
      await tester.pumpAndSettle();
      expect(loads, 0);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('reversed (a chat): the loader sits past the oldest item',
        (tester) async {
      await tester.pumpWidget(_host(PagedListView(
        reverse: true,
        itemCount: 3,
        hasMore: true,
        onLoadMore: () {},
        loadMoreLabel: 'Load earlier messages',
        itemBuilder: (_, i) => Text('message $i'),
      )));
      final loader = tester.getTopLeft(find.text('Load earlier messages'));
      final oldest = tester.getTopLeft(find.text('message 2'));
      final newest = tester.getTopLeft(find.text('message 0'));
      expect(loader.dy, lessThan(oldest.dy));
      expect(oldest.dy, lessThan(newest.dy));
    });
  });

  testWidgets('LoadMoreButton.forWindow follows the window', (tester) async {
    final sources = <StreamController<List<int>>>[];
    final window = LiveWindow<int>((limit) {
      final c = StreamController<List<int>>();
      sources.add(c);
      return c.stream;
    }, pageSize: 2);
    window.start();
    await tester.pumpWidget(_host(LoadMoreButton.forWindow(window)));
    expect(find.text('Load more'), findsNothing);

    sources.last.add([1, 2]);
    await tester.pump();
    expect(find.text('Load more'), findsOneWidget);

    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(window.limit, 4);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    sources.last.add([1, 2, 3]);
    await tester.pump();
    expect(find.text('Load more'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    window.dispose();
  });
}
