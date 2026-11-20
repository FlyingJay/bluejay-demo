import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/access_index.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/group_docs.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/user_app_entitlements.dart';

/// The shared read helpers for the platform registries (access index,
/// groups, memberships) and ScopedCollection.queryInGroup.
void main() {
  late FakeFirebaseFirestore fake;
  late List<String> metered;

  FirebaseFirestore db(String appId) => MeteredFirestore(
        FirestoreMeteringContext(appId, (app, metric, n) => metered.add('$app $metric')),
        resolve: () => fake,
      );

  setUp(() async {
    fake = FakeFirebaseFirestore();
    metered = [];
    await fake.doc('users/u1/metadata/access_index').set({
      'roles': ['developer'],
      'status': 'ACTIVE',
      'entitlements': ['g1:notes'],
    });
    await fake.doc('groups/g1').set({
      'groupId': 'g1',
      'name': 'One',
      'memberIds': ['u1', 'u2'],
      'installedApps': ['notes', 'wiki'],
    });
    await fake.doc('groups/g2').set({
      'groupId': 'g2',
      'name': 'Two',
      'memberIds': ['u2'],
      'installedApps': ['wiki'],
    });
    await fake.doc('memberships/g1_u1').set({'groupId': 'g1', 'userId': 'u1', 'role': 'admin'});
    await fake.doc('memberships/g1_u2').set({'groupId': 'g1', 'userId': 'u2', 'role': 'member'});
    await fake.doc('memberships/g2_u2').set({'groupId': 'g2', 'userId': 'u2', 'role': 'owner'});
  });

  group('AccessIndex', () {
    test('ref is users/{uid}/metadata/access_index', () {
      expect(AccessIndex.ref('u1', appId: 'notes', firestore: fake).path, 'users/u1/metadata/access_index');
    });

    test('get, loadData and snapshots read the doc, attributed to appId', () async {
      final snap = await AccessIndex.get('u1', appId: 'notes', firestore: db('notes'));
      expect(snap.exists, isTrue);
      expect(snap.data()!['roles'], ['developer']);
      expect(await AccessIndex.loadData('u1', appId: 'notes', firestore: fake), containsPair('status', 'ACTIVE'));
      expect((await AccessIndex.snapshots('u1', appId: 'notes', firestore: fake).first).data()!['entitlements'],
          ['g1:notes']);
      expect(await AccessIndex.watchData('u1', appId: 'notes', firestore: fake).first, containsPair('status', 'ACTIVE'));
    });

    test('a missing index reads as a non-existent doc / null data', () async {
      expect((await AccessIndex.get('nobody', appId: 'notes', firestore: fake)).exists, isFalse);
      expect(await AccessIndex.loadData('nobody', appId: 'notes', firestore: fake), isNull);
    });

    test('UserAppEntitlements parses what AccessIndex reads', () async {
      final access = UserAppEntitlements.fromAccessIndexData(
          await AccessIndex.loadData('u1', appId: 'notes', firestore: fake));
      expect(access.isPlatformAdmin, isTrue);
      expect(access.entitlements, {'g1:notes'});
    });
  });

  group('GroupDocs', () {
    test('get / snapshots by id', () async {
      expect((await GroupDocs.get('g1', appId: 'x', firestore: fake)).data()!['name'], 'One');
      expect((await GroupDocs.snapshots('g2', appId: 'x', firestore: fake).first).data()!['name'], 'Two');
      expect(GroupDocs.ref('g1', appId: 'x', firestore: fake).path, 'groups/g1');
    });

    test('ofMember lists the groups a uid belongs to', () async {
      final ids = (await GroupDocs.ofMember('u1', appId: 'x', firestore: fake).get()).docs.map((d) => d.id);
      expect(ids, ['g1']);
      final both = (await GroupDocs.ofMember('u2', appId: 'x', firestore: fake).get()).docs.map((d) => d.id);
      expect(both, unorderedEquals(['g1', 'g2']));
    });

    test('withGroupIdField, withInstalledApp and all', () async {
      expect((await GroupDocs.withGroupIdField('g2', appId: 'x', firestore: fake).get()).docs.single.id, 'g2');
      expect(
          (await GroupDocs.withInstalledApp('notes', appId: 'x', firestore: fake).count().get()).count, 1);
      expect(
          (await GroupDocs.withInstalledApp('wiki', appId: 'x', firestore: fake).count().get()).count, 2);
      expect((await GroupDocs.all(appId: 'x', firestore: fake).get()).docs, hasLength(2));
    });

    test('reads are metered against the given appId', () async {
      await GroupDocs.all(appId: 'app_creator', firestore: db('app_creator')).get();
      expect(metered, isNotEmpty);
      expect(metered.every((m) => m.startsWith('app_creator ')), isTrue);
    });
  });

  group('MembershipDocs', () {
    test('docId is {groupId}_{uid}', () {
      expect(MembershipDocs.docId('g1', 'u1'), 'g1_u1');
      expect(MembershipDocs.ref('g1', 'u1', appId: 'x', firestore: fake).path, 'memberships/g1_u1');
    });

    test('get / snapshots by group and uid', () async {
      expect((await MembershipDocs.get('g1', 'u1', appId: 'x', firestore: fake)).data()!['role'], 'admin');
      expect((await MembershipDocs.snapshots('g2', 'u2', appId: 'x', firestore: fake).first).data()!['role'],
          'owner');
      expect((await MembershipDocs.get('g2', 'u1', appId: 'x', firestore: fake)).exists, isFalse);
    });

    test('ofGroup and all', () async {
      final g1 = (await MembershipDocs.ofGroup('g1', appId: 'x', firestore: fake).get()).docs.map((d) => d.id);
      expect(g1, unorderedEquals(['g1_u1', 'g1_u2']));
      expect((await MembershipDocs.all(appId: 'x', firestore: fake).get()).docs, hasLength(3));
    });
  });

  group('ScopedCollection.queryInGroup', () {
    setUp(() async {
      ActiveGroupService.instance.activeGroupId = 'g1';
      await fake.collection('notes').doc('a').set({'groupId': 'g1', 'appId': 'notes'});
      await fake.collection('notes').doc('b').set({'groupId': 'g2', 'appId': 'notes'});
    });

    test('filters to the given group, not the active one; query still uses the active group', () async {
      final notes = ScopedCollection(collection: 'notes', appId: 'notes', firestore: fake);
      expect((await notes.queryInGroup('g2').get()).docs.map((d) => d.id), ['b']);
      expect((await notes.query.get()).docs.map((d) => d.id), ['a']);
    });

    test('an empty group matches nothing', () async {
      final notes = ScopedCollection(collection: 'notes', appId: 'notes', firestore: fake);
      expect((await notes.queryInGroup('').get()).docs, isEmpty);
    });
  });
}
