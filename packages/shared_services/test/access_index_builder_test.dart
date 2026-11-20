import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/access_index.dart';
import 'package:shared_services/access_index_cache.dart';
import 'package:shared_services/user_app_entitlements.dart';

/// AccessIndexBuilder and friends: the cached value on the first frame.
void main() {
  late FakeFirebaseFirestore fake;

  setUp(() async {
    fake = FakeFirebaseFirestore();
    AccessIndexCache.debugReset(firestore: fake, signedInUid: () => 'u1');
    await fake.doc('users/u1/metadata/access_index').set({
      'roles': ['admin'],
      'status': 'ACTIVE',
    });
  });

  tearDown(() => AccessIndexCache.debugReset());

  /// Flushes the fake Firestore's pending snapshot deliveries.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  /// Lets the shared listener receive its first snapshot (outside the
  /// widget test's fake async zone).
  Future<void> warmCache() async {
    await AccessIndex.get('u1', appId: 'x');
    expect(AccessIndex.current('u1'), isNotNull);
  }

  /// Records each frame's snapshot as "state:value".
  Widget recorder<T>(List<String> frames, String Function(T? data) show,
          Widget Function(AsyncWidgetBuilder<T> builder) wrap) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: wrap((context, snap) {
          frames.add('${snap.connectionState.name}:${show(snap.data)}');
          return const SizedBox();
        }),
      );

  String roles(AccessIndexSnapshot? snap) => '${snap?.data()?['roles']}';

  testWidgets('renders the cached value as active data on the first frame', (tester) async {
    await tester.runAsync(warmCache);
    final frames = <String>[];
    await tester.pumpWidget(recorder<AccessIndexSnapshot>(
      frames,
      roles,
      (builder) => AccessIndexBuilder(uid: 'u1', appId: 'x', builder: builder),
    ));
    expect(frames, ['active:[admin]']);
  });

  testWidgets('parsed and entitlements variants start from the cache too', (tester) async {
    await tester.runAsync(warmCache);
    final parsed = <String>[];
    await tester.pumpWidget(recorder<String>(
      parsed,
      (s) => '$s',
      (builder) => AccessIndexWatchBuilder<String>(uid: 'u1', appId: 'x', parse: _status, builder: builder),
    ));
    expect(parsed, ['active:ACTIVE']);

    final entitlements = <String>[];
    await tester.pumpWidget(recorder<UserAppEntitlements>(
      entitlements,
      (e) => '${e?.isActivePlatformAdmin}',
      (builder) => UserAppEntitlementsBuilder(uid: 'u1', builder: builder),
    ));
    expect(entitlements, ['active:true']);
  });

  testWidgets('waits as usual before the listener has a value', (tester) async {
    expect(AccessIndex.current('u1'), isNull);
    final frames = <String>[];
    await tester.pumpWidget(recorder<AccessIndexSnapshot>(
      frames,
      roles,
      (builder) => AccessIndexBuilder(uid: 'u1', appId: 'x', builder: builder),
    ));
    expect(frames, ['waiting:null']);
    await settle(tester);
    expect(frames.last, 'active:[admin]');
  });

  testWidgets('a firestore override bypasses the cache and waits', (tester) async {
    await tester.runAsync(warmCache);
    final other = FakeFirebaseFirestore();
    await other.doc('users/u1/metadata/access_index').set({
      'roles': ['developer'],
    });
    expect(AccessIndex.current('u1', firestore: other), isNull);
    final frames = <String>[];
    await tester.pumpWidget(recorder<AccessIndexSnapshot>(
      frames,
      roles,
      (builder) => AccessIndexBuilder(uid: 'u1', appId: 'x', firestore: other, builder: builder),
    ));
    expect(frames, ['waiting:null']);
    await settle(tester);
    expect(frames.last, 'active:[developer]');
  });

  testWidgets('PrimedStreamBuilder with no initial data is a plain StreamBuilder', (tester) async {
    final controller = StreamController<int>();
    final frames = <String>[];
    await tester.pumpWidget(recorder<int>(
      frames,
      (v) => '$v',
      (builder) => PrimedStreamBuilder<int>(stream: controller.stream, builder: builder),
    ));
    expect(frames, ['waiting:null']);
    controller.add(1);
    await settle(tester);
    expect(frames.last, 'active:1');
    await controller.close();
  });
}

String _status(Map<String, dynamic>? data) => '${data?['status']}';
