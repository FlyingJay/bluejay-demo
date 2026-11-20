import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/firestore_platform_metering.dart';
import 'package:shared_services/src/firestore_platform_metering_native.dart';
import 'package:shared_services/usage_meter.dart';

/// End to end on the method-channel platform: cloud_firestore's public API →
/// the metered platform subclasses → the real pigeon codec → a mocked host.
/// This is the path that crashed when references were wrapped, so the codec
/// cases below (references as field values, filters, FieldValue arguments,
/// decoded from snapshot data) are the regression tests for that design.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = _HostCodec();
  const prefix = 'dev.flutter.pigeon.cloud_firestore_platform_interface.FirebaseFirestoreHostApi.';
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Host calls by method, with their decoded arguments.
  final calls = <String, List<List<Object?>>>{};

  void host(String method, Object? Function(List<Object?> args) reply) {
    messenger.setMockMessageHandler('$prefix$method', (ByteData? message) async {
      final args = codec.decodeMessage(message)! as List<Object?>;
      calls.putIfAbsent(method, () => []).add(args);
      try {
        return codec.encodeMessage(<Object?>[reply(args)]);
      } on PlatformException catch (e) {
        return codec.encodeMessage(<Object?>[e.code, e.message, e.details]);
      }
    });
  }

  InternalSnapshotMetadata meta({bool fromCache = false, bool pending = false}) =>
      InternalSnapshotMetadata(hasPendingWrites: pending, isFromCache: fromCache);

  InternalDocumentSnapshot docSnap(String path, Map<String?, Object?>? data, {bool fromCache = false}) =>
      InternalDocumentSnapshot(path: path, data: data, metadata: meta(fromCache: fromCache));

  num total(String app, String metric) =>
      UsageMeter.instance.pendingEntries.fold<num>(0, (acc, e) => acc + (e.apps[app]?[metric] ?? 0));

  Map<String, num> all() {
    final out = <String, num>{};
    for (final e in UsageMeter.instance.pendingEntries) {
      for (final app in e.apps.entries) {
        for (final m in app.value.entries) {
          out['${app.key} ${m.key}'] = (out['${app.key} ${m.key}'] ?? 0) + m.value;
        }
      }
    }
    return out;
  }

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
    expect(installFirestorePlatformMetering(), isTrue);
  });

  setUp(() async {
    FirestoreAttribution.resetForTesting();
    FirestoreAttribution.foregroundAppId = () => null;
    calls.clear();
    host('documentReferenceSet', (_) => null);
    host('documentReferenceUpdate', (_) => null);
    host('documentReferenceDelete', (_) => null);
    host('documentReferenceGet', (args) {
      final request = args[1]! as DocumentReferenceRequest;
      return docSnap(request.path, {'n': 1});
    });
    UsageMeter.instance
      ..setUser('u1')
      ..setGroup('g1');
    // Drains earlier tests' counts. The flush's own usage_daily write goes
    // through the mocked host and is exempt from metering.
    await UsageMeter.instance.flush();
    calls.clear();
  });

  test('installs the metered platform once; reset then install works', () {
    expect(FirebaseFirestorePlatform.instance, isA<MeteredMethodChannelFirestore>());
    expect(installFirestorePlatformMetering(), isTrue);
    resetFirestorePlatformMeteringForTesting();
    expect(firestorePlatformMeteringInstalled, isFalse);
    expect(installFirestorePlatformMetering(), isTrue);
    expect(firestorePlatformMeteringInstalled, isTrue);
  });

  test('a failed install is loud: error plus a one-time usage signal', () {
    final metered = FirebaseFirestorePlatform.instance;
    final logs = <String>[];
    try {
      FirebaseFirestorePlatform.instance = _UnsupportedPlatform();
      resetFirestorePlatformMeteringForTesting();
      final ok = runZoned(installFirestorePlatformMetering,
          zoneSpecification: ZoneSpecification(print: (_, __, ___, line) => logs.add(line)));
      expect(ok, isFalse);
      expect(firestorePlatformMeteringFailure, contains('unsupported Firestore platform'));
      runZoned(installFirestorePlatformMetering,
          zoneSpecification: ZoneSpecification(print: (_, __, ___, line) => logs.add(line)));
      expect(logs.where((l) => l.contains('ERROR')), hasLength(1));
      expect(all(), {'~platform $meteringInstallFailedMetric': 1});
    } finally {
      FirebaseFirestorePlatform.instance = metered;
      resetFirestorePlatformMeteringForTesting();
      expect(installFirestorePlatformMetering(), isTrue);
    }
  });

  group('operations on references from the gateway', () {
    test('get, set, update and delete are billed to the gateway app', () async {
      final db = BluejayFirestore.forApp('notes');
      final viaDoc = db.doc('notes/a');
      final viaCollection = db.collection('notes').doc('b');
      await viaDoc.get();
      await viaCollection.set({'n': 1});
      await viaCollection.update({'n': 2});
      await viaDoc.delete();
      expect(all(), {'notes fsReads': 1, 'notes fsWrites': 2, 'notes fsDeletes': 1});
    });

    test('attribution is fixed when an operation is issued, not when it completes', () async {
      final gate = Completer<void>();
      messenger.setMockMessageHandler('${prefix}documentReferenceSet', (_) async {
        await gate.future;
        return codec.encodeMessage(<Object?>[null]);
      });
      FirestoreAttribution.foregroundAppId = () => 'first';
      final write = rawFirestore().doc('misc/a').set({'n': 1});
      FirestoreAttribution.foregroundAppId = () => 'second';
      gate.complete();
      await write;
      expect(all(), {'first fsWrites': 1});
    });

    test("ScopedCollection.set bills its own app, whatever the reference's origin", () async {
      final chatRef = BluejayFirestore.forApp('chat').doc('notes/a');
      final notes = ScopedCollection(collection: 'notes', appId: 'notes');
      await notes.set(chatRef, {'n': 1});
      // set() reads the doc first (create-only identity stamping); both
      // the read and the write are billed to the collection's app.
      expect(all(), {'notes fsReads': 1, 'notes fsWrites': 1});
    });

    test('add() is one write, counted once', () async {
      final ref = await BluejayFirestore.forApp('notes').collection('notes').add({'n': 1});
      expect(ref.path, startsWith('notes/'));
      expect(all(), {'notes fsWrites': 1});
      expect(calls['documentReferenceSet'], hasLength(1));
    });

    test('a cache-served get is free', () async {
      host('documentReferenceGet', (args) => docSnap('notes/a', {'n': 1}, fromCache: true));
      await BluejayFirestore.forApp('notes').doc('notes/a').get(const GetOptions(source: Source.cache));
      expect(all(), isEmpty);
    });

    test('a failed write records nothing', () async {
      host('documentReferenceSet', (_) => throw PlatformException(code: 'permission-denied', message: 'no'));
      await expectLater(BluejayFirestore.forApp('notes').doc('notes/a').set({'n': 1}), throwsA(isA<FirebaseException>()));
      expect(all(), isEmpty);
    });

    test('subcollections and parents stay with the app they came from', () async {
      final note = BluejayFirestore.forApp('notes').doc('notes/a');
      await note.collection('items').doc('x').set({'n': 1});
      await note.collection('items').doc('x').parent.doc('y').get();
      await note.parent.doc('c').get();
      expect(all(), {'notes fsWrites': 1, 'notes fsReads': 2});
    });

    test('withConverter references are metered like the plain ones', () async {
      final typed = BluejayFirestore.forApp('notes')
          .collection('notes')
          .withConverter<int>(fromFirestore: (s, _) => s.data()!['n'] as int, toFirestore: (n, _) => {'n': n});
      await typed.doc('a').set(3);
      expect((await typed.doc('a').get()).data(), 1);
      expect(all(), {'notes fsWrites': 1, 'notes fsReads': 1});
    });
  });

  group('references created outside a gateway call', () {
    void hostQuery(List<String> paths) => host(
          'queryGet',
          (_) => InternalQuerySnapshot(
            documents: [for (final p in paths) docSnap(p, {'n': 1})],
            documentChanges: const [],
            metadata: meta(),
          ),
        );

    test('snapshot.reference is billed to the app whose gateway uses its collection', () async {
      hostQuery(['tasks/t1']);
      final snap = await BluejayFirestore.forApp('projects').collection('tasks').get();
      await snap.docs.single.reference.update({'done': true});
      expect(all(), {'projects fsReads': 1, 'projects fsWrites': 1});
    });

    test('a collection used by several apps falls back to the foreground app', () async {
      FirestoreAttribution.foregroundAppId = () => 'profile';
      BluejayFirestore.forApp('chat').collection('users');
      BluejayFirestore.forApp('groups').collection('users');
      hostQuery(['users/u1']);
      final snap = await BluejayFirestore.forApp('chat').collection('users').get();
      await snap.docs.single.reference.get();
      expect(all(), {'chat fsReads': 1, 'profile fsReads': 1});
    });

    test('the raw instance: foreground app, else ~unknown', () async {
      await rawFirestore().doc('misc/a').get();
      FirestoreAttribution.foregroundAppId = () => 'wiki';
      await rawFirestore().collection('misc').doc('b').get();
      expect(all(), {'$unknownFirestoreAppId fsReads': 1, 'wiki fsReads': 1});
    });

    test('collection-group results are billed to the app that queried the group', () async {
      hostQuery(['posts/p1/comments/c1']);
      final snap = await BluejayFirestore.forApp('forum').collectionGroup('comments').get();
      await snap.docs.single.reference.delete();
      expect(all(), {'forum fsReads': 1, 'forum fsDeletes': 1});
    });
  });

  test("Usage Meter's own writes run unmetered; other usage_* access is metered", () async {
    UsageMeter.instance.record('notes', 'opens');
    await UsageMeter.instance.flush();
    expect(calls['documentReferenceSet'], hasLength(1));
    expect(all(), isEmpty);
    await BluejayFirestore.forApp('usage-meter').doc('usage_rollups/x').get();
    expect(all(), {'usage-meter fsReads': 1});
  });

  test('doc() paths count as using the collection', () async {
    FirestoreAttribution.foregroundAppId = () => 'wiki';
    BluejayFirestore.forApp('chat').doc('shared/x');
    BluejayFirestore.forApp('profile').doc('shared/y');
    await rawFirestore().doc('shared/z').get();
    expect(all(), {'wiki fsReads': 1});
  });

  group('references still encode as values (the wrapper design crashed here)', () {
    test('as field data, inside FieldValue.arrayUnion, and in filters', () async {
      host('queryGet', (_) => InternalQuerySnapshot(documents: const [], documentChanges: const [], metadata: meta()));
      final db = BluejayFirestore.forApp('notes');
      final ref = db.collection('notes').doc('a');
      await db.doc('notes/b').set({
        'link': ref,
        'links': FieldValue.arrayUnion([ref]),
      });
      await db.collection('notes').where('link', isEqualTo: ref).get();
      await db.collection('notes').where(Filter('links', arrayContains: ref)).get();

      final set = calls['documentReferenceSet']!.single[1]! as DocumentReferenceRequest;
      expect(set.data!['link'], const _HostRef('[DEFAULT]', 'notes/a'));
      expect(set.data!['links'], {
        'arrayUnion': [const _HostRef('[DEFAULT]', 'notes/a')],
      });
      final queries = calls['queryGet']!;
      expect(queries, hasLength(2));
      for (final query in queries) {
        final parameters = query[3]! as InternalQueryParameters;
        expect('${parameters.where} ${parameters.filters}', contains('_HostRef([DEFAULT], notes/a)'));
      }
    });

    test('a reference decoded from snapshot data is a metered reference', () async {
      host('documentReferenceGet', (args) {
        final request = args[1]! as DocumentReferenceRequest;
        return docSnap(request.path, {'link': const _HostRef('[DEFAULT]', 'notes/z')});
      });
      final snap = await BluejayFirestore.forApp('notes').doc('notes/a').get();
      final link = snap.data()!['link'] as DocumentReference;
      FirestoreAttribution.foregroundAppId = () => 'notes';
      await link.get();
      expect(all(), {'notes fsReads': 2});
    });

    test('equality with plain references is unchanged', () {
      final metered = BluejayFirestore.forApp('notes').doc('notes/a');
      expect(metered, rawFirestore().doc('notes/a'));
      expect(metered.hashCode, rawFirestore().doc('notes/a').hashCode);
    });
  });

  group('document listeners', () {
    late StreamController<InternalDocumentSnapshot> events;
    var observer = 0;

    setUp(() {
      events = StreamController<InternalDocumentSnapshot>.broadcast();
      host('documentReferenceSnapshot', (_) {
        final id = 'obs${observer++}';
        messenger.setMockStreamHandler(
          EventChannel('plugins.flutter.io/firebase_firestore/document/$id', const StandardMethodCodec(PigeonCodec())),
          MockStreamHandler.inline(onListen: (_, sink) {
            events.stream.listen(sink.success);
          }),
        );
        return id;
      });
    });

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('cache snapshots are free (the first too), then one read per server snapshot', () async {
      final seen = <Object?>[];
      final sub = BluejayFirestore.forApp('notes').doc('notes/a').snapshots().listen((s) => seen.add(s.data()?['n']));
      await pump();
      events.add(docSnap('notes/a', {'n': 1}, fromCache: true));
      events.add(docSnap('notes/a', {'n': 2}));
      events.add(docSnap('notes/a', {'n': 3}, fromCache: true));
      await pump();
      expect(seen, [1, 2, 3]);
      expect(total('notes', 'fsReads'), 1);
      await sub.cancel();
    });

    test('with includeMetadataChanges, metadata-only events are free', () async {
      final sub = BluejayFirestore.forApp('notes')
          .doc('notes/a')
          .snapshots(includeMetadataChanges: true)
          .listen((_) {});
      await pump();
      events.add(docSnap('notes/a', {'n': 1}, fromCache: true));
      events.add(docSnap('notes/a', {'n': 1}));
      events.add(docSnap('notes/a', {'n': 2}));
      await pump();
      expect(total('notes', 'fsReads'), 2);
      await sub.cancel();
    });

    test('a missing document still bills its first snapshot', () async {
      final sub = BluejayFirestore.forApp('notes').doc('notes/none').snapshots().listen((_) {});
      await pump();
      events.add(docSnap('notes/none', null));
      await pump();
      expect(total('notes', 'fsReads'), 1);
      await sub.cancel();
    });
  });
}

/// The plugin's own instance, as code that bypasses the gateway uses it.
FirebaseFirestore rawFirestore() => (BluejayFirestore.forApp('raw') as MeteredFirestore).unmetered;

/// A reference as the host sees it (and sends it back).
class _HostRef {
  const _HostRef(this.app, this.path);
  final String app;
  final String path;

  @override
  bool operator ==(Object other) => other is _HostRef && other.app == app && other.path == path;

  @override
  int get hashCode => Object.hash(app, path);

  @override
  String toString() => '_HostRef($app, $path)';
}

/// The host's side of the codec: reads what Dart writes (references as
/// their Firestore instance plus path, FieldValues, settings), which the
/// Dart-side codec never needs to, and writes references the way the host
/// does (app name, path, database id).
class _HostCodec extends PigeonCodec {
  const _HostCodec();

  static const _documentReference = 182;
  static const _arrayUnion = 184;
  static const _arrayRemove = 185;
  static const _delete = 186;
  static const _serverTimestamp = 187;
  static const _incrementDouble = 189;
  static const _incrementInteger = 190;
  static const _fieldPath = 192;
  static const _firestoreInstance = 196;
  static const _settings = 198;

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is _HostRef) {
      buffer.putUint8(_documentReference);
      writeValue(buffer, value.app);
      writeValue(buffer, value.path);
      writeValue(buffer, '(default)');
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case _documentReference:
        final firestore = readValue(buffer)! as Map;
        return _HostRef(firestore['app']! as String, readValue(buffer)! as String);
      case _firestoreInstance:
        final app = readValue(buffer);
        final databaseId = readValue(buffer);
        readValue(buffer); // settings
        return {'app': app, 'databaseId': databaseId};
      case _settings:
        return readValue(buffer);
      case _fieldPath:
        final length = readSize(buffer);
        return FieldPath([for (var i = 0; i < length; i++) readValue(buffer)! as String]);
      case _arrayUnion:
        return {'arrayUnion': readValue(buffer)};
      case _arrayRemove:
        return {'arrayRemove': readValue(buffer)};
      case _incrementDouble:
      case _incrementInteger:
        return {'increment': readValue(buffer)};
      case _delete:
        return 'delete';
      case _serverTimestamp:
        return 'serverTimestamp';
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

class _UnsupportedPlatform extends FirebaseFirestorePlatform {}
