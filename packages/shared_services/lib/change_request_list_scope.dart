import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_stewardship.dart';
import 'scoped_collection.dart';
import 'user_app_entitlements.dart';

/// Which tickets an Improve Apps list (bugs or ideas) shows. Shared by
/// packages/bug_reports and packages/feature_voting so both lists offer the
/// same scopes, gated the same way, from one definition.
enum ChangeRequestListScope {
  /// The active group's own tickets — the default, offered to everyone.
  activeGroup,

  /// Tickets about apps the user's group stewards, from every group using
  /// them (see app_stewardship.dart). Offered to stewards only.
  managedApps,

  /// Every group's tickets. Offered to active platform admins only
  /// ([UserAppEntitlements.isActivePlatformAdmin]) — the platform-admin read
  /// grant (EX-ADMIN-1) is the only one that can read a list spanning every
  /// group, so nobody else could load it anyway.
  allGroups,
}

/// The scopes to offer, in display order. A single scope means there is
/// nothing to switch between, so callers hide the switcher.
List<ChangeRequestListScope> availableChangeRequestScopes({
  required bool hasStewardedApps,
  required bool isPlatformAdmin,
}) {
  return [
    ChangeRequestListScope.activeGroup,
    if (hasStewardedApps) ChangeRequestListScope.managedApps,
    if (isPlatformAdmin) ChangeRequestListScope.allGroups,
  ];
}

/// [selected] if it is still [available] (access can be revoked while the
/// list is open), otherwise the active group.
ChangeRequestListScope effectiveChangeRequestScope(
  ChangeRequestListScope selected,
  List<ChangeRequestListScope> available,
) {
  return available.contains(selected)
      ? selected
      : ChangeRequestListScope.activeGroup;
}

/// The scope a notification deep link to ticket [data] should open in, or
/// null when the active group's list already contains it (or the ticket is
/// unreadable). Prefers "Apps I manage" over "All groups" when both would
/// show it, since that is the narrower list.
ChangeRequestListScope? deepLinkChangeRequestScope(
  Map<String, dynamic>? data, {
  required String? activeGroupId,
  required Set<String> stewardedAppIds,
  required bool isPlatformAdmin,
}) {
  if (data == null || data['groupId'] == activeGroupId) return null;
  if (isStewardedTicketOutsideGroup(
    data,
    activeGroupId: activeGroupId,
    stewardedAppIds: stewardedAppIds,
  )) {
    return ChangeRequestListScope.managedApps;
  }
  return isPlatformAdmin ? ChangeRequestListScope.allGroups : null;
}

/// Whether the list may offer voting / owner edit and delete on ticket
/// [data]: only in the ticket's own group, in every scope. Stewards
/// (EX-STEWARD-1) and platform admins (EX-ADMIN-1, which writes only
/// adminWritable collections) read and comment on another group's ticket
/// but can't change it; status changes go through improveBluejaySetItemStatus
/// either way. [scope] is kept so callers state which list they render.
bool isChangeRequestWritableInScope(
  Map<String, dynamic> data, {
  required ChangeRequestListScope scope,
  required String? activeGroupId,
}) {
  return activeGroupId != null &&
      activeGroupId.isNotEmpty &&
      data['groupId'] == activeGroupId;
}

/// The chip naming where a ticket came from, for scopes that mix groups:
/// "Group · App" ("Group" alone when the ticket names no related app), or
/// null in the active group's own list.
String? changeRequestScopeLabel(
  Map<String, dynamic> data,
  ChangeRequestListScope scope,
) {
  if (scope == ChangeRequestListScope.activeGroup) return null;
  final group = stewardedTicketGroupLabel(data);
  final app = stewardedTicketAppLabel(data);
  if (app.isEmpty) return group;
  if (group.isEmpty) return app;
  return '$group · $app';
}

/// Builds and caches the ticket stream for each [ChangeRequestListScope] of
/// one Improve Apps collection, so rebuilds don't re-run listeners. Merged
/// streams are single-subscription, so call [reset] whenever the scope
/// changes or the list retries.
class ChangeRequestScopeStreams {
  final ScopedCollection collection;

  ChangeRequestScopeStreams(this.collection);

  Stream<List<QueryDocumentSnapshot>>? _stream;
  String _key = '';

  void reset() {
    _stream = null;
    _key = '';
  }

  /// The tickets in [scope]. [stewardedAppIds] is only used by
  /// [ChangeRequestListScope.managedApps].
  Stream<List<QueryDocumentSnapshot>> streamFor(
    ChangeRequestListScope scope, {
    Set<String> stewardedAppIds = const {},
  }) {
    final sortedAppIds = stewardedAppIds.toList()..sort();
    final key = scope == ChangeRequestListScope.managedApps
        ? '${scope.name}:${sortedAppIds.join(',')}'
        : scope.name;
    if (_stream != null && key == _key) return _stream!;
    _key = key;
    return _stream = switch (scope) {
      ChangeRequestListScope.activeGroup =>
        _docs(collection.query.where('appId', isEqualTo: collection.appId)),
      // One equality query per stewarded app (firestore.rules can only prove
      // a steward read per `relatedAppId` value), merged and de-duplicated.
      ChangeRequestListScope.managedApps =>
        combineLatestUniqueById<QueryDocumentSnapshot>(
          [
            for (final appId in sortedAppIds)
              _docs(collection.queryForRelatedApp(appId)),
          ],
          idOf: (doc) => doc.id,
        ),
      ChangeRequestListScope.allGroups =>
        _docs(collection.queryAcrossAllGroups()),
    };
  }

  static Stream<List<QueryDocumentSnapshot>> _docs(
    Query<Map<String, dynamic>> query,
  ) =>
      query
          .snapshots()
          .map<List<QueryDocumentSnapshot>>((snapshot) => snapshot.docs);
}
