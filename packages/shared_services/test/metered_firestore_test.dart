// Hand-written fakes below implement @sealed cloud_firestore types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/bluejay_firestore.dart';

/// Collects what the decorators record, as `appId|metric → total`.
class _Recorder {
  final Map<String, num> totals = {};

  void call(String appId, String metric, num amount) {
    final key = '$appId|$metric';
    totals[key] = (totals[key] ?? 0) + amount;
  }

  num reads([String app = 'test-app']) => totals['$app|fsReads'] ?? 0;
  num writes([String app = 'test-app']) => totals['$app|fsWrites'] ?? 0;
  num deletes([String app = 'test-app']) => totals['$app|fsDeletes'] ?? 0;
}

void main() {
  late FakeFirebaseFirestore fake;
  late _Recorder rec;
  late FirestoreMeteringContext ctx;
  late MeteredFirestore db;

  setUp(() async {
    fake = FakeFirebaseFirestore();
    rec = _Recorder();
    ctx = FirestoreMeteringContext('test-app', rec.call);
    db = MeteredFirestore(ctx, resolve: () => fake);
    await fake.collection('notes').doc('a').set({'n': 1, 'groupId': 'g'});
    await fake.collection('notes').doc('b').set({'n': 2, 'groupId': 'g'});
    await fake.collection('notes').doc('c').set({'n': 3, 'groupId': 'other'});
  });

  group('one-off reads', () {
    test('query get counts docs returned, minimum one', () async {
      final snap = await db.collection('notes').where('groupId', isEqualTo: 'g').get();
      expect(snap.size, 2);
      expect(rec.reads(), 2);

      await db.collection('notes').where('groupId', isEqualTo: 'none').get();
      expect(rec.reads(), 3);
    });

    test('cache-served gets are free', () async {
      await db.collection('notes').get(const GetOptions(source: Source.cache));
      expect(rec.reads(), 0);
    });

    test('count() is approximated as one read', () async {
      final agg = await db.collection('notes').count().get();
      expect(agg.count, 3);
      expect(rec.reads(), 1);
    });

    test('collectionGroup queries are metered', () async {
      await fake.doc('notes/a/items/x').set({'v': 1});
      await db.collectionGroup('items').get();
      expect(rec.reads(), 1);
    });
  });

  group('listeners', () {
    test('initial result set, then one read per changed doc', () async {
      final sizes = <int>[];
      final sub = db.collection('notes').where('groupId', isEqualTo: 'g').snapshots().listen((s) => sizes.add(s.size));
      await pumpEventQueue();
      expect(rec.reads(), 2);

      await fake.collection('notes').doc('d').set({'n': 4, 'groupId': 'g'});
      await pumpEventQueue();
      expect(sizes.last, 3);
      expect(rec.reads(), 3);
      await sub.cancel();
    });

    QueryListenMeter<Map<String, dynamic>> newMeter({bool metadata = false}) =>
        QueryListenMeter<Map<String, dynamic>>(ctx, includeMetadataChanges: metadata);

    test('a warm-cache first snapshot bills the result set once', () {
      final meter = newMeter();
      meter(_snap(docs: 5, changes: _added(5), fromCache: true)); // initial, from cache
      expect(rec.reads(), 5);
      meter(_snap(docs: 5, changes: const [], fromCache: false)); // server confirms, no change
      expect(rec.reads(), 5);
      meter(_snap(docs: 6, changes: _added(1, from: 5), fromCache: false)); // a real change
      expect(rec.reads(), 6);
    });

    test('cache-then-server: the server snapshot bills only its changes', () {
      final meter = newMeter();
      meter(_snap(docs: 4, changes: _added(4), fromCache: true));
      meter(_snap(docs: 5, changes: _added(1, from: 4), fromCache: false));
      expect(rec.reads(), 4 + 1);
    });

    test('an empty initial result bills one read', () {
      newMeter()(_snap(docs: 0, changes: const [], fromCache: false));
      expect(rec.reads(), 1);
    });

    test('later snapshots served from cache are free', () {
      final meter = newMeter();
      meter(_snap(docs: 2, changes: _added(2), fromCache: false));
      meter(_snap(docs: 3, changes: _added(1, from: 2), fromCache: true));
      expect(rec.reads(), 2);
    });

    test('with includeMetadataChanges, metadata-only changes are free', () {
      final meter = newMeter(metadata: true);
      meter(_snap(docs: 2, changes: _added(2), fromCache: false));
      // Pending-write ack: doc 0 re-delivered as "modified" with the same data.
      meter(_snap(docs: 2, changes: [_change(0, DocumentChangeType.modified)], fromCache: false));
      expect(rec.reads(), 2);
      // A real edit to doc 0.
      meter(_snap(docs: 2, changes: [_change(0, DocumentChangeType.modified, n: 99)], fromCache: false));
      expect(rec.reads(), 3);
    });

    test('a broadcast source is metered once per event, not per listener', () async {
      final source = StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast();
      final query = MeteredQuery(_StreamQuery(source.stream), ctx);
      final stream = query.snapshots();
      final a = <int>[];
      final b = <int>[];
      final subA = stream.listen((s) => a.add(s.size));
      final subB = stream.listen((s) => b.add(s.size));

      source.add(_snap(docs: 3, changes: _added(3), fromCache: false));
      source.add(_snap(docs: 4, changes: _added(1, from: 3), fromCache: false));
      await pumpEventQueue();
      expect(a, [3, 4]);
      expect(b, [3, 4]);
      expect(rec.reads(), 3 + 1);

      // Everyone leaves, then a new listener: a re-attached listener is
      // billed its initial result set again.
      await subA.cancel();
      await subB.cancel();
      final subC = stream.listen((_) {});
      source.add(_snap(docs: 4, changes: const [], fromCache: false));
      await pumpEventQueue();
      expect(rec.reads(), 3 + 1 + 4);
      await subC.cancel();
      await source.close();
    });

    test('a single-subscription source passes through pause, errors and done', () async {
      final source = StreamController<int>();
      var metered = 0;
      final out = <Object>[];
      final done = Completer<void>();
      final sub = meterEachEvent<int>(source.stream, () => (_) => metered++)
          .listen(out.add, onError: out.add, onDone: done.complete);
      source.add(1);
      sub.pause();
      expect(source.isPaused, isTrue);
      sub.resume();
      source.addError('boom');
      source.add(2);
      await source.close();
      await done.future;
      expect(out, [1, 'boom', 2]);
      expect(metered, 2);
    });
  });

  group('DocumentReferences are always the plugin\'s own objects', () {
    // cloud_firestore encodes a DocumentReference value (FieldValue.arrayUnion,
    // Filter, nested data, cursors, converter output) by reading its private
    // `_delegate`; only the plugin's own reference has one. So nothing here
    // may ever hand out a wrapped reference.
    test('from doc(), add(), parent, snapshots, changes and transactions', () async {
      final pluginType = fake.doc('notes/a').runtimeType;
      final notes = db.collection('notes');
      expect(db.doc('notes/a').runtimeType, pluginType);
      expect(notes.doc('a').runtimeType, pluginType);
      expect((await notes.add({'n': 9})).runtimeType, pluginType);
      expect(notes.doc('a').collection('sub').parent.runtimeType, pluginType);
      final snap = await notes.get();
      expect(snap.docs.first.reference.runtimeType, pluginType);
      expect(snap.docChanges.first.doc.reference.runtimeType, pluginType);
      final listened = await notes.snapshots().first;
      expect(listened.docs.first.reference.runtimeType, pluginType);
      await db.runTransaction((tx) async {
        final s = await tx.get(notes.doc('a'));
        expect(s.reference.runtimeType, pluginType);
      });
    });

    test('values pass through filters, cursors and converters unchanged', () async {
      final notes = db.collection('notes');
      final filtered = await notes.where(Filter.or(Filter('n', isEqualTo: 1), Filter('n', isEqualTo: 3))).get();
      expect(filtered.docs.map((d) => d.id).toSet(), {'a', 'c'});

      final first = await notes.orderBy('n').limit(1).get();
      final rest = await notes.orderBy('n').startAfterDocument(first.docs.first).get();
      expect(rest.docs.map((d) => d.id), ['b', 'c']);
      final byValue = await notes.orderBy('n').startAfter([1]).endAt([2]).get();
      expect(byValue.docs.map((d) => d.id), ['b']);

      final linked = notes.withConverter<DocumentReference>(
        fromFirestore: (s, _) => s.data()!['ref'] as DocumentReference,
        toFirestore: (ref, _) => {'ref': ref, 'nested': {'list': [ref]}},
      );
      await linked.doc('link').set(first.docs.first.reference);
      final stored = (await fake.doc('notes/link').get()).data()!;
      expect((stored['ref'] as DocumentReference).path, 'notes/a');
    });
  });

  group('chaining stays metered', () {
    test('every refinement returns a metered query', () {
      final c = db.collection('notes');
      expect(c, isA<MeteredCollectionReference>());
      expect(c.where('n', isGreaterThan: 1), isA<MeteredQuery>());
      expect(c.orderBy('n').limit(1).startAfter([1]).endAt([5]), isA<MeteredQuery>());
      expect(c.limitToLast(2), isA<MeteredQuery>());
      expect(c.firestore, isA<MeteredFirestore>());
      expect(db.batch(), isA<MeteredWriteBatch>());
      expect(c.withConverter<int>(fromFirestore: (s, _) => 0, toFirestore: (v, _) => {}),
          isA<MeteredCollectionReference<int>>());
    });

    test('query equality delegates to the plugin', () {
      final q = db.collection('notes').where('n', isEqualTo: 1) as MeteredQuery;
      expect(q == q.unmetered, isTrue);
      expect(q.hashCode, q.unmetered.hashCode);
      expect(q, equals(MeteredQuery(q.unmetered, const FirestoreMeteringContext('other-app'))));
      expect(db.collection('notes').path, 'notes');
      expect(db.collection('notes').id, 'notes');
    });
  });

  group('writes are recorded only once they succeed', () {
    test('add: counted by the gateway when the platform layer is not active', () async {
      // The fake has no platform layer, so documentWrite's fallback records
      // the write (with metering installed, the platform layer does, once:
      // test/firestore_platform_metering_test.dart).
      final pending = db.collection('notes').add({'n': 5});
      expect(rec.writes(), 0);
      final ref = await pending;
      expect(rec.writes(), 1);
      expect((await fake.doc(ref.path).get()).data(), {'n': 5});
    });

    test('batch counts at successful commit', () async {
      final batch = db.batch();
      batch.set(db.collection('notes').doc('x'), {'n': 1});
      batch.update(db.collection('notes').doc('a'), {'n': 2});
      batch.delete(db.collection('notes').doc('b'));
      final commit = batch.commit();
      expect(rec.writes(), 0);
      await commit;
      expect(rec.writes(), 2);
      expect(rec.deletes(), 1);
      expect((await fake.doc('notes/x').get()).exists, isTrue);
      expect((await fake.doc('notes/b').get()).exists, isFalse);
    });

    test('a failed batch commit records nothing', () async {
      final batch = MeteredWriteBatch(_FailingBatch(), ctx);
      batch.set(fake.doc('notes/x'), {'n': 1});
      batch.delete(fake.doc('notes/a'));
      await expectLater(batch.commit(), throwsStateError);
      expect(rec.writes(), 0);
      expect(rec.deletes(), 0);
    });

    test('a failed add records nothing', () async {
      final notes = MeteredCollectionReference(_FailingCollection(), ctx);
      await expectLater(notes.add({'n': 1}), throwsStateError);
      expect(rec.writes(), 0);
    });

    test('transaction: reads as they happen, writes after commit', () async {
      final result = await db.runTransaction((tx) async {
        final snap = await tx.get(db.doc('notes/a'));
        tx.update(db.doc('notes/a'), {'n': (snap.data()!['n'] as int) + 1});
        tx.set(db.doc('notes/z'), {'n': 0});
        tx.delete(db.doc('notes/b'));
        expect(rec.writes(), 0);
        return 'ok';
      });
      expect(result, 'ok');
      expect(rec.reads(), 1);
      expect(rec.writes(), 2);
      expect(rec.deletes(), 1);
      expect((await fake.doc('notes/a').get()).data()!['n'], 2);
    });

    test('a failed transaction records no writes', () async {
      await expectLater(
        db.runTransaction((tx) async {
          tx.set(db.doc('notes/q'), {'n': 0});
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(rec.writes(), 0);
    });
  });

  group('BluejayFirestore.forApp', () {
    test('wraps an injected instance', () {
      final a = BluejayFirestore.forApp('a', firestore: fake) as MeteredFirestore;
      expect(a.appId, 'a');
      expect(a.unmetered, same(fake));
      expect(BluejayFirestore.forApp('a', firestore: a), same(a));
    });

    test('re-attributing a metered instance keeps its recorder', () async {
      final other = BluejayFirestore.forApp('other-app', firestore: db) as MeteredFirestore;
      expect(other.unmetered, same(fake));
      await other.collection('notes').get();
      expect(rec.reads('other-app'), 3);
      expect(rec.reads(), 0);
    });

    test('is lazy: no Firebase access until used', () {
      expect(() => BluejayFirestore.forApp('lazy-app'), returnsNormally);
    });
  });
}

// -----------------------------------------------------------------------------
// Hand-written fakes (fake_cloud_firestore never reports isFromCache on
// listeners, nor metadata-only changes).
// -----------------------------------------------------------------------------

class _StreamQuery extends Fake implements Query<Map<String, dynamic>> {
  _StreamQuery(this._stream);
  final Stream<QuerySnapshot<Map<String, dynamic>>> _stream;

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      _stream;
}

class _FailingBatch extends Fake implements WriteBatch {
  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {}

  @override
  void delete(DocumentReference document) {}

  @override
  Future<void> commit() => Future.error(StateError('rejected'));
}

class _FailingCollection extends Fake implements CollectionReference<Map<String, dynamic>> {
  @override
  Future<DocumentReference<Map<String, dynamic>>> add(Map<String, dynamic> data) =>
      Future.error(StateError('rejected'));
}

class _FakeMetadata extends Fake implements SnapshotMetadata {
  _FakeMetadata(this.isFromCache);
  @override
  final bool isFromCache;
  @override
  bool get hasPendingWrites => false;
}

class _FakeDoc extends Fake implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, [this.n = 0]);
  @override
  final String id;
  final int n;
  @override
  Map<String, dynamic> data() => {'n': n};
}

class _FakeChange extends Fake implements DocumentChange<Map<String, dynamic>> {
  _FakeChange(this.type, this.doc);
  @override
  final DocumentChangeType type;
  @override
  final DocumentSnapshot<Map<String, dynamic>> doc;
}

DocumentChange<Map<String, dynamic>> _change(int i, DocumentChangeType type, {int n = 0}) =>
    _FakeChange(type, _FakeDoc('d$i', n));

List<DocumentChange<Map<String, dynamic>>> _added(int count, {int from = 0}) =>
    [for (var i = from; i < from + count; i++) _change(i, DocumentChangeType.added)];

class _FakeSnapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _FakeSnapshot(this.docs, this.docChanges, this.metadata);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  @override
  final List<DocumentChange<Map<String, dynamic>>> docChanges;
  @override
  final SnapshotMetadata metadata;
  @override
  int get size => docs.length;
}

QuerySnapshot<Map<String, dynamic>> _snap({
  required int docs,
  required List<DocumentChange<Map<String, dynamic>>> changes,
  required bool fromCache,
}) =>
    _FakeSnapshot([for (var i = 0; i < docs; i++) _FakeDoc('d$i')], changes, _FakeMetadata(fromCache));
