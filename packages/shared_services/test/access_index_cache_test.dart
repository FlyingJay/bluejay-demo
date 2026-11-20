import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/access_index.dart';
import 'package:shared_services/access_index_cache.dart';
import 'package:shared_services/user_app_entitlements.dart';

/// The shared access index listener behind AccessIndex / UserAppEntitlements.
void main() {
  late FakeFirebaseFirestore fake;
  late StreamController<String?> auth;
  String? signedIn;

  Future<void> setIndex(String uid, Map<String, dynamic> data) =>
      fake.doc('users/$uid/metadata/access_index').set(data);

  setUp(() async {
    fake = FakeFirebaseFirestore();
    auth = StreamController<String?>.broadcast();
    signedIn = 'u1';
    AccessIndexCache.debugReset(
      firestore: fake,
      signedInUid: () => signedIn,
      authUidChanges: auth.stream,
    );
    await setIndex('u1', {
      'roles': ['developer'],
      'status': 'ACTIVE',
      'entitlements': ['g1:notes'],
    });
  });

  tearDown(() async {
    AccessIndexCache.debugReset();
    await auth.close();
  });

  test('one Firestore listener serves every subscriber and read', () async {
    final a = AccessIndex.snapshots('u1', appId: 'notes');
    final b = AccessIndex.snapshots('u1', appId: 'wiki');
    expect(identical(a, b), isTrue, reason: 'same instance across calls (StreamBuilder in build())');
    expect(identical(AccessIndex.watchData('u1', appId: 'x'), AccessIndex.watchData('u1', appId: 'y')), isTrue);
    expect(identical(UserAppEntitlements.watch('u1'), UserAppEntitlements.watch('u1', appId: 'notes')), isTrue);
    expect(identical(AccessIndex.watch('u1', appId: 'x', parse: _status), AccessIndex.watch('u1', appId: 'y', parse: _status)),
        isTrue);
    expect(await AccessIndex.watch('u1', appId: 'x', parse: _status).first, 'ACTIVE');

    final first = await a.first;
    expect(first.data()!['roles'], ['developer']);
    expect((await b.first).exists, isTrue);
    expect((await AccessIndex.get('u1', appId: 'notes')).data()!['status'], 'ACTIVE');
    expect((await UserAppEntitlements.load('u1')).canAccessApp('g1', 'notes'), isTrue);
    expect(await AccessIndex.loadData('u1', appId: 'notes'), containsPair('status', 'ACTIVE'));
    expect((await UserAppEntitlements.watch('u1').first).isPlatformAdmin, isTrue);

    expect(AccessIndexCache.debugListensOpened, 1);
  });

  test('replays the latest value to new subscribers and exposes it synchronously', () async {
    expect(AccessIndex.current('u1'), isNull);
    final seen = <List<dynamic>?>[];
    final sub = AccessIndex.snapshots('u1', appId: 'notes').listen((s) => seen.add(s.data()?['roles']));
    await pumpEventQueue();
    expect(seen, [
      ['developer'],
    ]);

    await setIndex('u1', {
      'roles': ['admin'],
      'status': 'ACTIVE',
    });
    await pumpEventQueue();
    expect(seen.last, ['admin']);
    expect(AccessIndex.current('u1')!.data()!['roles'], ['admin']);
    expect(UserAppEntitlements.current('u1')!.isActivePlatformAdmin, isTrue);

    // A late subscriber starts from the latest value without waiting for a change.
    final late = await AccessIndex.snapshots('u1', appId: 'wiki').first;
    expect(late.data()!['roles'], ['admin']);
    // get() completes from the cache.
    expect((await AccessIndex.get('u1', appId: 'notes')).data()!['roles'], ['admin']);

    await sub.cancel();
    expect(AccessIndexCache.debugListensOpened, 1);
  });

  test('resets when the signed-in user changes and on sign-out', () async {
    await setIndex('u2', {
      'roles': <String>[],
      'status': 'ACTIVE',
      'entitlements': ['g2:wiki'],
    });
    final u1Stream = AccessIndex.snapshots('u1', appId: 'notes');
    final u1Done = Completer<void>();
    u1Stream.listen((_) {}, onDone: u1Done.complete);
    await pumpEventQueue();
    final u1Listener = AccessIndexCache.debugActive!;
    expect(u1Listener.uid, 'u1');

    signedIn = 'u2';
    auth.add('u2');
    await pumpEventQueue();
    expect(AccessIndexCache.debugActive, isNull, reason: 'dropped on the auth change');
    expect(u1Listener.isListening, isFalse);
    expect(u1Done.isCompleted, isTrue, reason: "the old user's stream is closed");

    // The new user gets their own listener and their own data.
    expect((await UserAppEntitlements.load('u2')).canAccessApp('g2', 'wiki'), isTrue);
    expect(AccessIndexCache.debugActive!.uid, 'u2');
    expect(identical(AccessIndex.snapshots('u2', appId: 'notes'), u1Stream), isFalse);

    // A uid other than the signed-in user's bypasses the cache.
    expect(AccessIndexCache.forUid('u1'), isNull);
    expect(AccessIndex.current('u1'), isNull);
    expect(AccessIndexCache.debugActive!.uid, 'u2');

    signedIn = null;
    auth.add(null);
    await pumpEventQueue();
    expect(AccessIndexCache.debugActive, isNull);
    expect(AccessIndexCache.debugListensOpened, 2);
  });

  test('an explicit firestore bypasses the shared listener', () async {
    final other = FakeFirebaseFirestore();
    await other.doc('users/u1/metadata/access_index').set({'status': 'SUSPENDED'});
    expect(await AccessIndex.loadData('u1', appId: 'notes', firestore: other), containsPair('status', 'SUSPENDED'));
    expect(AccessIndexCache.debugListensOpened, 0);
  });

  test('a missing doc reads as not existing, and fails closed for entitlements', () async {
    signedIn = 'nobody';
    expect((await AccessIndex.get('nobody', appId: 'notes')).exists, isFalse);
    expect((await UserAppEntitlements.load('nobody')).status, 'INACTIVE');
    expect(await UserAppEntitlements.load(''), same(UserAppEntitlements.none));
  });
}

String? _status(Map<String, dynamic>? data) => data?['status'] as String?;
