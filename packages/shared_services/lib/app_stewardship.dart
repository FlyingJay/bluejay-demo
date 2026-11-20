import 'dart:async';

/// Client-side helpers for app stewardship: a group listed in an app's
/// `apps/{appId}.stewardGroupIds` manages that app for every group using it,
/// and its members get an `app:<appId>:steward` entitlement in
/// `users/{uid}/metadata/access_index` (computeEntitlements in
/// functions/_shared.js). The rules' EX-STEWARD-1 grant checks that
/// entitlement against a doc's `relatedAppId` — not its groupId — granting
/// read and comment (never edit/delete) on change requests about the app, in
/// any group (collections declared `stewardRead` in security/collections.json).

final RegExp _stewardEntitlementPattern = RegExp(r'^app:(.+):steward$');

/// The app ids an access index's `entitlements` say the user stewards — the
/// Dart twin of `stewardedAppIds` in functions/_shared.js.
Set<String> stewardedAppIdsFromEntitlements(Iterable<Object?>? entitlements) {
  if (entitlements == null) return const {};
  return entitlements
      .whereType<String>()
      .map((value) => _stewardEntitlementPattern.firstMatch(value)?.group(1))
      .whereType<String>()
      .toSet();
}

/// Whether a ticket [data] sits outside [activeGroupId] but is readable via
/// stewardship of its `relatedAppId` — i.e. it shows up only in a "managed
/// apps" view, never in the active group's own list.
bool isStewardedTicketOutsideGroup(
  Map<String, dynamic>? data, {
  required String? activeGroupId,
  required Set<String> stewardedAppIds,
}) {
  if (data == null) return false;
  final relatedAppId = data['relatedAppId'];
  if (relatedAppId is! String || !stewardedAppIds.contains(relatedAppId)) {
    return false;
  }
  return data['groupId'] != activeGroupId;
}

/// The owning group's display name for a ticket shown across groups —
/// `groupName` (stamped server-side on create) or the raw `groupId`.
String stewardedTicketGroupLabel(Map<String, dynamic> data) =>
    _firstNonEmpty(data['groupName'], data['groupId']);

/// The app a ticket is about — `relatedAppName` or the raw `relatedAppId`.
String stewardedTicketAppLabel(Map<String, dynamic> data) =>
    _firstNonEmpty(data['relatedAppName'], data['relatedAppId']);

String _firstNonEmpty(Object? preferred, Object? fallback) {
  if (preferred is String && preferred.trim().isNotEmpty) {
    return preferred.trim();
  }
  if (fallback is String) return fallback.trim();
  return '';
}

/// Merges [sources] into one list with each id kept once (first occurrence
/// wins), optionally sorted by [compare].
List<T> mergeUniqueById<T>(
  Iterable<Iterable<T>> sources, {
  required String Function(T item) idOf,
  Comparator<T>? compare,
}) {
  final seen = <String>{};
  final merged = <T>[];
  for (final source in sources) {
    for (final item in source) {
      if (seen.add(idOf(item))) merged.add(item);
    }
  }
  if (compare != null) merged.sort(compare);
  return merged;
}

/// Combines the latest list from each of [sources] into one de-duplicated
/// list (see [mergeUniqueById]), emitting once every source has emitted and
/// again on each later change. Used to run one equality query per stewarded
/// app — firestore.rules can only prove a steward query per `relatedAppId`
/// value, so a single `whereIn` would be rejected.
///
/// Sources are listened to only while the result is, and cancelled with it.
/// An error from any source is forwarded. No sources emits one empty list.
Stream<List<T>> combineLatestUniqueById<T>(
  List<Stream<List<T>>> sources, {
  required String Function(T item) idOf,
  Comparator<T>? compare,
}) {
  if (sources.isEmpty) return Stream.value(<T>[]);

  final latest = List<List<T>?>.filled(sources.length, null);
  final subscriptions = <StreamSubscription<List<T>>>[];
  late final StreamController<List<T>> controller;

  void emitIfReady() {
    if (latest.any((items) => items == null)) return;
    controller.add(
      mergeUniqueById(latest.cast<List<T>>(), idOf: idOf, compare: compare),
    );
  }

  controller = StreamController<List<T>>(
    onListen: () {
      for (var i = 0; i < sources.length; i++) {
        subscriptions.add(sources[i].listen(
          (items) {
            latest[i] = items;
            emitIfReady();
          },
          onError: controller.addError,
        ));
      }
    },
    onPause: () {
      for (final subscription in subscriptions) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in subscriptions) {
        subscription.resume();
      }
    },
    onCancel: () async {
      final pending = subscriptions.map((s) => s.cancel()).toList();
      subscriptions.clear();
      await Future.wait(pending);
    },
  );
  return controller.stream;
}
