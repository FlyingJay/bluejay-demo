import 'dart:async';

import 'access_index.dart';
import 'access_index_cache.dart';
import 'bluejay_firestore.dart';

export 'access_index_builder.dart' show PrimedStreamBuilder, UserAppEntitlementsBuilder;

/// A user's platform roles and per-`{groupId}:{appId}` entitlements, read
/// from `users/{uid}/metadata/access_index` through [AccessIndex] (which also
/// serves code that needs the raw snapshot).
///
/// This is the generalized form of the `AppAccessPermissions` pattern that
/// every `<app>_access.dart` file in this repo implements for its own
/// hardcoded app ID (see `packages/corporate_access/lib/app_access_access.dart`).
/// `computeEntitlements` (functions/_shared.js) only adds a `{groupId}:{appId}`
/// entry when the user both belongs to a group with that app installed *and*
/// isn't excluded by an `app_access` user segment — so a bare
/// `entitlements.contains('$groupId:$appId')` check already folds in both
/// group access and segment restrictions, with no extra Firestore read.
class UserAppEntitlements {
  final Set<String> roles;
  final Set<String> entitlements;

  /// Access index `status` — `'ACTIVE'` unless the account is suspended.
  final String status;

  /// Group IDs frozen out for this user (the rules' inTenant() kill switch).
  final Set<String> deniedScopes;

  const UserAppEntitlements({
    this.roles = const {},
    this.entitlements = const {},
    this.status = 'ACTIVE',
    this.deniedScopes = const {},
  });

  /// No roles or entitlements — what an unreadable access index yields.
  static const none = UserAppEntitlements(status: 'INACTIVE');

  /// Reads [uid]'s current access index through [AccessIndex] (the shared
  /// listener for the signed-in user, so usually no Firestore read at all).
  /// Fails closed: a missing uid or a failed read yields [none]. [appId] is
  /// the app an uncached read is attributed to (default: the platform).
  static Future<UserAppEntitlements> load(String uid, {String appId = platformAppId}) async {
    if (uid.isEmpty) return none;
    try {
      final snap = await AccessIndex.get(uid, appId: appId);
      return UserAppEntitlements.fromAccessIndexData(snap.data());
    } catch (_) {
      return none;
    }
  }

  /// The signed-in user's entitlements as of the shared listener's latest
  /// snapshot, or null before it has one (or for any other uid).
  static UserAppEntitlements? current(String uid) {
    final snap = AccessIndex.current(uid);
    return snap == null ? null : UserAppEntitlements.fromAccessIndexData(snap.data());
  }

  static final Expando<Stream<UserAppEntitlements>> _watched = Expando('UserAppEntitlements.watch');

  /// [uid]'s access index as it changes, e.g. while a role grant propagates.
  /// Emits [none] for a missing uid or when the stream errors. For the
  /// signed-in user every call returns the same stream instance, backed by
  /// the shared listener, so it is safe to call from `build()`. [appId] is
  /// the app an uncached read is attributed to (default: the platform).
  static Stream<UserAppEntitlements> watch(String uid, {String appId = platformAppId}) {
    if (uid.isEmpty) return Stream.value(none);
    final shared = AccessIndexCache.forUid(uid);
    if (shared == null) return _entitlementsOf(AccessIndex.snapshots(uid, appId: appId));
    return _watched[shared] ??= _entitlementsOf(shared.snapshots);
  }

  static Stream<UserAppEntitlements> _entitlementsOf(Stream<AccessIndexSnapshot> snapshots) => snapshots
      .map((snap) => UserAppEntitlements.fromAccessIndexData(snap.data()))
      .transform(StreamTransformer<UserAppEntitlements, UserAppEntitlements>.fromHandlers(
        handleError: (_, __, sink) => sink.add(none),
      ));

  factory UserAppEntitlements.fromAccessIndexData(Map<String, dynamic>? data) {
    Set<String> readStringSet(Object? raw) {
      if (raw is! List) return const {};
      return raw.whereType<String>().toSet();
    }

    return UserAppEntitlements(
      roles: readStringSet(data?['roles']),
      entitlements: readStringSet(data?['entitlements']),
      status: (data?['status'] as String? ?? 'INACTIVE').toUpperCase(),
      deniedScopes: readStringSet(data?['denied_scopes']),
    );
  }

  /// Whether this user holds at least [tier] for `{groupId}:{appId}` — the
  /// same check the tenant rule and `hasAppEntitlement` in
  /// functions/_shared.js make, including the status and denied_scopes kill
  /// switches. Unlike [canAccessApp], the platform `admin` role passes it
  /// (the rules let admins read every group, EX-ADMIN-1, but write only
  /// `adminWritable` collections); `developer` gets no app-data access. Use
  /// it to decide what UI to show; the rules remain the real enforcement.
  bool hasAppTier(String groupId, String appId, [EntitlementTier tier = EntitlementTier.read]) {
    if (groupId.isEmpty || appId.isEmpty) return false;
    if (roles.contains('admin')) return true;
    if (status != 'ACTIVE' || deniedScopes.contains(groupId)) return false;
    final scope = '$groupId:$appId';
    return switch (tier) {
      EntitlementTier.read => entitlements.contains(scope) ||
          entitlements.contains('$scope:edit') ||
          entitlements.contains('$scope:admin'),
      EntitlementTier.edit =>
        entitlements.contains('$scope:edit') || entitlements.contains('$scope:admin'),
      EntitlementTier.admin => entitlements.contains('$scope:admin'),
    };
  }

  bool get isPlatformAdmin =>
      roles.contains('admin') || roles.contains('developer');

  /// Whether this user holds the rules' platform-admin read grant
  /// (EX-ADMIN-1): an ACTIVE account with the platform `admin` role (not
  /// `developer`, which reads only `developerRead` collections). The one
  /// check for UI that reads every group's data, e.g. Improve Apps' "All
  /// groups" scope.
  bool get isActivePlatformAdmin =>
      status.trim().toUpperCase() == 'ACTIVE' && roles.contains('admin');

  /// Whether this user can access [appId] within [groupId].
  bool canAccessApp(String groupId, String appId) {
    if (isPlatformAdmin) return true;
    return entitlements.contains('$groupId:$appId');
  }

  /// Filters [appIds] down to the ones this user can access in [groupId],
  /// preserving the input order.
  List<String> filterAccessibleAppIds(String groupId, Iterable<String> appIds) {
    return appIds.where((id) => canAccessApp(groupId, id)).toList();
  }
}

/// Entitlement tiers computed by `computeEntitlements` (functions/_shared.js):
/// bare scope (read/create), `:edit`, and `:admin`.
enum EntitlementTier { read, edit, admin }
