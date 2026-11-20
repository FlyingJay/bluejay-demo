import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/game_place.dart';
import 'package:shared_services/shared_place.dart';

void main() {
  late FakeFirebaseFirestore fake;

  setUp(() async {
    fake = FakeFirebaseFirestore();
    ActiveGroupService.instance
      ..activeGroupId = 'acme'
      ..activeGroupDocId = 'acme'
      ..activeGroupName = 'Acme';
    await fake.doc('chess_games/g1').set({
      'groupId': 'acme',
      'memberIds': ['me', 'sam'],
    });
  });

  tearDown(() {
    CurrentPlace.reset();
    ActiveGroupService.instance
      ..activeGroupId = null
      ..activeGroupDocId = null
      ..activeGroupName = null;
  });

  group('gamePlaceTitle', () {
    test('names the opponents for a player, both sides for anyone else', () {
      expect(gamePlaceTitle('Chess', myId: 'me', players: {'me': 'Jay', 'sam': 'Sam'}), 'Chess with Sam');
      expect(
        gamePlaceTitle('Flock', myId: 'me', players: {'me': 'Jay', 'a': 'Al', 'b': 'Bo', 'c': 'Cy'}),
        'Flock with Al, Bo and Cy',
      );
      expect(gamePlaceTitle('Chess', myId: 'me', players: {'a': 'Al', 'b': 'Bo'}), 'Chess: Al vs Bo');
      expect(gamePlaceTitle('Chess', myId: 'me', players: const {}), 'Chess');
    });
  });

  testWidgets('GamePlace marks the game, naming its app', (t) async {
    await t.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: GamePlace(
        appId: 'chess',
        gameName: 'Chess',
        gameId: 'g1',
        myId: 'me',
        players: {'me': 'Jay', 'sam': 'Sam'},
        child: SizedBox(),
      ),
    ));
    final here = CurrentPlace.here()!;
    expect(here.appId, 'chess');
    expect(here.appName, 'Chess');
    expect(here.args, {gameArg: 'g1'});
    expect(here.title, 'Chess with Sam');
  });

  group('sharedGameAccess', () {
    Future<SharedGameAccess> access(String gameId, String uid) => sharedGameAccess(
          collection: 'chess_games',
          appId: 'chess',
          gameId: gameId,
          uid: uid,
          firestore: fake,
        );

    test('a player, someone else, and a missing game', () async {
      expect(await access('g1', 'me'), SharedGameAccess.player);
      expect(await access('g1', 'kim'), SharedGameAccess.notPlayer);
      expect(await access('gone', 'me'), SharedGameAccess.unavailable);
    });
  });

  group('SharedGameLauncher', () {
    Future<void> launch(WidgetTester t, {required String gameId, required String uid}) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SharedGameLauncher(
            appId: 'chess',
            collection: 'chess_games',
            gameId: gameId,
            uid: uid,
            firestore: fake,
            gameBuilder: (_) => const Text('board'),
            child: const Text('lobby'),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('opens the game over the lobby for a player', (t) async {
      await launch(t, gameId: 'g1', uid: 'me');
      expect(find.text('board'), findsOneWidget);
      t.state<NavigatorState>(find.byType(Navigator)).pop();
      await t.pumpAndSettle();
      expect(find.text('lobby'), findsOneWidget);
    });

    testWidgets('keeps a non-player in the lobby with a note', (t) async {
      await launch(t, gameId: 'g1', uid: 'kim');
      expect(find.text('board'), findsNothing);
      expect(find.text('lobby'), findsOneWidget);
      expect(find.textContaining("aren't playing"), findsOneWidget);
    });

    testWidgets('says a missing game is unavailable', (t) async {
      await launch(t, gameId: 'gone', uid: 'me');
      expect(find.text('board'), findsNothing);
      expect(find.textContaining("isn't available"), findsOneWidget);
    });
  });
}
