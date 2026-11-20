import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/app_launch_bridge.dart';
import 'package:shared_services/shared_place.dart';
import 'package:shared_services/user_app_entitlements.dart';

class _User implements fire_auth.User {
  @override
  String get uid => 'u1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final groups = ActiveGroupService.instance;

  setUp(() {
    groups
      ..activeGroupId = 'acme'
      ..activeGroupDocId = 'acme'
      ..activeGroupName = 'Acme'
      ..userGroups = const [
        GroupSummary(docId: 'acme', groupId: 'acme', name: 'Acme', memberCount: 3),
        GroupSummary(docId: 'home', groupId: 'home', name: 'Home', memberCount: 1),
      ];
    groups.groupSwitcher = (id) {
      groups.activeGroupId = id;
      groups.activeGroupDocId = id;
      return true;
    };
  });

  tearDown(() {
    CurrentPlace.reset();
    AppLaunchBridge.resolveScreen = null;
    groups
      ..groupSwitcher = null
      ..userGroups = const []
      ..activeGroupId = null
      ..activeGroupDocId = null
      ..activeGroupName = null;
  });

  group('SharedPlace', () {
    test('round-trips through a map', () {
      const place = SharedPlace(
        groupId: 'acme',
        groupDocId: 'acme',
        groupName: 'Acme',
        appId: 'crm',
        appName: 'CRM',
        args: {'deal': 'd1'},
        title: 'Big deal',
      );
      expect(SharedPlace.fromMap(place.toMap()), place);
      expect(SharedPlace.fromMap(place.toMap())!.appName, 'CRM');
    });

    test('rejects maps without a group and app, drops non-string args', () {
      expect(SharedPlace.fromMap(null), isNull);
      expect(SharedPlace.fromMap({'appId': 'crm'}), isNull);
      final place = SharedPlace.fromMap({
        'groupId': 'acme',
        'appId': 'crm',
        'args': {'deal': 'd1', 'n': 3},
      })!;
      expect(place.args, {'deal': 'd1'});
      expect(place.isRecord, isTrue);
    });

    test('labels an app by name, else by its id in words', () {
      expect(const SharedPlace(groupId: 'g', appId: 'help-desk').appLabel, 'Help desk');
      expect(const SharedPlace(groupId: 'g', appId: 'crm', appName: 'CRM').appLabel, 'CRM');
    });
  });

  group('PlaceMarker', () {
    testWidgets('the innermost marker wins and inherits the app', (t) async {
      await t.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: PlaceMarker(
          appId: 'projects',
          appName: 'Projects',
          child: PlaceMarker(args: {'project': 'p1'}, title: 'Launch', child: SizedBox()),
        ),
      ));
      final here = CurrentPlace.here()!;
      expect(here.appId, 'projects');
      expect(here.appName, 'Projects');
      expect(here.args, {'project': 'p1'});
      expect(here.title, 'Launch');
      expect(here.groupId, 'acme');
      expect(here.groupName, 'Acme');
    });

    testWidgets('a screen pushed above the app takes the app from the marker beneath', (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const PlaceMarker(appId: 'crm', appName: 'CRM', child: SizedBox()),
      ));
      nav.currentState!.push(MaterialPageRoute(
          builder: (_) => const PlaceMarker(args: {'deal': 'd1'}, title: 'Big deal', child: SizedBox())));
      await t.pumpAndSettle();
      final here = CurrentPlace.here()!;
      expect((here.appId, here.appName, here.title), ('crm', 'CRM', 'Big deal'));
      expect(here.args, {'deal': 'd1'});
      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(CurrentPlace.here()!.args, isEmpty);
    });

    testWidgets('falls back to the app once the record screen closes', (t) async {
      await t.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: PlaceMarker(appId: 'crm', child: PlaceMarker(args: {'deal': 'd1'}, child: SizedBox())),
      ));
      expect(CurrentPlace.here()!.args, {'deal': 'd1'});
      await t.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: PlaceMarker(appId: 'crm', child: SizedBox()),
      ));
      expect(CurrentPlace.here()!.args, isEmpty);
      await t.pumpWidget(const SizedBox());
      expect(CurrentPlace.here(), isNull);
    });
  });

  group('openSharedPlace', () {
    const place = SharedPlace(groupId: 'home', appId: 'crm', args: {'deal': 'd1'});
    final opened = <String>[];

    Future<SharedPlaceOutcome> open(WidgetTester t, SharedPlace place, Set<String> entitlements) async {
      opened.clear();
      AppLaunchBridge.resolveScreen = (appId, user, {isDeepLink = false, args}) {
        opened.add('$appId ${args ?? {}}');
        return const SizedBox();
      };
      late BuildContext context;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      return openSharedPlace(context, place,
          user: _User(), entitlements: UserAppEntitlements(entitlements: entitlements));
    }

    testWidgets('switches group and opens the record', (t) async {
      expect(await open(t, place, {'home:crm'}), SharedPlaceOutcome.opened);
      expect(groups.activeGroupId, 'home');
      expect(opened, ['crm {deal: d1}']);
    });

    testWidgets("stops when the viewer isn't in the group", (t) async {
      const elsewhere = SharedPlace(groupId: 'other', appId: 'crm');
      expect(await open(t, elsewhere, {'other:crm'}), SharedPlaceOutcome.notInGroup);
      expect(opened, isEmpty);
      expect(groups.activeGroupId, 'acme');
    });

    testWidgets("stops when the viewer doesn't have the app", (t) async {
      expect(await open(t, place, {'home:chat'}), SharedPlaceOutcome.noAppAccess);
      expect(opened, isEmpty);
      expect(groups.activeGroupId, 'acme', reason: 'no group switch without the app');
    });
  });
}
