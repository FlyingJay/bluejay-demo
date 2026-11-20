/// Shared places for head-to-head games: the `game` launch arg that opens
/// one game, the [PlaceMarker] a game screen wears, and the launcher that
/// opens a shared game over its app's lobby.
///
/// A game screen marks itself so Chat's "Link to where I am" names it:
///
/// ```dart
/// GamePlace(
///   appId: APP_ID,
///   gameName: 'Chess',
///   gameId: gameId,
///   myId: currentUser.uid,
///   players: {for (final e in players.entries) e.key: e.value.label},
///   child: board,
/// )
/// ```
///
/// `AppRouter` opens `{game: id}` with [SharedGameLauncher]: the lobby, and
/// the game on top of it when the viewer plays in it.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'scoped_collection.dart';
import 'shared_place.dart';

/// Launch arg naming one game (its doc id) in a head-to-head game app.
const String gameArg = 'game';

/// What a shared place calls a game: "Chess with Sam" for one of its
/// players, "Chess: Sam vs Alex" for anyone else, [gameName] alone before
/// the names load. [players] maps each player's uid to their name.
String gamePlaceTitle(
  String gameName, {
  required String myId,
  required Map<String, String> players,
}) {
  final others = [
    for (final e in players.entries)
      if (e.key != myId && e.value.trim().isNotEmpty) e.value.trim(),
  ];
  if (others.isEmpty) return gameName;
  if (!players.containsKey(myId)) return '$gameName: ${others.join(' vs ')}';
  final names = others.length == 1
      ? others.single
      : '${others.sublist(0, others.length - 1).join(', ')} and ${others.last}';
  return '$gameName with $names';
}

/// Marks a game screen as a shared place: `{game: gameId}` in [appId],
/// titled by [gamePlaceTitle]. A game screen is pushed above its app's
/// marker, so it names its app itself.
class GamePlace extends StatelessWidget {
  final String appId;

  /// The game's name, e.g. 'Chess'; also the app's name in the place.
  final String gameName;
  final String gameId;

  /// The viewer's uid.
  final String myId;

  /// Each player's uid and name, as far as they've loaded.
  final Map<String, String> players;
  final Widget child;

  const GamePlace({
    super.key,
    required this.appId,
    required this.gameName,
    required this.gameId,
    required this.myId,
    this.players = const {},
    required this.child,
  });

  @override
  Widget build(BuildContext context) => PlaceMarker(
        appId: appId,
        appName: gameName,
        args: {gameArg: gameId},
        title: gamePlaceTitle(gameName, myId: myId, players: players),
        child: child,
      );
}

/// Whether someone can open a shared game.
enum SharedGameAccess {
  /// They play in it.
  player,

  /// It exists, but they aren't one of its players.
  notPlayer,

  /// It's gone, or they can't read it.
  unavailable,
}

/// Reads game [gameId] from [collection] (an app's games, each listing its
/// players in `memberIds`) and says whether [uid] plays in it.
Future<SharedGameAccess> sharedGameAccess({
  required String collection,
  required String appId,
  required String gameId,
  required String uid,
  @visibleForTesting FirebaseFirestore? firestore,
}) async {
  try {
    final games = ScopedCollection(
      collection: collection,
      appId: appId,
      // Passed through from this function's own test hook.
      // ignore: invalid_use_of_visible_for_testing_member
      firestore: firestore,
    );
    final snap = await games.doc(gameId).get();
    final data = snap.data();
    if (!snap.exists || data == null) return SharedGameAccess.unavailable;
    final memberIds = data['memberIds'];
    return memberIds is List && memberIds.contains(uid)
        ? SharedGameAccess.player
        : SharedGameAccess.notPlayer;
  } catch (_) {
    // permission-denied (another group's game, or no access) or offline.
    return SharedGameAccess.unavailable;
  }
}

/// An app's lobby ([child]) that opens a shared game on top of itself once
/// shown, when the viewer plays in it; otherwise the lobby stays, with a
/// note saying why. None of the head-to-head games has a spectator view, so
/// someone who isn't playing lands in the lobby.
class SharedGameLauncher extends StatefulWidget {
  final String appId;

  /// The app's games collection, e.g. `chess_games`.
  final String collection;
  final String gameId;

  /// The viewer's uid.
  final String uid;

  /// The game's screen, pushed over the lobby.
  final WidgetBuilder gameBuilder;
  final Widget child;

  @visibleForTesting
  final FirebaseFirestore? firestore;

  const SharedGameLauncher({
    super.key,
    required this.appId,
    required this.collection,
    required this.gameId,
    required this.uid,
    required this.gameBuilder,
    required this.child,
    this.firestore,
  });

  @override
  State<SharedGameLauncher> createState() => _SharedGameLauncherState();
}

class _SharedGameLauncherState extends State<SharedGameLauncher> {
  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final access = await sharedGameAccess(
      collection: widget.collection,
      appId: widget.appId,
      gameId: widget.gameId,
      uid: widget.uid,
      firestore: widget.firestore,
    );
    if (!mounted) return;
    switch (access) {
      case SharedGameAccess.player:
        Navigator.of(context).push(MaterialPageRoute(builder: widget.gameBuilder));
      case SharedGameAccess.notPlayer:
        _note("You aren't playing in that game, so it can't be opened for you.");
      case SharedGameAccess.unavailable:
        _note("That game isn't available. It may have been deleted, or you can't see it.");
    }
  }

  void _note(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
