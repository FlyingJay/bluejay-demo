/// Links that open an app inside a specific group: `/{groupId}/{appId}`,
/// optionally with query parameters the target app reads as launch args.
///
/// On web, opening such a URL makes `groupId` the active group and then
/// launches `appId` (see `_groupSlugFromUrl`/`_appSlugFromUrl` in
/// lib/main.dart and `_tryDeepLinkNavigation` in the launcher). The
/// launcher forwards the URL's query parameters to `AppRouter.getScreen` as
/// `args`, so any app that already understands `args` (see
/// `AppScreenResolver` in app_launch_bridge.dart) can be deep-linked to a
/// sub-view by URL too.
library;

import 'cloud_functions.dart' show kPublicHost;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Where the web app is served when there's no browser URL to borrow the
/// origin from (native builds, tests).
const String defaultWebOrigin = 'https://$kPublicHost';

/// `{origin}/{groupId}/{appId}?{args}`, or null when either id is blank.
///
/// [origin] defaults to the page's own origin on web (so preview channels
/// and localhost link to themselves) and to [defaultWebOrigin] elsewhere.
Uri? groupAppUri(
  String groupId,
  String appId, {
  Map<String, String> args = const {},
  Uri? origin,
}) {
  final group = groupId.trim();
  final app = appId.trim();
  if (group.isEmpty || app.isEmpty) return null;
  final base = origin ?? _currentOrigin();
  final query = {
    for (final entry in args.entries)
      if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
  };
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: [group, app],
    queryParameters: query.isEmpty ? null : query,
  );
}

Uri _currentOrigin() {
  if (kIsWeb && (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
    return Uri.base;
  }
  return Uri.parse(defaultWebOrigin);
}

/// Launch-arg keys Improve Apps (`improve-apps`) reads to open on one
/// ticket: [improveAppsItemTypeArg] is `bug` or `feature`.
const String improveAppsItemIdArg = 'itemId';
const String improveAppsItemTypeArg = 'itemType';

/// Improve Apps in [groupId], opened on the given bug/idea.
Uri? improveAppsTicketUri(
  String groupId, {
  required String itemType,
  required String itemId,
  Uri? origin,
}) =>
    groupAppUri(
      groupId,
      'improve-apps',
      args: {improveAppsItemTypeArg: itemType, improveAppsItemIdArg: itemId},
      origin: origin,
    );

/// Launch-arg key App Maker (`app-maker`) reads to open on one app request.
const String appMakerRequestIdArg = 'requestId';

/// App Maker in [groupId], opened on app request [requestId].
Uri? appMakerRequestUri(
  String groupId, {
  required String requestId,
  Uri? origin,
}) =>
    groupAppUri(
      groupId,
      'app-maker',
      args: {appMakerRequestIdArg: requestId},
      origin: origin,
    );

/// The path segment of a notification link:
/// `/{groupId}/notifications?id={notificationId}`, or
/// `/notifications?id={notificationId}` for one with no group. Every SMS,
/// email and web push notification links here unless its sender chose a
/// link or marked it informational (functions/_notification_links.js); the
/// launcher opens it the way a tap in the notifications screen would
/// (lib/notifications/notification_link.dart).
const String notificationsPathSegment = 'notifications';

/// Query parameter holding the notification id in a notification link.
const String notificationIdParam = 'id';

/// A parsed notification link (see [notificationsPathSegment]).
class NotificationLink {
  const NotificationLink({this.groupId, this.notificationId});

  /// The group from the URL path, or null for `/notifications`.
  final String? groupId;

  /// The notification to open, or null to just show the notifications screen.
  final String? notificationId;

  /// The link [uri] holds, or null when it isn't a notification link.
  static NotificationLink? fromUri(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final String? groupId;
    if (segments.length == 1 && segments.first == notificationsPathSegment) {
      groupId = null;
    } else if (segments.length == 2 && segments[1] == notificationsPathSegment) {
      groupId = segments.first.trim();
    } else {
      return null;
    }
    final id = uri.queryParameters[notificationIdParam]?.trim() ?? '';
    return NotificationLink(
      groupId: groupId == null || groupId.isEmpty ? null : groupId,
      notificationId: id.isEmpty ? null : id,
    );
  }
}
