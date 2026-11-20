// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart' show DocumentSnapshotPlatform;
import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/metered_firestore.dart';
import 'package:shared_services/rules_denial_reporter.dart';
import 'package:shared_services/src/document_metering.dart';
import 'package:shared_services/storage_denial_reporting.dart';

FirebaseException firestoreDenied() => FirebaseException(
    plugin: 'cloud_firestore', code: 'permission-denied', message: 'Missing or insufficient permissions.');

FirebaseException storageDenied() =>
    FirebaseException(plugin: 'firebase_storage', code: 'unauthorized', message: 'User is not authorized.');

void main() {
  late List<Map<String, Object?>> sent;
  late RulesDenialReporter reporter;
  late RulesDenialReporter original;

  RulesDenialReporter newReporter({
    Duration flushDelay = const Duration(hours: 1),
    int maxPerSession = 100,
    Future<void> Function(Map<String, Object?>)? send,
  }) =>
      RulesDenialReporter(
        send: send ??
            (payload) async {
              sent.add(payload);
            },
        flushDelay: flushDelay,
        maxPerSession: maxPerSession,
        clientVersion: 'abc123',
        platform: 'web',
        groupId: () => 'bluejay',
        foregroundAppId: () => 'launcher',
        nowMs: () => 1000,
      );

  setUp(() {
    sent = [];
    original = RulesDenialReporter.instance;
    reporter = newReporter();
    RulesDenialReporter.instance = reporter;
  });

  tearDown(() => RulesDenialReporter.instance = original);

  group('shapes', () {
    test('firestoreShape drops document ids', () {
      expect(RulesDenialReporter.firestoreShape('notes'), 'notes');
      expect(RulesDenialReporter.firestoreShape('notes/abc'), 'notes');
      expect(RulesDenialReporter.firestoreShape('groups/g1/members'), 'groups/members');
      expect(RulesDenialReporter.firestoreShape('groups/g1/members/u2'), 'groups/members');
      expect(RulesDenialReporter.firestoreShape('users/uid123/metadata/access_index'), 'users/metadata');
    });

    test('storageFamily drops group ids, user ids and file names', () {
      expect(RulesDenialReporter.storageFamily('groups/g1/apps/gallery/photos/uuid_Jane Doe passport.jpg'),
          'groups/{groupId}/apps/gallery/photos');
      expect(RulesDenialReporter.storageFamily('groups/g1/apps/gallery/photos', isListing: true),
          'groups/{groupId}/apps/gallery/photos');
      expect(RulesDenialReporter.storageFamily('groups/g1/apps/gallery/secret.pdf'), 'groups/{groupId}/apps/gallery');
      expect(RulesDenialReporter.storageFamily('groups/g1/logo.jpg'), 'groups/{groupId}/logo.jpg');
      expect(RulesDenialReporter.storageFamily('groups/g1/other.png'), 'groups/{groupId}/*');
      expect(RulesDenialReporter.storageFamily('profile_pictures/uid123/me.jpg'), 'profile_pictures/*');
      expect(RulesDenialReporter.storageAppId('groups/g1/apps/gallery/photos/x'), 'gallery');
      expect(RulesDenialReporter.storageAppId('profile_pictures/u/x'), isNull);
    });

    test('filterFieldName names fields, never values', () {
      expect(RulesDenialReporter.filterFieldName('groupId'), 'groupId');
      expect(RulesDenialReporter.filterFieldName(FieldPath(const ['meta', 'owner'])), 'meta.owner');
      expect(RulesDenialReporter.filterFieldName(Filter('a', isEqualTo: 'secret')), '<filter>');
    });
  });

  group('queue', () {
    test('reports each (service, op, collection) once per session', () async {
      for (var i = 0; i < 3; i++) {
        reporter.firestore(firestoreDenied(), op: 'get', path: () => 'notes/doc$i', appId: 'notes');
      }
      reporter.firestore(firestoreDenied(), op: 'list', path: () => 'notes', appId: 'notes', isQuery: true);
      await reporter.flush();
      expect(sent, hasLength(1));
      final reports = sent.single['reports']! as List;
      expect(reports, hasLength(2));
      expect(sent.single['clientVersion'], 'abc123');
      expect(sent.single['platform'], 'web');
      expect(reports.first, {
        'service': 'firestore',
        'op': 'get',
        'collection': 'notes',
        'appId': 'notes',
        'groupId': 'bluejay',
        'isQuery': false,
        'filterFields': <String>[],
        'clientTime': 1000,
      });
    });

    test('ignores errors that are not rules denials', () async {
      reporter.firestore(StateError('x'), op: 'get', path: () => 'notes/a', appId: 'notes');
      reporter.firestore(FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
          op: 'get', path: () => 'notes/a', appId: 'notes');
      reporter.storage(FirebaseException(plugin: 'firebase_storage', code: 'object-not-found'),
          op: 'download', fullPath: () => 'a/b');
      await reporter.flush();
      expect(sent, isEmpty);
    });

    test('debounces: one send a short while after the first denial', () async {
      reporter = newReporter(flushDelay: const Duration(milliseconds: 20));
      reporter.firestore(firestoreDenied(), op: 'get', path: () => 'a/1', appId: 'x');
      reporter.firestore(firestoreDenied(), op: 'get', path: () => 'b/1', appId: 'x');
      expect(sent, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent, hasLength(1));
      expect((sent.single['reports']! as List), hasLength(2));
    });

    test('sends a full batch at once and caps reports per session', () async {
      reporter = newReporter(maxPerSession: 30);
      for (var i = 0; i < 40; i++) {
        reporter.firestore(firestoreDenied(), op: 'get', path: () => 'c$i/doc', appId: 'x');
      }
      await reporter.flush();
      final counts = [for (final p in sent) (p['reports']! as List).length];
      expect(counts, [RulesDenialReporter.maxBatch, 30 - RulesDenialReporter.maxBatch]);
    });

    test('a failed send is dropped, never thrown', () async {
      reporter = newReporter(send: (_) => Future.error(StateError('offline')));
      reporter.firestore(firestoreDenied(), op: 'get', path: () => 'a/1', appId: 'x');
      await expectLater(reporter.flush(), completes);
      expect(reporter.pending, isEmpty);
    });

    test('a throwing path callback never reaches the caller', () {
      expect(
        () => reporter.firestore(firestoreDenied(), op: 'get', path: () => throw StateError('no path'), appId: 'x'),
        returnsNormally,
      );
    });
  });

  group('Firestore gateways', () {
    const ctx = FirestoreMeteringContext('notes', _noop);

    test('a denied query rethrows the same error and reports shape and filter fields, not values', () async {
      final error = firestoreDenied();
      final notes = MeteredCollectionReference<Map<String, dynamic>>(
          _DeniedCollection('groups/g1/members', error), ctx);
      final query = notes.where('creatorId', isEqualTo: 'uid-SECRET').where('email', isEqualTo: 'jane@x.com');
      await expectLater(query.get(), throwsA(same(error)));
      await expectLater(query.count().get(), throwsA(same(error)));
      await reporter.flush();
      final report = (sent.single['reports']! as List).single as Map;
      expect(report['op'], 'list');
      expect(report['collection'], 'groups/members');
      expect(report['isQuery'], true);
      expect(report['filterFields'], ['creatorId', 'email']);
      final json = jsonEncode(sent);
      for (final leak in ['g1', 'uid-SECRET', 'jane@x.com', 'Missing or insufficient']) {
        expect(json.contains(leak), isFalse, reason: 'leaked $leak');
      }
    });

    test('a denied listener is reported and its error passed through unchanged', () async {
      final error = firestoreDenied();
      final notes = MeteredCollectionReference<Map<String, dynamic>>(_DeniedCollection('notes', error), ctx);
      await expectLater(notes.snapshots(), emitsError(same(error)));
      await reporter.flush();
      expect(((sent.single['reports']! as List).single as Map)['collection'], 'notes');
    });

    test('a collection-group query is marked as one', () async {
      final error = firestoreDenied();
      final query = MeteredQuery<Map<String, dynamic>>(_DeniedQuery(error), ctx,
          source: 'members', collectionGroup: true);
      await expectLater(query.get(), throwsA(same(error)));
      await reporter.flush();
      expect(((sent.single['reports']! as List).single as Map)['collection'], '**/members');
    });

    test('a denied batch commit names its collections, not its documents', () async {
      final fake = FakeFirebaseFirestore();
      final error = firestoreDenied();
      final batch = MeteredWriteBatch(_DeniedBatch(error), ctx);
      batch.set(fake.doc('notes/abc123'), {'title': 'private title'});
      batch.delete(fake.doc('groups/g1/members/u2'));
      await expectLater(batch.commit(), throwsA(same(error)));
      await reporter.flush();
      final report = (sent.single['reports']! as List).single as Map;
      expect(report['op'], 'commit');
      expect(report['collection'], 'groups/members,notes');
      expect(jsonEncode(sent).contains('private title'), isFalse);
    });

    test('document operations (platform layer) report get/write/update/delete by collection shape', () async {
      final error = firestoreDenied();
      final meter = DocumentOpsMeter('groups/g1/members/u2', ctx);
      await expectLater(meter.get<DocumentSnapshotPlatform>(() => Future.error(error)), throwsA(same(error)));
      await expectLater(meter.write(() => Future.error(error)), throwsA(same(error)));
      await expectLater(meter.write(() => Future.error(error), op: 'update'), throwsA(same(error)));
      await expectLater(meter.delete(() => Future.error(error)), throwsA(same(error)));
      await expectLater(
        meter.snapshots<DocumentSnapshotPlatform>(() => Stream.error(error), includeMetadataChanges: false),
        emitsError(same(error)),
      );
      await reporter.flush();
      final reports = (sent.single['reports']! as List).cast<Map>();
      expect(reports.map((r) => r['op']), ['get', 'write', 'update', 'delete']);
      expect(reports.map((r) => r['collection']).toSet(), {'groups/members'});
      expect(reports.map((r) => r['appId']).toSet(), {'notes'});
      expect(jsonEncode(sent).contains('u2'), isFalse);
    });

    test('a non-denial failure is not reported', () async {
      final batch = MeteredWriteBatch(_DeniedBatch(StateError('aborted')), ctx);
      await expectLater(batch.commit(), throwsStateError);
      await reporter.flush();
      expect(sent, isEmpty);
    });
  });

  group('Storage platform wrapper', () {
    test('reports a denied download and upload, passing results and errors through', () async {
      final error = storageDenied();
      final storage = DenialReportingStoragePlatform(_FakeStorage(error));
      final ref = storage.ref('groups/g1/apps/gallery/photos/uuid_passport.jpg');
      expect(ref, isA<DenialReportingReference>());
      expect(ref.fullPath, 'groups/g1/apps/gallery/photos/uuid_passport.jpg');
      await expectLater(ref.getDownloadURL(), throwsA(same(error)));
      // gateway-exempt: storage-put drives the platform wrapper with a fake reference; nothing is uploaded
      final task = ref.putData(Uint8List(1));
      await expectLater(task.onComplete, throwsA(same(error)));
      expect(ref.child('x'), isA<DenialReportingReference>());
      expect(ref.parent, isA<DenialReportingReference>());
      await reporter.flush();
      final reports = (sent.single['reports']! as List).cast<Map>();
      expect(reports.map((r) => r['op']), ['download', 'upload']);
      expect(reports.first['service'], 'storage');
      expect(reports.first['collection'], 'groups/{groupId}/apps/gallery/photos');
      expect(reports.first['appId'], 'gallery');
      expect(jsonEncode(sent).contains('passport'), isFalse);
    });

    test('install wraps the platform instance once', () {
      final base = _FakeStorage(storageDenied());
      final previous = FirebaseStoragePlatform.instance;
      FirebaseStoragePlatform.instance = base;
      resetStorageDenialReportingForTesting();
      try {
        expect(installStorageDenialReporting(), isTrue);
        expect(installStorageDenialReporting(), isTrue);
        final installed = FirebaseStoragePlatform.instance;
        expect(installed, isA<DenialReportingStoragePlatform>());
        expect((installed as DenialReportingStoragePlatform).inner, same(base));
      } finally {
        FirebaseStoragePlatform.instance = previous;
        resetStorageDenialReportingForTesting();
      }
    });
  });
}

void _noop(String appId, String metric, num amount) {}

class _DeniedQuery extends Fake implements Query<Map<String, dynamic>> {
  _DeniedQuery(this.error);
  final Object error;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) => Future.error(error);

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      Stream.error(error);

  @override
  Query<Map<String, dynamic>> where(Object field,
          {Object? isEqualTo,
          Object? isNotEqualTo,
          Object? isLessThan,
          Object? isLessThanOrEqualTo,
          Object? isGreaterThan,
          Object? isGreaterThanOrEqualTo,
          Object? arrayContains,
          Iterable<Object?>? arrayContainsAny,
          Iterable<Object?>? whereIn,
          Iterable<Object?>? whereNotIn,
          bool? isNull}) =>
      this;

  @override
  AggregateQuery count() => _DeniedAggregate(error);
}

class _DeniedCollection extends _DeniedQuery implements CollectionReference<Map<String, dynamic>> {
  _DeniedCollection(this.path, Object error) : super(error);

  @override
  final String path;
}

class _DeniedAggregate extends Fake implements AggregateQuery {
  _DeniedAggregate(this.error);
  final Object error;

  @override
  Future<AggregateQuerySnapshot> get({AggregateSource source = AggregateSource.server}) => Future.error(error);
}

class _DeniedBatch extends Fake implements WriteBatch {
  _DeniedBatch(this.error);
  final Object error;

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {}

  @override
  void delete(DocumentReference document) {}

  @override
  Future<void> commit() => Future.error(error);
}

class _FakeStorage extends FirebaseStoragePlatform {
  _FakeStorage(this.error) : super(bucket: 'bucket');
  final Object error;

  @override
  ReferencePlatform ref(String path) => _FakeRef(this, path);
}

class _FakeRef extends ReferencePlatform {
  _FakeRef(this._fake, String path) : super(_fake, path);
  final _FakeStorage _fake;

  @override
  ReferencePlatform? get parent {
    final slash = fullPath.lastIndexOf('/');
    return slash <= 0 ? null : _FakeRef(_fake, fullPath.substring(0, slash));
  }

  @override
  ReferencePlatform child(String path) => _FakeRef(_fake, '$fullPath/$path');

  @override
  Future<String> getDownloadURL() => Future.error(_fake.error);

  @override
  TaskPlatform putData(Uint8List data, [SettableMetadata? metadata]) => _FailedTask(_fake.error);
}

class _FailedTask extends TaskPlatform {
  _FailedTask(Object error) : _onComplete = Future.error(error);
  final Future<TaskSnapshotPlatform> _onComplete;

  @override
  Future<TaskSnapshotPlatform> get onComplete => _onComplete;
}
