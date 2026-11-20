import 'package:shared_services/user_app_entitlements.dart';

import 'constants.dart';

// Pure decision logic for the in-app "Request a change" entry point (see
// request_change.dart). Kept free of the bug_reports / feature_voting UI
// imports so it can be unit-tested in this package on its own.

/// Whether the in-app "Request a change" entry point should be offered for
/// [appId].
///
/// [allowChangeRequests] is the app's own `apps/{id}.allowChangeRequests`
/// (App Manager's "In-app change requests" toggle; true when unset) — the
/// one place an app opts out, e.g. Improve Apps itself.
///
/// Requires a signed-in, non-guest user ([isSignedInMember]) whose active
/// group ([activeGroupId]) grants them Improve Apps — the same
/// `{groupId}:improve-apps` entitlement the tenant rule checks when
/// the resulting bug_reports / feature_requests doc is written, so the
/// affordance is only shown when the submission would actually succeed.
bool canOfferRequestChange({
  required String appId,
  required bool allowChangeRequests,
  required bool isSignedInMember,
  required String? activeGroupId,
  required UserAppEntitlements entitlements,
}) {
  if (!allowChangeRequests) return false;
  if (!isRequestChangeCandidate(appId: appId, isSignedInMember: isSignedInMember)) {
    return false;
  }
  if (activeGroupId == null || activeGroupId.isEmpty) return false;
  return entitlements.hasAppTier(activeGroupId, improveBluejayAppId);
}

/// The cheap, synchronous half of [canOfferRequestChange]: everything that
/// can be decided without any reads. Lets the shell skip them for guests.
bool isRequestChangeCandidate({
  required String appId,
  required bool isSignedInMember,
}) {
  final id = appId.trim();
  if (id.isEmpty) return false;
  return isSignedInMember;
}

/// A readable name for [appId] when its `apps` doc can't be read, e.g.
/// `'habit-tracker'` → `'Habit Tracker'`.
String fallbackAppDisplayName(String appId) {
  final words = appId
      .trim()
      .split(RegExp(r'[-_\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}');
  final name = words.join(' ');
  return name.isEmpty ? 'this app' : name;
}

/// Confirmation shown after a request filed from inside [appName] is saved.
String requestChangeSuccessMessage(String appName) =>
    "Thanks! Your request for $appName is in — we'll let you know when it's live.";
