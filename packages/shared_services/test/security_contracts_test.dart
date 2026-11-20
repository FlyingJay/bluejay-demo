import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/scoped_storage.dart';
import 'package:shared_services/mime_type_helper.dart';
import 'package:shared_services/notification_service.dart';

String _readLibFile(String fileName) {
  final file = File('${Directory.current.path}/lib/$fileName');
  expect(file.existsSync(), isTrue, reason: 'Missing $fileName contract source');
  return file.readAsStringSync();
}

void main() {
  group('shared_services security contracts', () {
    // ScopedCollection: reads are always group-filtered and fail closed
    // with no active group; writes always stamp the tenancy fields.
    group('ScopedCollection', () {
      late FakeFirebaseFirestore fake;
      late ScopedCollection notes;

      setUp(() async {
        fake = FakeFirebaseFirestore();
        notes = ScopedCollection(
            collection: 'notes', appId: 'notes', firestore: fake);
        await fake
            .doc('notes/a')
            .set({'groupId': 'g1', 'appId': 'notes', 'relatedAppId': 'x'});
        await fake
            .doc('notes/b')
            .set({'groupId': 'g2', 'appId': 'notes', 'relatedAppId': 'x'});
        // A doc with no groupId must never match a "no group" query either.
        await fake.doc('notes/c').set({'appId': 'notes'});
      });

      tearDown(() => ActiveGroupService.instance.activeGroupId = null);

      Future<List<String>> ids(Query<Map<String, dynamic>> q) async =>
          (await q.get()).docs.map((d) => d.id).toList()..sort();

      test('query is filtered to the active group', () async {
        ActiveGroupService.instance.activeGroupId = 'g1';
        expect(await ids(notes.query), ['a']);
      });

      test('query matches nothing with no active group', () async {
        ActiveGroupService.instance.activeGroupId = null;
        expect(await ids(notes.query), isEmpty);
        ActiveGroupService.instance.activeGroupId = '';
        expect(await ids(notes.query), isEmpty);
      });

      test('queryAsReader / queryForRelatedApp fail closed on empty ids',
          () async {
        final threads = ScopedCollection(
            collection: 'threads',
            appId: 'market',
            firestore: fake,
            policy: const CollectionPolicy(readerListField: 'ownerIds'));
        await fake.doc('threads/t1').set({'groupId': 'g2', 'ownerIds': ['u1']});
        await fake.doc('threads/t2').set({'groupId': 'g2', 'ownerIds': ['u2']});
        expect(await ids(threads.queryAsReader('u1')), ['t1']);
        expect(await ids(threads.queryAsReader('')), isEmpty);
        // No reader field declared: no cross-group read at all (D1).
        expect(() => notes.queryAsReader('u1'), throwsStateError);
        expect(await ids(notes.queryForRelatedApp('x')), ['a', 'b']);
        expect(await ids(notes.queryForRelatedApp('')), isEmpty);
      });

      test('queryOwned lists the caller\'s owned docs in the active group',
          () async {
        var uid = 'u1';
        final owned = ScopedCollection(
            collection: 'notes',
            appId: 'notes',
            firestore: fake,
            currentUid: () => uid);
        await fake.doc('notes/mine').set(
            {'groupId': 'g1', 'appId': 'notes', 'ownerIds': ['u1']});
        await fake.doc('notes/shared').set(
            {'groupId': 'g1', 'appId': 'notes', 'ownerIds': ['u2', 'u1']});
        await fake.doc('notes/theirs').set(
            {'groupId': 'g1', 'appId': 'notes', 'ownerIds': ['u2']});
        await fake.doc('notes/elsewhere').set(
            {'groupId': 'g2', 'appId': 'notes', 'ownerIds': ['u1']});
        ActiveGroupService.instance.activeGroupId = 'g1';
        expect(await ids(owned.queryOwned()), ['mine', 'shared']);
        // Fails closed with no signed-in user or no active group.
        uid = '';
        expect(await ids(owned.queryOwned()), isEmpty);
        uid = 'u1';
        ActiveGroupService.instance.activeGroupId = null;
        expect(await ids(owned.queryOwned()), isEmpty);
      });

      test('queryAsClient lists the client\'s records in the active group',
          () async {
        var uid = 'pat';
        final invoices = ScopedCollection(
            collection: 'invoicing_documents',
            appId: 'invoices',
            firestore: fake,
            currentUid: () => uid,
            policy: const CollectionPolicy(
                apps: ['invoices'], clientReaderListField: 'clientUids'));
        await fake.doc('invoicing_documents/mine').set(
            {'groupId': 'g1', 'clientUids': ['pat']});
        await fake.doc('invoicing_documents/theirs').set(
            {'groupId': 'g1', 'clientUids': ['lee']});
        await fake.doc('invoicing_documents/elsewhere').set(
            {'groupId': 'g2', 'clientUids': ['pat']});
        ActiveGroupService.instance.activeGroupId = 'g1';
        expect(await ids(invoices.queryAsClient()), ['mine']);
        uid = '';
        expect(await ids(invoices.queryAsClient()), isEmpty);
        expect(() => notes.queryAsClient(), throwsStateError);
      });

      test('queryAsClient on a record collection reads its client_ projection',
          () async {
        final records = ScopedCollection(
            collection: 'invoicing_documents',
            appId: 'invoices',
            firestore: fake,
            currentUid: () => 'pat');
        await fake.doc('invoicing_documents/i1').set(
            {'groupId': 'g1', 'clientUids': ['pat'], 'payments': []});
        await fake.doc('client_invoicing_documents/i1').set(
            {'groupId': 'g1', 'clientUids': ['pat'], 'number': 'INV-1'});
        ActiveGroupService.instance.activeGroupId = 'g1';
        final snap = await records.queryAsClient().get();
        expect(snap.docs.map((d) => d.reference.path),
            ['client_invoicing_documents/i1']);
        expect(snap.docs.single.data().containsKey('payments'), isFalse);
      });

      test('writes overwrite spoofed tenancy fields', () {
        final stamped = ScopedCollection.permissionFields(
          {'groupId': 'evil', 'appId': 'evil', 'creatorId': 'evil', 'n': 1},
          creatorId: 'u1',
          groupId: 'g1',
          appId: 'notes',
        );
        expect(stamped, {
          'groupId': 'g1',
          'appId': 'notes',
          'creatorId': 'u1',
          'ownerIds': ['u1'],
          'n': 1,
        });
      });

      test('writes keep caller ownerIds, else default to the creator', () {
        expect(
          ScopedCollection.permissionFields({
            'ownerIds': ['u1', 'u2']
          }, creatorId: 'u1', groupId: 'g1', appId: 'notes')['ownerIds'],
          ['u1', 'u2'],
        );
      });
    });

    test('ScopedStorage.published reads only the public namespace', () {
      expect(ScopedStorage.isPublishedPath('published/g1/market/listings/l1/a.png'), isTrue);
      expect(ScopedStorage.isPublishedPath('groups/g1/apps/market/a.png'), isFalse);
      expect(ScopedStorage.isPublishedPath('published/g1/../g2/x'), isFalse);
      expect(ScopedStorage.isPublishedPath('published/'), isFalse);
      expect(() => ScopedStorage.published('groups/g1/apps/storage/files/a.pdf'),
          throwsArgumentError);
    });

    test('ScopedStorage metadata overwrites tenancy fields, default group',
        () {
      final meta = ScopedStorage.permissionMetadata(
        creatorId: 'u1',
        groupId: 'g1',
        appId: 'notes',
        extraMetadata: {
          'creatorId': 'evil',
          'groupId': 'evil',
          'appId': 'evil',
          'visibility': 'public',
        },
      );
      // `visibility` is retired (D2): never sent, not even as extra metadata.
      expect(meta.customMetadata, {
        'creatorId': 'u1',
        'groupId': 'g1',
        'appId': 'notes',
      });
    });

    test('NotificationService keeps null-group suppression contract', () {
      final source = _readLibFile('notification_service.dart');

      expect(source, contains('if (scope == null || scope.isEmpty)'));
      expect(source, contains('return null;'));
    });

    test('NotificationService sends through the notificationsSend callable only',
        () {
      final source = _readLibFile('notification_service.dart');

      expect(source, contains("httpsCallable(sendCallableName)"));
      expect(NotificationService.sendCallableName, 'notificationsSend');
      // No direct client writes to the notifications collection (rules plan
      // T8: the collection is server-written; recipients only flip isRead).
      expect(source, isNot(contains('_ref.add(')));
      expect(source, isNot(contains('.set(')));
    });

    test('MimeTypeHelper uses binary fallback for unknown extensions', () {
      expect(
        MimeTypeHelper.detect('file.bluejaytotallyunknownext'),
        equals('application/octet-stream'),
      );
      expect(MimeTypeHelper.detect('image.png'), equals('image/png'));
      expect(MimeTypeHelper.detect('upload.HEIC'), equals('image/heic'));
      expect(MimeTypeHelper.detect('.heif'), equals('image/heif'));
      expect(MimeTypeHelper.detect('photo.bmp?download=1'), equals('image/bmp'));
    });

    test('MimeTypeHelper.forImage uses the real type of a picked image', () {
      expect(
        MimeTypeHelper.forImage(reportedMimeType: 'image/png', fileName: 'x'),
        equals('image/png'),
      );
      expect(
        MimeTypeHelper.forImage(fileName: 'IMG_0001.HEIC'),
        equals('image/heic'),
      );
      expect(
        MimeTypeHelper.forImage(reportedMimeType: '', fileName: 'shot.png'),
        equals('image/png'),
      );
      // A non-image reported type or name falls back to JPEG.
      expect(
        MimeTypeHelper.forImage(
            reportedMimeType: 'application/octet-stream', fileName: 'blob'),
        equals('image/jpeg'),
      );
    });
  });
}
