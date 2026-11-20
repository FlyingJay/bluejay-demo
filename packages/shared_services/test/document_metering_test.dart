import 'dart:async';

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/metered_firestore.dart';
import 'package:shared_services/src/document_metering.dart';
import 'package:shared_services/usage_meter.dart';

/// The platform-neutral half of document metering: attribution, the billing
/// approximation, and the mixins both the web and the native classes are
/// built from. The fake platform classes below are composed exactly like
/// the web ones (plugin-shaped base class + the shared mixins + `update` and
/// `snapshots` overrides), so this exercises the web logic without the JS
/// SDK. No platform channel or JS is involved, so it runs on the VM and in
/// the browser:
///   flutter test test/document_metering_test.dart
///   flutter test --platform chrome test/document_metering_test.dart
void main() {
  final recorded = <String>[];
  FirestoreMeteringContext context(String appId) =>
      FirestoreMeteringContext(appId, (app, metric, n) => recorded.add('$app $metric $n'));

  late _Firestore fs;
  late _Backend backend;

  setUp(() {
    recorded.clear();
    FirestoreAttribution.resetForTesting();
    FirestoreAttribution.foregroundAppId = () => null;
    backend = _Backend();
    fs = _Firestore(backend);
  });

  _Snap snap(Map<String, dynamic>? data, {bool fromCache = false}) => _Snap(fs, 'notes/a', data, fromCache);

  group('mixins (the code the web and native classes share)', () {
    test('doc() and collection() capture the gateway context and note the collection', () async {
      final a = FirestoreAttribution.runAs(context('notes'), () => fs.doc('notes/a'));
      await a.get();
      await a.set({'n': 1});
      await (a as _Doc).update({'n': 2});
      await a.delete();
      expect(recorded, ['notes fsReads 1', 'notes fsWrites 1', 'notes fsWrites 1', 'notes fsDeletes 1']);
      expect(FirestoreAttribution.appForDocument('notes/zzz'), 'notes');
    });

    test('collection.doc() builds the path directly, with a 20-character auto id', () {
      final notes = FirestoreAttribution.runAs(context('notes'), () => fs.collection('groups/g/notes'));
      final named = notes.doc('x');
      final auto = notes.doc();
      expect(named.path, 'groups/g/notes/x');
      expect(auto.path, matches(RegExp(r'^groups/g/notes/[A-Za-z0-9]{20}$')));
      expect(notes.parent!.path, 'groups/g');
      expect(fs.collection('top').parent, isNull);
      expect((named as _Doc).metering?.appId, 'notes');
      expect((notes.parent! as _Doc).metering?.appId, 'notes');
    });

    test('subcollections and parents of a metered document keep its context', () async {
      final a = FirestoreAttribution.runAs(context('notes'), () => fs.doc('notes/a'));
      await a.collection('items').doc('x').get();
      await a.parent.doc('b').get();
      expect(recorded, ['notes fsReads 1', 'notes fsReads 1']);
    });

    test('doc() paths count as using the collection, so ambiguity is detected', () async {
      FirestoreAttribution.runAs(context('chat'), () => fs.doc('shared/x'));
      FirestoreAttribution.runAs(context('profile'), () => fs.collection('shared'));
      FirestoreAttribution.foregroundAppId = () => 'wiki';
      expect(FirestoreAttribution.appForDocument('shared/y'), isNull);
      expect(FirestoreAttribution.resolve(null, 'shared/y').appId, 'wiki');
    });

    test('attribution is resolved when the operation is issued, not when it completes', () async {
      UsageMeter.instance
        ..setUser('u1')
        ..setGroup('g1');
      await UsageMeter.instance.flush().catchError((_) {});
      FirestoreAttribution.foregroundAppId = () => 'first';
      final ref = fs.doc('misc/a');
      final pending = Completer<void>();
      backend.writeGate = pending.future;
      final write = ref.set({'n': 1});
      final listen = ref.snapshots(listenSource: ListenSource.defaultSource).listen((_) {});
      FirestoreAttribution.foregroundAppId = () => 'second';
      pending.complete();
      await write;
      backend.events.add(_Snap(fs, 'misc/a', {'n': 1}, false));
      await Future<void>.delayed(Duration.zero);
      final apps = {for (final e in UsageMeter.instance.pendingEntries) ...e.apps.keys};
      expect(apps, {'first'});
      await listen.cancel();
    });

    test('an operation issued under a gateway context is billed to it, whatever the reference', () async {
      final foreign = FirestoreAttribution.runAs(context('chat'), () => fs.doc('chat/a'));
      await FirestoreAttribution.runAs(context('notes'), () => foreign.set({'n': 1}));
      expect(recorded, ['notes fsWrites 1']);
    });

    test('the unmetered context records nothing', () async {
      final ref = fs.doc('usage_daily/x');
      await FirestoreAttribution.runAs(FirestoreMeteringContext.unmetered, () => ref.set({'n': 1}));
      final other = FirestoreAttribution.runAs(context('notes'), () => fs.doc('usage_daily/y'));
      await other.get();
      // Only an explicit unmetered context is exempt, not a path prefix.
      expect(recorded, ['notes fsReads 1']);
    });

    test('documentWrite counts a write once: by the platform layer, or else itself', () async {
      final ctx = context('notes');
      await ctx.documentWrite(() => fs.doc('notes/a').set({'n': 1}), writes: 1);
      expect(recorded, ['notes fsWrites 1']);
      recorded.clear();
      await ctx.documentWrite(() => Future<void>.value(), writes: 1); // unmetered reference
      expect(recorded, ['notes fsWrites 1']);
    });
  });

  group('DocumentOpsMeter', () {
    test('get is free from cache; failed writes record nothing', () async {
      final meter = DocumentOpsMeter('notes/a', context('notes'));
      await meter.get(() => Future.value(snap({'n': 1}, fromCache: true)));
      await expectLater(meter.write(() => Future.error(StateError('denied'))), throwsStateError);
      expect(recorded, isEmpty);
    });

    test('a broadcast listener is billed once per event, not per subscriber', () async {
      final source = StreamController<DocumentSnapshotPlatform>.broadcast(sync: true);
      final stream = DocumentOpsMeter('notes/a', context('notes'))
          .snapshots(() => source.stream, includeMetadataChanges: false);
      final a = stream.listen((_) {});
      final b = stream.listen((_) {});
      source.add(snap({'n': 1}));
      source.add(snap({'n': 2}));
      expect(recorded, ['notes fsReads 1', 'notes fsReads 1']);
      await a.cancel();
      await b.cancel();
    });
  });

  group('DocumentListenMeter', () {
    late List<int> reads;
    DocumentListenMeter meter({bool metadata = false}) =>
        DocumentListenMeter((_, n) => reads.add(n), includeMetadataChanges: metadata);
    setUp(() => reads = []);

    test('cache snapshots are free, the first one too, like get()', () {
      final m = meter();
      m(snap({'n': 1}, fromCache: true));
      m(snap({'n': 2}, fromCache: true));
      expect(reads, isEmpty);
      m(snap({'n': 2}));
      m(snap({'n': 3}));
      expect(reads, [1, 1]);
    });

    test('the first server snapshot is billed even when unchanged; later metadata-only ones are free', () {
      final m = meter(metadata: true);
      m(snap({'n': 1}, fromCache: true));
      m(snap({'n': 1}));
      m(snap({'n': 1}));
      m(snap({'n': 2}));
      expect(reads, [1, 1]);
    });
  });

  group('FirestoreAttribution', () {
    test('runAs is synchronous and nests', () {
      final outer = context('a');
      final inner = context('b');
      FirestoreAttribution.runAs(outer, () {
        expect(FirestoreAttribution.current, outer);
        FirestoreAttribution.runAs(inner, () => expect(FirestoreAttribution.current, inner));
        expect(FirestoreAttribution.current, outer);
      });
      expect(FirestoreAttribution.current, isNull);
    });

    test('collections are keyed by shape, so the table is bounded by the schema', () {
      expect(FirestoreAttribution.shapeOf('groups/g1/members'), 'groups/members');
      FirestoreAttribution.noteCollection('groups/g1/members', context('groups'));
      expect(FirestoreAttribution.appForDocument('groups/g2/members/u1'), 'groups');
      expect(FirestoreAttribution.appForDocument('groups/g2'), isNull);
    });

    test('collection groups match by collection id', () {
      FirestoreAttribution.noteCollectionGroup('comments', 'forum');
      expect(FirestoreAttribution.appForDocument('posts/p/comments/c'), 'forum');
    });

    test('nothing known is ~unknown', () {
      expect(FirestoreAttribution.resolve(null, 'misc/a').appId, unknownFirestoreAppId);
    });
  });
}

// -----------------------------------------------------------------------------
// Fake platform classes, composed like the web/native ones.
// -----------------------------------------------------------------------------

class _Backend {
  Future<void>? writeGate;
  final events = StreamController<DocumentSnapshotPlatform>.broadcast(sync: true);
}

class _Snap extends DocumentSnapshotPlatform {
  _Snap(FirebaseFirestorePlatform fs, String path, Map<String, dynamic>? data, bool fromCache)
      : super(fs, path, data, InternalSnapshotMetadata(hasPendingWrites: false, isFromCache: fromCache));
}

class _PluginFirestore extends FirebaseFirestorePlatform {
  _PluginFirestore(this.backend);
  final _Backend backend;
}

class _Firestore extends _PluginFirestore with MeteredFirestorePlatform {
  _Firestore(super.backend);

  @override
  CollectionReferencePlatform newMeteredCollection(String path, FirestoreMeteringContext? metering) =>
      _Collection(this, path, metering);

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      _Doc(this, path, metering);
}

class _PluginCollection extends CollectionReferencePlatform {
  _PluginCollection(super.firestore, super.path);
}

class _Collection extends _PluginCollection with MeteredCollectionReferencePlatform {
  _Collection(super.firestore, super.path, this.metering);

  @override
  final FirestoreMeteringContext? metering;

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      _Doc(firestore as _Firestore, path, metering);
}

class _PluginDoc extends DocumentReferencePlatform {
  _PluginDoc(_Firestore super.firestore, super.path);

  _Backend get backend => (firestore as _Firestore).backend;

  @override
  Future<DocumentSnapshotPlatform> get([GetOptions options = const GetOptions()]) async =>
      _Snap(firestore, path, {'n': 1}, false);

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async => backend.writeGate;

  @override
  Future<void> update(Map<FieldPath, dynamic> data) async => backend.writeGate;

  @override
  Future<void> delete() async {}

  @override
  Stream<DocumentSnapshotPlatform> snapshots({bool includeMetadataChanges = false, required ListenSource listenSource}) =>
      backend.events.stream;
}

class _Doc extends _PluginDoc with MeteredDocumentReferencePlatform {
  _Doc(super.firestore, super.path, this.metering);

  @override
  final FirestoreMeteringContext? metering;

  @override
  Future<void> update(Map<Object, dynamic> data) => meter.write(() => super.update(data.cast<FieldPath, dynamic>()));

  @override
  Stream<DocumentSnapshotPlatform> snapshots({bool includeMetadataChanges = false, required ListenSource listenSource}) =>
      meter.snapshots(
        () => super.snapshots(includeMetadataChanges: includeMetadataChanges, listenSource: listenSource),
        includeMetadataChanges: includeMetadataChanges,
      );
}
