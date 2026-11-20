import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/foundation.dart';

import 'access_index.dart';
import 'active_group_service.dart';
import 'bluejay_firestore.dart';
import 'group_docs.dart';

/// What the signed-in user is in one group.
enum GuestKind {
  /// Not loaded yet.
  unknown,

  /// Not in the group at all.
  none,

  /// A member (any non-guest role).
  member,

  /// An anonymous visitor: a guest session opened from an embeddable app's
  /// link (`createGuestSession`, functions/guest_users.js).
  visitor,

  /// An approved client of the group's portal
  /// (plans/business-suite/CLIENT_PORTAL_PLAN.md).
  client,

  /// A client whose registration waits for the group's approval.
  pendingClient,
}

/// Whether the signed-in user is a guest in a group, and what kind. The one
/// place client code decides "guest": the launcher, the app tray, Request a
/// change and the apps read it instead of `User.isAnonymous`, which says how
/// someone signed in and stopped meaning "guest" once clients got accounts.
///
/// Derived ([derive]) from the access index's `guest_groups` (the groups
/// where the user is any kind of guest, which the rules confine) and the
/// user's own membership doc (`memberships/{groupDocId}_{uid}`: `role`,
/// `guestType`, `clientStatus`; functions/_client_portal.js has the model).
@immutable
class GuestStatus {
  const GuestStatus(this.groupDocId, this.kind);

  /// Not loaded yet for [groupDocId].
  const GuestStatus.unknown(this.groupDocId) : kind = GuestKind.unknown;

  /// The group's doc id (`groups/{id}`).
  final String groupDocId;
  final GuestKind kind;

  bool get isLoaded => kind != GuestKind.unknown;
  bool get isMember => kind == GuestKind.member;
  bool get isVisitor => kind == GuestKind.visitor;
  bool get isActiveClient => kind == GuestKind.client;
  bool get isPendingClient => kind == GuestKind.pendingClient;

  /// A client, approved or not.
  bool get isClient => isActiveClient || isPendingClient;

  /// Any kind of guest: a visitor or a client.
  bool get isGuest => isVisitor || isClient;

  /// Whether member-only chrome (search, notifications, Request a change,
  /// the dev queue, app settings, the member directory) stays hidden: for
  /// every guest, and while the status is still loading.
  bool get hidesMemberChrome => isGuest || !isLoaded;

  /// [groupDocId]'s status from the user's [accessIndex] and [membership]
  /// data (either may be null: missing or unreadable). The guest test is
  /// the union of the two, so a stale index or an unreadable membership
  /// never shows member UI to someone the rules treat as a guest.
  /// [isAnonymous]: an anonymous session is only ever a visitor (members and
  /// clients sign in with an account), so it needs neither read.
  static GuestStatus derive({
    required String groupDocId,
    Map<String, dynamic>? accessIndex,
    Map<String, dynamic>? membership,
    bool isAnonymous = false,
  }) {
    if (isAnonymous) return GuestStatus(groupDocId, GuestKind.visitor);
    List<Object?> list(Object? raw) => raw is List ? raw : const [];
    final role = membership?['role'];
    final indexSaysGuest = list(accessIndex?['guest_groups']).contains(groupDocId);
    if (role == 'guest' || indexSaysGuest) {
      if (membership?['guestType'] == 'client') {
        return GuestStatus(
          groupDocId,
          membership?['clientStatus'] == 'active' ? GuestKind.client : GuestKind.pendingClient,
        );
      }
      return GuestStatus(groupDocId, GuestKind.visitor);
    }
    if (role is String || list(accessIndex?['groups']).contains(groupDocId)) {
      return GuestStatus(groupDocId, GuestKind.member);
    }
    return GuestStatus(groupDocId, GuestKind.none);
  }

  /// Whether an access index's every group is a guest group (and it has at
  /// least one): an account that is only ever a visitor or client, with no
  /// member view of any group.
  static bool isGuestOnly(Map<String, dynamic>? accessIndex) {
    final groups = accessIndex?['groups'];
    final guestGroups = accessIndex?['guest_groups'];
    if (groups is! List || groups.isEmpty || guestGroups is! List) return false;
    return groups.every(guestGroups.contains);
  }

  @override
  bool operator ==(Object other) =>
      other is GuestStatus && other.groupDocId == groupDocId && other.kind == kind;

  @override
  int get hashCode => Object.hash(groupDocId, kind);

  @override
  String toString() => 'GuestStatus($groupDocId, ${kind.name})';
}

/// The signed-in user's [GuestStatus] in the active group, kept current as
/// the user, the active group ([ActiveGroupService.activeGroupDocId]), the
/// access index and the membership change.
///
/// [current] is the listenable (null while signed out or with no active
/// group); [statusIn] and [isGuestIn] are the synchronous queries once it
/// has loaded. [watch] streams any other group's status.
class GuestStatusService {
  GuestStatusService._();

  static final GuestStatusService instance = GuestStatusService._();

  final ValueNotifier<GuestStatus?> _current = ValueNotifier<GuestStatus?>(null);
  StreamSubscription<fire_auth.User?>? _authSub;
  StreamSubscription<GuestStatus>? _statusSub;
  fire_auth.User? _user;
  String? _trackedUid;
  String? _trackedGroup;
  bool? _trackedAnonymous;
  bool _started = false;

  /// The signed-in user's status in the active group, as it changes. Null
  /// while signed out or with no active group; [GuestStatus.unknown] while
  /// loading.
  ValueListenable<GuestStatus?> get current {
    _ensureStarted();
    return _current;
  }

  /// The loaded status in [groupDocId], or null when the active group is
  /// another one or it hasn't loaded yet.
  GuestStatus? statusIn(String? groupDocId) {
    final status = current.value;
    if (status == null || !status.isLoaded) return null;
    return groupDocId == null || status.groupDocId == groupDocId ? status : null;
  }

  /// Whether [user] is a guest in the active group. Before the status has
  /// loaded this falls back to [user]'s anonymity (an anonymous session is
  /// always a visitor), so pass the user the caller has.
  bool isGuestIn({required bool isAnonymous, String? groupDocId}) {
    if (isAnonymous) return true;
    return statusIn(groupDocId)?.isGuest ?? false;
  }

  /// The active group's status once it has loaded: null while signed out
  /// or with no active group. After [timeout] it settles for whatever
  /// [current] holds (possibly [GuestStatus.unknown], which hides member UI).
  Future<GuestStatus?> loaded({Duration timeout = const Duration(seconds: 10)}) {
    final listenable = current;
    bool settled(GuestStatus? status) => status == null || status.isLoaded;
    if (settled(listenable.value)) return Future.value(listenable.value);
    final completer = Completer<GuestStatus?>();
    void listener() {
      if (!settled(listenable.value) || completer.isCompleted) return;
      completer.complete(listenable.value);
    }

    listenable.addListener(listener);
    return completer.future.timeout(timeout, onTimeout: () => listenable.value).whenComplete(
          () => listenable.removeListener(listener),
        );
  }

  /// Whether the signed-in user is a member (not a guest of any kind) of the
  /// active group, waiting for the status to load. False for an anonymous
  /// session, and when the status didn't load in time.
  Future<bool> isMemberOfActiveGroup({required bool isAnonymous}) async {
    if (isAnonymous) return false;
    final status = await loaded();
    return status == null || !status.hidesMemberChrome;
  }

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    try {
      // userChanges also fires when a visitor claims an account (the same
      // uid stops being anonymous).
      _authSub = fire_auth.FirebaseAuth.instance.userChanges().listen((user) {
        _user = user;
        _retrack();
      });
    } catch (_) {
      // Firebase isn't initialized (a test); nothing to follow.
    }
    ActiveGroupService.instance.addListener(_retrack);
  }

  void _retrack() {
    final user = _user;
    final groupDocId = ActiveGroupService.instance.activeGroupDocId;
    final uid = user?.uid;
    final anonymous = user?.isAnonymous;
    if (uid == _trackedUid && groupDocId == _trackedGroup && anonymous == _trackedAnonymous) return;
    _trackedUid = uid;
    _trackedGroup = groupDocId;
    _trackedAnonymous = anonymous;
    _statusSub?.cancel();
    _statusSub = null;
    if (uid == null || groupDocId == null || groupDocId.isEmpty) {
      _current.value = null;
      return;
    }
    _current.value = GuestStatus.unknown(groupDocId);
    _statusSub = watch(uid, groupDocId, isAnonymous: user!.isAnonymous).listen((status) {
      _current.value = status;
    });
  }

  /// [uid]'s status in [groupDocId] as it changes: [GuestStatus.unknown]
  /// first, then [GuestStatus.derive] of the access index and the
  /// membership doc once both have arrived. A read that fails counts as a
  /// missing doc (a non-member can't read a membership that isn't theirs).
  /// [firestore] overrides the instance (tests).
  static Stream<GuestStatus> watch(
    String uid,
    String groupDocId, {
    bool isAnonymous = false,
    FirebaseFirestore? firestore,
  }) {
    if (isAnonymous) {
      return Stream.value(GuestStatus.derive(groupDocId: groupDocId, isAnonymous: true));
    }
    late final StreamController<GuestStatus> controller;
    StreamSubscription<Object?>? indexSub;
    StreamSubscription<Object?>? membershipSub;
    var indexLoaded = false;
    var membershipLoaded = false;
    Map<String, dynamic>? index;
    Map<String, dynamic>? membership;
    GuestStatus? last;

    void emit() {
      final next = indexLoaded && membershipLoaded
          ? GuestStatus.derive(groupDocId: groupDocId, accessIndex: index, membership: membership)
          : GuestStatus.unknown(groupDocId);
      if (next == last) return;
      last = next;
      controller.add(next);
    }

    controller = StreamController<GuestStatus>(
      onListen: () {
        emit();
        indexSub = AccessIndex.watchData(uid, appId: platformAppId, firestore: firestore).listen(
          (data) {
            index = data;
            indexLoaded = true;
            emit();
          },
          onError: (Object _) {
            index = null;
            indexLoaded = true;
            emit();
          },
        );
        membershipSub = MembershipDocs.snapshots(groupDocId, uid, appId: platformAppId, firestore: firestore).listen(
          (snap) {
            membership = snap.data();
            membershipLoaded = true;
            emit();
          },
          onError: (Object _) {
            membership = null;
            membershipLoaded = true;
            emit();
          },
        );
      },
      onCancel: () async {
        await indexSub?.cancel();
        await membershipSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// Sets [current] directly and stops following auth and the active group
  /// (tests). Pass null to clear.
  @visibleForTesting
  void debugSetCurrent(GuestStatus? status) {
    _started = true;
    _statusSub?.cancel();
    _statusSub = null;
    _authSub?.cancel();
    _authSub = null;
    ActiveGroupService.instance.removeListener(_retrack);
    _trackedUid = null;
    _trackedGroup = null;
    _trackedAnonymous = null;
    _current.value = status;
  }
}
