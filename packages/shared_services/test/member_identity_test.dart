import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_services/member_identity.dart';

Future<void> _seed(
        FakeFirebaseFirestore db, String groupId, String uid, Map<String, dynamic> data) =>
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
    await _seed(db, 'g1', 'priya', {
      'email': 'demo-priya@bluejay.gg',
      'displayName': 'Priya Nair',
      'photoURL': 'https://p/priya',
    });
    await _seed(db, 'g1', 'nameless', {'email': 'no-name@bluejay.gg'});
    await _seed(db, 'g2', 'zed', {'email': 'zed@bluejay.gg', 'displayName': 'Zed'});
  });

  group('MemberIdentity', () {
    test('fallback: stored name, then email local part, then unknown', () {
      expect(
          MemberIdentity.fallback(name: 'Sam Okafor', email: 'demo-sam@x.y').label, 'Sam Okafor');
      expect(MemberIdentity.fallback(name: ' ', email: 'demo-sam@x.y').label, 'demo-sam');
      expect(MemberIdentity.fallback(name: 'demo-sam@x.y').label, 'demo-sam');
      // An empty email counts as no email, so an email-shaped name still
      // shows its local part.
      expect(MemberIdentity.fallback(name: 'demo-sam@x.y', email: '').label, 'demo-sam');
      expect(MemberIdentity.fallback(name: 'demo-sam@x.y', email: '  ').label, 'demo-sam');
      expect(MemberIdentity.fallback().label, 'Unknown');
      expect(MemberIdentity.fallback(unknown: 'Opponent').label, 'Opponent');
      expect(MemberIdentity.fallback(email: 'a@b').isResolved, isFalse);
    });

    test('initials: first and last word, or the one word', () {
      expect(MemberIdentity.initialsOf('Priya Nair'), 'PN');
      expect(MemberIdentity.initialsOf('Mary Jane Watson'), 'MW');
      expect(MemberIdentity.initialsOf('demo-priya'), 'DP');
      expect(MemberIdentity.initialsOf('bob'), 'B');
      expect(MemberIdentity.initialsOf('  '), '?');
    });
  });

  group('directory identity lookups', () {
    test('identify by uid uses the display name and picture', () async {
      final id = await dir.identify(uid: 'priya');
      expect(id.label, 'Priya Nair');
      expect(id.photoUrl, 'https://p/priya');
      expect(id.isResolved, isTrue);
    });

    test('identify by email when only an email was stored', () async {
      expect((await dir.identify(email: 'DEMO-PRIYA@bluejay.gg')).label, 'Priya Nair');
    });

    test('a uid the group lacks falls through to the email', () async {
      expect((await dir.identify(uid: 'gone', email: 'demo-priya@bluejay.gg')).label, 'Priya Nair');
    });

    test('someone outside the group gets the fallback', () async {
      final id = await dir.identify(uid: 'zed', email: 'zed@bluejay.gg', name: 'Stored');
      expect(id.label, 'Stored');
      expect(id.isResolved, isFalse);
      expect((await dir.identify(uid: 'zed', groupId: 'g2')).label, 'Zed');
    });

    test('a member with no display name shows their username', () async {
      expect((await dir.identify(uid: 'nameless')).label, 'no-name');
    });

    test('peekIdentity reads only the cache', () async {
      expect(dir.peekIdentity(uid: 'priya', email: 'demo-priya@bluejay.gg').label, 'demo-priya');
      await dir.group();
      expect(dir.peekIdentity(uid: 'priya').label, 'Priya Nair');
      expect(dir.peekIdentity(email: 'demo-priya@bluejay.gg').label, 'Priya Nair');
      expect(dir.cachedMember(uid: 'zed'), isNull);
    });

    test('selfLabel prefers the directory name, then the auth name', () async {
      expect(await dir.selfLabel(uid: 'priya', email: 'demo-priya@bluejay.gg'), 'Priya Nair');
      expect(
        await dir.selfLabel(uid: 'nameless', email: 'no-name@bluejay.gg', authDisplayName: 'Nora'),
        'Nora',
      );
      expect(await dir.selfLabel(uid: 'nameless', email: 'no-name@bluejay.gg'), 'no-name');
      expect(await dir.selfLabel(uid: 'ghost'), 'Someone');
    });

    test('no group to look in shows the fallback', () async {
      ActiveGroupService.instance.activeGroupId = null;
      expect(
          (await dir.identify(uid: 'priya', email: 'demo-priya@bluejay.gg')).label, 'demo-priya');
    });
  });
}
