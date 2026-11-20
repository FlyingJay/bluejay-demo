import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/live_window.dart';

/// LiveWindow: one subscription per page size, a stable replaying stream,
/// hasMore from a full page, and loadMore/retry swapping the subscription.
void main() {
  group('with a stub source', () {
    late List<int> requested;
    late List<StreamController<List<int>>> sources;

    LiveWindow<int> window({int pageSize = 3}) {
      requested = [];
      sources = [];
      return LiveWindow<int>((limit) {
        requested.add(limit);
        final c = StreamController<List<int>>();
        sources.add(c);
        return c.stream;
      }, pageSize: pageSize);
    }

    test('subscribes on first listen, at one page', () async {
      final w = window();
      expect(requested, isEmpty);
      final got = <List<int>>[];
      final sub = w.stream.listen(got.add);
      await pumpEventQueue();
      expect(requested, [3]);
      sources.last.add([1, 2, 3]);
      await pumpEventQueue();
      expect(got, [
        [1, 2, 3]
      ]);
      expect(w.items, [1, 2, 3]);
      expect(w.hasMore, isTrue);
      await sub.cancel();
      w.dispose();
    });

    test('a short page means nothing more to load', () async {
      final w = window();
      final sub = w.stream.listen((_) {});
      await pumpEventQueue();
      sources.last.add([1, 2]);
      await pumpEventQueue();
      expect(w.hasMore, isFalse);
      w.loadMore();
      expect(requested, [3]);
      await sub.cancel();
      w.dispose();
    });

    test('loadMore widens the window by a page and swaps the subscription',
        () async {
      final w = window();
      var notified = 0;
      w.addListener(() => notified++);
      final got = <List<int>>[];
      final sub = w.stream.listen(got.add);
      await pumpEventQueue();
      sources.last.add([1, 2, 3]);
      await pumpEventQueue();

      w.loadMore();
      expect(w.isLoadingMore, isTrue);
      expect(w.limit, 6);
      // A second call while the page loads is ignored.
      w.loadMore();
      expect(requested, [3, 6]);
      expect(sources.first.hasListener, isFalse);

      sources.last.add([1, 2, 3, 4, 5]);
      await pumpEventQueue();
      expect(w.isLoadingMore, isFalse);
      expect(w.hasMore, isFalse);
      expect(got.last, [1, 2, 3, 4, 5]);
      expect(notified, greaterThanOrEqualTo(3));
      await sub.cancel();
      w.dispose();
    });

    test('loadAll doubles the window until a short page arrives', () async {
      final w = window();
      final sub = w.stream.listen((_) {});
      await pumpEventQueue();
      sources.last.add([1, 2, 3]);
      await pumpEventQueue();
      w.loadAll();
      await pumpEventQueue();
      expect(requested, [3, 6]);
      sources.last.add([1, 2, 3, 4, 5, 6]);
      await pumpEventQueue();
      expect(requested, [3, 6, 12]);
      sources.last.add([1, 2, 3, 4, 5, 6, 7]);
      await pumpEventQueue();
      expect(requested, [3, 6, 12]);
      expect(w.items, [1, 2, 3, 4, 5, 6, 7]);
      expect(w.hasMore, isFalse);
      expect(w.isLoadingMore, isFalse);
      await sub.cancel();
      w.dispose();
    });

    test('a new listener gets the latest list straight away', () async {
      final w = window();
      final sub = w.stream.listen((_) {});
      await pumpEventQueue();
      sources.last.add([7]);
      await pumpEventQueue();

      final late = <List<int>>[];
      final sub2 = w.stream.listen(late.add);
      await pumpEventQueue();
      expect(late, [
        [7]
      ]);
      // Still one subscription to the source.
      expect(requested, [3]);
      await sub.cancel();
      await sub2.cancel();
      w.dispose();
    });

    test('stops when the last listener cancels, resumes on the next',
        () async {
      final w = window();
      final sub = w.stream.listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
      expect(sources.last.hasListener, isFalse);
      final sub2 = w.stream.listen((_) {});
      await pumpEventQueue();
      expect(requested, [3, 3]);
      await sub2.cancel();
      w.dispose();
    });

    test('errors reach listeners; retry resubscribes at the same size',
        () async {
      final w = window();
      final errors = <Object>[];
      final sub = w.stream.listen((_) {}, onError: errors.add);
      await pumpEventQueue();
      sources.last.addError(StateError('denied'));
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(w.error, isA<StateError>());

      w.retry();
      expect(w.error, isNull);
      expect(requested, [3, 3]);
      sources.last.add([1]);
      await pumpEventQueue();
      expect(w.items, [1]);
      await sub.cancel();
      w.dispose();
    });

    test('start() runs the source without a stream listener', () async {
      final w = window();
      w.start();
      expect(requested, [3]);
      sources.last.add([1, 2, 3]);
      await pumpEventQueue();
      expect(w.items, [1, 2, 3]);
      w.dispose();
      expect(sources.last.hasListener, isFalse);
    });
  });

  test('pages: hasMore follows what the query read, not what it kept',
      () async {
    final source = StreamController<LiveWindowPage<int>>();
    final w = LiveWindow<int>.pages((_) => source.stream, pageSize: 3);
    w.start();
    // Three read, one dropped (say, soft-deleted): the page was full.
    source.add(const LiveWindowPage([1, 2], fetched: 3));
    await pumpEventQueue();
    expect(w.items, [1, 2]);
    expect(w.hasMore, isTrue);
    w.dispose();
  });

  group('LiveWindow.query', () {
    test('limits the query and pages through it', () async {
      final db = FakeFirebaseFirestore();
      for (var i = 0; i < 5; i++) {
        await db.collection('messages').add({'n': i});
      }
      final w = LiveWindow.query(
        db.collection('messages').orderBy('n', descending: true),
        pageSize: 2,
      );
      final sub = w.stream.listen((_) {});
      await pumpEventQueue();
      expect(w.items!.map((d) => d['n']), [4, 3]);
      expect(w.hasMore, isTrue);

      w.loadMore();
      await pumpEventQueue();
      expect(w.items!.map((d) => d['n']), [4, 3, 2, 1]);

      w.loadMore();
      await pumpEventQueue();
      expect(w.items!.map((d) => d['n']), [4, 3, 2, 1, 0]);
      expect(w.hasMore, isFalse);

      // Live: a new newest message shows up in the window.
      await db.collection('messages').add({'n': 5});
      await pumpEventQueue();
      expect(w.items!.first['n'], 5);
      await sub.cancel();
      w.dispose();
    });
  });

  test('cappedCountLabel', () {
    expect(cappedCountLabel(0), '0');
    expect(cappedCountLabel(99), '99');
    expect(cappedCountLabel(100), '99+');
    expect(cappedCountLabel(250), '99+');
  });
}
