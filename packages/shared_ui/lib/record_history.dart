import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/user_app_entitlements.dart';

import 'record_history_view.dart';

export 'record_history_view.dart';

/// Record history: who changed what on a record, from the audit trail.
///
/// The `recordHistory` callable (functions/record_history.js) reads the
/// record's `audit_events` and returns the ones the viewer oversees (a
/// platform admin, or the `:admin` tier of the event's app in its group, or
/// a steward group's admin on a stewardRead collection). This file is the
/// client half: the History menu item, the sheet, and the timeline widget
/// Security Audit's Records tab reuses.

// ─────────────────────────────────────────────────────────────────────────────
// Entry points
// ─────────────────────────────────────────────────────────────────────────────

/// Whether the History entry should show for a record of [collection] in
/// [groupId] (default: the active group): the collection is on the audit
/// trail and the cached access index says the viewer might oversee it. The
/// callable decides per event; this only keeps the item away from people
/// who would always see an empty sheet. [entitlements] is for tests.
bool canSeeRecordHistory(
  ScopedCollection collection, {
  String? groupId,
  UserAppEntitlements? entitlements,
}) {
  if (!collection.isAudited) return false;
  final e = entitlements ?? UserAppEntitlements.current(_signedInUid());
  if (e == null || e.status != 'ACTIVE') return false;
  if (e.isActivePlatformAdmin) return true;
  final group = groupId ?? ActiveGroupService.instance.activeGroupId ?? '';
  final apps = {collection.appId, ...collection.policy.apps};
  if (apps.any((app) => e.hasAppTier(group, app, EntitlementTier.admin))) return true;
  return e.entitlements.any((x) => x.endsWith(':steward'));
}

/// The signed-in uid, or '' when there is none (or no Firebase app at all,
/// as in widget tests), so the History entry fails closed.
String _signedInUid() {
  try {
    return fire_auth.FirebaseAuth.instance.currentUser?.uid ?? '';
  } catch (_) {
    return '';
  }
}

/// The History item for a record's overflow menu ([BjOverflowMenu]), or
/// nothing when [canSeeRecordHistory] says no, so it is safe to spread into
/// any detail screen's menu:
///
/// ```dart
/// BjOverflowMenu(actions: [
///   ..._menu(deal),
///   ...recordHistoryActions(context, collection: _deals, docId: deal.id),
/// ])
/// ```
///
/// [labels] maps field names to what the timeline calls them.
List<BjMenuAction> recordHistoryActions(
  BuildContext context, {
  required ScopedCollection collection,
  required String docId,
  String? groupId,
  Map<String, String> labels = const {},
}) {
  if (docId.isEmpty || !canSeeRecordHistory(collection, groupId: groupId)) return const [];
  return [
    BjMenuAction(
      label: 'History',
      icon: Icons.history_rounded,
      onSelected: () => showRecordHistory(
        context: context,
        collection: collection.isSubcollection ? _subKey(collection.collection) : collection.collection,
        docId: docId,
        parentDocId: collection.isSubcollection ? collection.collection.split('/')[1] : null,
        labels: labels,
      ),
    ),
  ];
}

/// The same entry as an icon button, for screens without an overflow menu.
class RecordHistoryButton extends StatelessWidget {
  const RecordHistoryButton({
    super.key,
    required this.collection,
    required this.docId,
    this.groupId,
    this.labels = const {},
  });

  final ScopedCollection collection;
  final String docId;
  final String? groupId;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    final actions = recordHistoryActions(context,
        collection: collection, docId: docId, groupId: groupId, labels: labels);
    if (actions.isEmpty) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'History',
      icon: const Icon(Icons.history_rounded),
      onPressed: actions.first.onSelected,
    );
  }
}

/// 'bug_reports/b1/comments' → 'bug_reports/comments' (the audit trail's key).
String _subKey(String path) {
  final parts = path.split('/');
  return parts.length == 3 ? '${parts[0]}/${parts[2]}' : path;
}
