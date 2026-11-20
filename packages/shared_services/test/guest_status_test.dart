import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/guest_status.dart';

GuestKind _kind({Map<String, dynamic>? index, Map<String, dynamic>? membership, bool anonymous = false}) =>
    GuestStatus.derive(groupDocId: 'g1', accessIndex: index, membership: membership, isAnonymous: anonymous).kind;

void main() {
  group('GuestStatus.derive', () {
    test('a member', () {
      expect(_kind(index: {'groups': ['g1'], 'guest_groups': []}, membership: {'role': 'member'}), GuestKind.member);
      expect(_kind(index: {'groups': ['g1']}, membership: {'role': 'owner'}), GuestKind.member);
    });

    test('a visitor: a guest membership without guestType', () {
      expect(_kind(index: {'groups': ['g1'], 'guest_groups': ['g1']}, membership: {'role': 'guest'}), GuestKind.visitor);
    });

    test('an active client', () {
      expect(
        _kind(
          index: {'groups': ['g1'], 'guest_groups': ['g1']},
          membership: {'role': 'guest', 'guestType': 'client', 'clientStatus': 'active'},
        ),
        GuestKind.client,
      );
    });

    test('a pending client (and any status other than active)', () {
      expect(
        _kind(membership: {'role': 'guest', 'guestType': 'client', 'clientStatus': 'pending'}),
        GuestKind.pendingClient,
      );
      expect(_kind(membership: {'role': 'guest', 'guestType': 'client'}), GuestKind.pendingClient);
    });

    test('an anonymous session is a visitor whatever the reads say', () {
      expect(_kind(anonymous: true), GuestKind.visitor);
      expect(_kind(anonymous: true, membership: {'role': 'member'}), GuestKind.visitor);
    });

    test('the index alone marks a guest (membership unreadable)', () {
      expect(_kind(index: {'groups': ['g1'], 'guest_groups': ['g1']}), GuestKind.visitor);
    });

    test('a stale index still says guest after the membership became a member: guest wins', () {
      expect(_kind(index: {'groups': ['g1'], 'guest_groups': ['g1']}, membership: {'role': 'member'}), GuestKind.visitor);
    });

    test('a guest membership the index has not caught up with is still a guest', () {
      expect(
        _kind(index: {'groups': []}, membership: {'role': 'guest', 'guestType': 'client', 'clientStatus': 'active'}),
        GuestKind.client,
      );
    });

    test('not in the group', () {
      expect(_kind(index: {'groups': ['g2']}), GuestKind.none);
      expect(_kind(), GuestKind.none);
    });

    test('getters', () {
      const client = GuestStatus('g1', GuestKind.client);
      expect(client.isGuest && client.isClient && client.isActiveClient && client.hidesMemberChrome, isTrue);
      const pending = GuestStatus('g1', GuestKind.pendingClient);
      expect(pending.isClient && !pending.isActiveClient, isTrue);
      const member = GuestStatus('g1', GuestKind.member);
      expect(member.isGuest || member.hidesMemberChrome, isFalse);
      expect(const GuestStatus.unknown('g1').hidesMemberChrome, isTrue);
      expect(const GuestStatus('g1', GuestKind.visitor).isVisitor, isTrue);
    });
  });

  group('GuestStatus.isGuestOnly', () {
    test('every group a guest group', () {
      expect(GuestStatus.isGuestOnly({'groups': ['a', 'b'], 'guest_groups': ['a', 'b']}), isTrue);
      expect(GuestStatus.isGuestOnly({'groups': ['a', 'b'], 'guest_groups': ['a']}), isFalse);
      expect(GuestStatus.isGuestOnly({'groups': [], 'guest_groups': []}), isFalse);
      expect(GuestStatus.isGuestOnly(null), isFalse);
    });
  });

  group('GuestStatusService.watch', () {
    late FakeFirebaseFirestore db;

    setUp(() => db = FakeFirebaseFirestore());

    Future<void> seed({Map<String, dynamic>? membership, Map<String, dynamic>? index}) async {
      if (membership != null) await db.collection('memberships').doc('g1_u1').set(membership);
      if (index != null) await db.collection('users').doc('u1').collection('metadata').doc('access_index').set(index);
    }

    test('unknown first, then the derived status', () async {
      await seed(
        membership: {'groupId': 'g1', 'userId': 'u1', 'role': 'guest', 'guestType': 'client', 'clientStatus': 'pending'},
        index: {'groups': ['g1'], 'guest_groups': ['g1']},
      );
      final statuses = GuestStatusService.watch('u1', 'g1', firestore: db);
      await expectLater(
        statuses,
        emitsInOrder([
          const GuestStatus.unknown('g1'),
          const GuestStatus('g1', GuestKind.pendingClient),
        ]),
      );
    });

    test('follows an approval', () async {
      await seed(
        membership: {'groupId': 'g1', 'userId': 'u1', 'role': 'guest', 'guestType': 'client', 'clientStatus': 'pending'},
        index: {'groups': ['g1'], 'guest_groups': ['g1']},
      );
      final seen = <GuestKind>[];
      final sub = GuestStatusService.watch('u1', 'g1', firestore: db).listen((s) => seen.add(s.kind));
      await pumpEventQueue();
      await db.collection('memberships').doc('g1_u1').update({'clientStatus': 'active'});
      await pumpEventQueue();
      await sub.cancel();
      expect(seen, [GuestKind.unknown, GuestKind.pendingClient, GuestKind.client]);
    });

    test('a member', () async {
      await seed(
        membership: {'groupId': 'g1', 'userId': 'u1', 'role': 'member'},
        index: {'groups': ['g1'], 'guest_groups': []},
      );
      expect(await GuestStatusService.watch('u1', 'g1', firestore: db).firstWhere((s) => s.isLoaded),
          const GuestStatus('g1', GuestKind.member));
    });

    test('an anonymous session needs no reads', () async {
      expect(await GuestStatusService.watch('u1', 'g1', isAnonymous: true, firestore: db).first,
          const GuestStatus('g1', GuestKind.visitor));
    });
  });

  group('GuestStatusService queries', () {
    tearDown(() => GuestStatusService.instance.debugSetCurrent(null));

    test('statusIn and isGuestIn read the loaded status', () async {
      final service = GuestStatusService.instance;
      service.debugSetCurrent(const GuestStatus('g1', GuestKind.client));
      expect(service.statusIn('g1')?.isActiveClient, isTrue);
      expect(service.statusIn('g2'), isNull);
      expect(service.isGuestIn(isAnonymous: false), isTrue);
      expect(service.isGuestIn(isAnonymous: true), isTrue);
      expect(await service.isMemberOfActiveGroup(isAnonymous: false), isFalse);

      service.debugSetCurrent(const GuestStatus('g1', GuestKind.member));
      expect(service.isGuestIn(isAnonymous: false), isFalse);
      expect(await service.isMemberOfActiveGroup(isAnonymous: false), isTrue);
      expect(await service.isMemberOfActiveGroup(isAnonymous: true), isFalse);
    });

    test('loaded waits for the status to load', () async {
      final service = GuestStatusService.instance;
      service.debugSetCurrent(const GuestStatus.unknown('g1'));
      expect(service.isGuestIn(isAnonymous: false), isFalse, reason: 'not loaded: no answer yet');
      final pending = service.loaded();
      service.debugSetCurrent(const GuestStatus('g1', GuestKind.visitor));
      expect(await pending, const GuestStatus('g1', GuestKind.visitor));
    });

    test('loaded settles for unknown after the timeout', () async {
      final service = GuestStatusService.instance;
      service.debugSetCurrent(const GuestStatus.unknown('g1'));
      expect(await service.loaded(timeout: const Duration(milliseconds: 10)), const GuestStatus.unknown('g1'));
      expect(await service.isMemberOfActiveGroup(isAnonymous: false).timeout(const Duration(seconds: 15)), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
