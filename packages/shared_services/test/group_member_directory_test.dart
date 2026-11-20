import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/group_member_directory.dart';

Future<void> _seed(FakeFirebaseFirestore db, String groupId, String uid, Map<String, dynamic> data) =>
    db.collection('group_members').doc(GroupMemberDirectory.docId(groupId, uid)).set({
      'groupId': groupId,
      'uid': uid,
      ...data,
    });

void main() {
  late FakeFirebaseFirestore db;
  late GroupMemberDirectory dir;

  setUp(() async {
    db = FakeFirebaseFirestore();
    dir = GroupMemberDirectory(firestore: db);
    ActiveGroupService.instance.activeGroupId = 'g1';
    await _seed(db, 'g1', 'u1', {'email': 'alice@bluejay.gg', 'role': 'owner', 'photoURL': 'https://p/a'});
    await _seed(db, 'g1', 'u2', {'email': 'bob@bluejay.gg', 'displayName': 'Bobby'});
    await _seed(db, 'g1', 'u3', {'isGuest': true, 'guestName': 'Gus', 'role': 'guest'});
    await _seed(db, 'g2', 'u4', {'email': 'zed@bluejay.gg'});
  });

  test('docId matches the server key', () {
    expect(GroupMemberDirectory.docId('my_group', 'u1'), 'my_group__u1');
  });

  test('GroupMember labels: displayName, then guest name, then username', () {
    expect(GroupMember.fromMap({'email': 'Alice@Bluejay.gg'}).label, 'alice');
    expect(GroupMember.fromMap({'email': 'a@b.c', 'displayName': 'Al'}).label, 'Al');
    expect(GroupMember.fromMap({'isGuest': true, 'guestName': 'Gus'}).label, 'Gus');
    expect(GroupMember.fromMap({}).label, 'User');
    expect(GroupMember.fromMap({'status': 'inactive'}).isInactive, isTrue);
  });

  test('a guest membership is a guest even after the visitor claims an account', () {
    // users.isGuest is false once claimed (or for a portal client), but the
    // role stays guest, so member pickers keep leaving them out.
    expect(GroupMember.fromMap({'role': 'guest', 'isGuest': false}).isGuest, isTrue);
    expect(GroupMember.fromMap({'role': 'member', 'isGuest': false}).isGuest, isFalse);
  });

  test('toUserData keeps the legacy users/{uid} field names', () {
    final m = GroupMember.fromMap({'uid': 'u1', 'email': 'a@b.c', 'photoURL': 'https://p'});
    expect(m.toUserData()['profilePictureUrl'], 'https://p');
    expect(m.toUserData()['email'], 'a@b.c');
  });

  test('group() defaults to the active group and sorts by label', () async {
    final members = await dir.group();
    expect(members.map((m) => m.uid), ['u1', 'u2', 'u3']);
  });

  test('members() only returns people in the requested group', () async {
    final found = await dir.members(['u1', 'u4', 'nobody']);
    expect(found.keys, ['u1']);
    final other = await dir.members(['u1', 'u4'], groupId: 'g2');
    expect(other.keys, ['u4']);
  });

  test('member() and findByEmail()', () async {
    expect((await dir.member('u2'))!.label, 'Bobby');
    expect(await dir.member('u4'), isNull);
    expect((await dir.findByEmail('ALICE@bluejay.gg'))!.uid, 'u1');
  });

  test('no active group and no groupId: empty, no query', () async {
    ActiveGroupService.instance.activeGroupId = null;
    expect(await dir.group(), isEmpty);
    expect(await dir.members(['u1']), isEmpty);
  });

  test('watchGroup streams updates', () async {
    final stream = dir.watchGroup('g1');
    expect((await stream.first).length, 3);
    await db.collection('group_members').doc('g1__u2').delete();
    expect((await dir.watchGroup('g1').first).length, 2);
  });

  test('cache: a second lookup does not need the server', () async {
    await dir.group('g1');
    await db.collection('group_members').doc('g1__u1').update({'email': 'changed@bluejay.gg'});
    expect((await dir.member('u1', groupId: 'g1'))!.email, 'alice@bluejay.gg');
    dir.clearCache('g1');
    expect((await dir.member('u1', groupId: 'g1'))!.email, 'changed@bluejay.gg');
  });

  test('timestamps parse', () async {
    final m = GroupMember.fromMap({'joinedAt': Timestamp.fromMillisecondsSinceEpoch(5)});
    expect(m.joinedAt!.millisecondsSinceEpoch, 5);
  });

  group('query sharing', () {
    // Counts one-off queries: MeteredFirestore records reads once per get().
    late int queries;
    late GroupMemberDirectory counted;

    setUp(() {
      queries = 0;
      final ctx = FirestoreMeteringContext('test-app', (_, metric, __) {
        if (metric == FirestoreMeteringContext.reads) queries++;
      });
      counted = GroupMemberDirectory(firestore: MeteredFirestore(ctx, resolve: () => db));
    });

    test('N concurrent rows in one group cause one query', () async {
      final rows = await Future.wait([
        for (var i = 0; i < 20; i++) counted.member(i.isEven ? 'u1' : 'u2', groupId: 'g1'),
      ]);
      expect(rows.where((m) => m != null).length, 20);
      expect(queries, 1);
    });

    test('a uid missing from the group is remembered until the cache expires', () async {
      expect(await counted.member('nobody', groupId: 'g1'), isNull);
      expect(await counted.member('nobody', groupId: 'g1'), isNull);
      expect(await counted.members(['nobody', 'u1'], groupId: 'g1'), hasLength(1));
      expect(queries, 1);
    });

    test('each group loads once', () async {
      await Future.wait([
        counted.member('u1', groupId: 'g1'),
        counted.member('u4', groupId: 'g2'),
        counted.member('u2', groupId: 'g1'),
        counted.member('u4', groupId: 'g2'),
      ]);
      expect(queries, 2);
    });
  });

  test('matchesSearch: name, guest name, email local part, or a full address', () {
    const m = GroupMember(
        groupId: 'g', uid: 'u', email: 'priya@bluejay.gg', displayName: 'Priya Nair');
    expect(m.matchesSearch('nair'), isTrue);
    expect(m.matchesSearch('PRI'), isTrue);
    expect(m.matchesSearch('bluejay'), isFalse);
    expect(m.matchesSearch('priya@bluejay'), isTrue);
    expect(m.matchesSearch(''), isTrue);
    const guest = GroupMember(
        groupId: 'g', uid: 'x', email: '', isGuest: true, guestName: 'Kim Client');
    expect(guest.matchesSearch('kim'), isTrue);
  });
}
