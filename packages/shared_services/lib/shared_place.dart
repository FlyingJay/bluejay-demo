/// Shared places: where someone is in Bluejay (an app, and the record,
/// project, task or game open in it), in a form a teammate can open.
///
/// Every app launched through `AppRouter.getScreen` is marked with its app
/// id and launch args. A screen showing one record refines that with its own
/// [PlaceMarker], giving the launch args that reopen it and a title:
///
/// ```dart
/// PlaceMarker(
///   title: deal.name,
///   args: {dealArg: deal.id},
///   child: DealScreen(...),
/// )
/// ```
///
/// [CurrentPlace.here] is the innermost marker on screen (the most recently
/// shown one). [openSharedPlace] opens a place as close as the viewer's
/// access allows: the record, else its app, else nothing with the reason.
library;

import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'active_group_service.dart';
import 'app_launch_bridge.dart';
import 'group_app_links.dart';
import 'user_app_entitlements.dart';

/// A place someone can share: an app in a group, the launch args that open
/// a record in it (none for the app's home), and what to call it.
@immutable
class SharedPlace {
  const SharedPlace({
    required this.groupId,
    required this.appId,
    this.appName,
    this.groupDocId,
    this.groupName,
    this.args = const {},
    this.title = '',
  });

  /// The group's `groupId` slug, and its doc id when known.
  final String groupId;
  final String? groupDocId;
  final String? groupName;
  final String appId;

  /// The app's display name when known.
  final String? appName;

  /// [appName], else the app id in words (`'help-desk'` → `'Help desk'`).
  String get appLabel {
    final name = appName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final words = appId.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return words.isEmpty ? appId : words[0].toUpperCase() + words.substring(1);
  }

  /// Launch args for [appId] (`AppLaunchBridge.openApp`), each value a
  /// string, the same keys the app's links use.
  final Map<String, String> args;

  /// What is open there, e.g. "Chess with Sam" or a task's title; empty for
  /// an app's home.
  final String title;

  /// Whether this names a record inside the app, not just the app.
  bool get isRecord => args.isNotEmpty;

  /// The web link to this place (`/{groupId}/{appId}?...`).
  Uri? get uri => groupAppUri(groupId, appId, args: args);

  Map<String, dynamic> toMap() => {
        'groupId': groupId,
        if (groupDocId != null) 'groupDocId': groupDocId,
        if (groupName != null) 'groupName': groupName,
        'appId': appId,
        if (appName != null) 'appName': appName,
        'args': args,
        'title': title,
      };

  /// The place stored in [raw], or null when it names no app and group.
  static SharedPlace? fromMap(Object? raw) {
    if (raw is! Map) return null;
    String? s(String key) {
      final v = raw[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final groupId = s('groupId');
    final appId = s('appId');
    if (groupId == null || appId == null) return null;
    final rawArgs = raw['args'];
    return SharedPlace(
      groupId: groupId,
      groupDocId: s('groupDocId'),
      groupName: s('groupName'),
      appId: appId,
      appName: s('appName'),
      args: {
        if (rawArgs is Map)
          for (final e in rawArgs.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      title: s('title') ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SharedPlace &&
      other.groupId == groupId &&
      other.appId == appId &&
      other.title == title &&
      mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(groupId, appId, title, Object.hashAllUnordered(args.entries.map((e) => '${e.key}=${e.value}')));
}

/// The places marked on screen, innermost last.
class CurrentPlace {
  CurrentPlace._();

  static final List<_PlaceMarkerState> _stack = [];

  /// Where the person is: the most recently shown [PlaceMarker] in the active
  /// group, or null when no app is open.
  static SharedPlace? here() {
    final groups = ActiveGroupService.instance;
    final groupId = groups.activeGroupId;
    if (groupId == null || groupId.isEmpty) return null;
    for (final marker in _stack.reversed) {
      final appId = marker.appId;
      if (appId == null) continue;
      return SharedPlace(
        groupId: groupId,
        groupDocId: groups.activeGroupDocId,
        groupName: groups.activeGroupName,
        appId: appId,
        appName: marker.appName,
        args: marker.widget.args,
        title: marker.widget.title ?? '',
      );
    }
    return null;
  }

  @visibleForTesting
  static void reset() => _stack.clear();
}

/// Marks its subtree as a place [CurrentPlace.here] can report. [appId]
/// defaults to the enclosing marker's (the app's own, from the router), so a
/// screen inside an app gives only its [args] and [title]. A screen an app
/// pushes sits outside the app's marker; it takes the app from the marker
/// that was on top when it was shown.
class PlaceMarker extends StatefulWidget {
  final String? appId;
  final String? appName;
  final Map<String, String> args;
  final String? title;
  final Widget child;

  const PlaceMarker({
    super.key,
    this.appId,
    this.appName,
    this.args = const {},
    this.title,
    required this.child,
  });

  @override
  State<PlaceMarker> createState() => _PlaceMarkerState();
}

class _PlaceMarkerState extends State<PlaceMarker> {
  _PlaceMarkerState? _parent;

  String? get appId => widget.appId ?? _parent?.appId;

  /// Inherited only along with the app id.
  String? get appName =>
      widget.appId != null ? widget.appName : (widget.appName ?? _parent?.appName);

  /// The topmost marker with an app when this one was shown.
  _PlaceMarkerState? _shownOver;

  @override
  void initState() {
    super.initState();
    for (final marker in CurrentPlace._stack.reversed) {
      if (marker.appId != null) {
        _shownOver = marker;
        break;
      }
    }
    CurrentPlace._stack.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = context.findAncestorStateOfType<_PlaceMarkerState>() ?? _shownOver;
  }

  @override
  void dispose() {
    CurrentPlace._stack.remove(this);
    super.dispose();
  }


  @override
  Widget build(BuildContext context) => widget.child;
}

/// How [openSharedPlace] went.
enum SharedPlaceOutcome {
  /// The place opened (an app's own screen decides what to show when its
  /// record is gone or hidden from the viewer).
  opened,

  /// The viewer isn't in the place's group.
  notInGroup,

  /// The viewer is in the group but doesn't have the app there.
  noAppAccess,

  /// The app couldn't be opened (not in this build).
  unavailable,
}

/// Opens [place] for the signed-in viewer on [navigator]'s context: switches
/// to its group when they're in it, then opens its app with its args. Stops
/// short, with the reason, where their access ends.
Future<SharedPlaceOutcome> openSharedPlace(
  BuildContext context,
  SharedPlace place, {
  fire_auth.User? user,
  UserAppEntitlements? entitlements,
}) async {
  final viewer = user ?? fire_auth.FirebaseAuth.instance.currentUser;
  if (viewer == null) return SharedPlaceOutcome.notInGroup;
  final groups = ActiveGroupService.instance;
  final group = groups.groupFor(place.groupDocId) ?? groups.groupFor(place.groupId);
  if (group == null) return SharedPlaceOutcome.notInGroup;

  final access = entitlements ??
      UserAppEntitlements.current(viewer.uid) ??
      await UserAppEntitlements.load(viewer.uid);
  final hasApp = access.hasAppTier(group.docId, place.appId) ||
      access.hasAppTier(group.groupId, place.appId);
  if (!hasApp) return SharedPlaceOutcome.noAppAccess;

  if (!groups.switchTo(group.groupId)) return SharedPlaceOutcome.notInGroup;
  if (!context.mounted) return SharedPlaceOutcome.unavailable;
  final opened = AppLaunchBridge.openApp(context, place.appId, viewer, args: place.args);
  return opened ? SharedPlaceOutcome.opened : SharedPlaceOutcome.unavailable;
}
