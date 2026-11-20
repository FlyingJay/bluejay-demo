import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'active_group_service.dart';
import 'app_launch_bridge.dart';

/// Handles deep-link navigation for notifications belonging to a specific app.
///
/// Implement one [NotificationDeepLinkHandler] per app and register all
/// handlers once at startup via [NotificationRouter.register].
/// [NotificationsScreen] calls [NotificationRouter.dispatch] instead of a
/// monolithic `switch` statement, so adding support for a new app no longer
/// requires editing the `notifications` package.
abstract class NotificationDeepLinkHandler {
  /// Returns `true` when this handler is responsible for [appId].
  bool canHandle(String appId);

  /// Navigates to the appropriate screen for the given [notificationContext].
  ///
  /// [notificationContext] is guaranteed to be non-null (defaults to `{}`).
  void handle(
    BuildContext context,
    Map<String, dynamic> notificationContext,
    fire_auth.User currentUser,
  );
}

/// Registry that dispatches notification deep-links to their registered handler.
///
/// **Setup** — call [register] once at app startup (e.g. in `main()`):
///
/// ```dart
/// NotificationRouter.register([
///   ChatNotificationHandler(),
///   ChessNotificationHandler(),
///   // …
/// ]);
/// ```
///
/// **Dispatch** — call from [NotificationsScreen._handleNotificationTap]:
///
/// ```dart
/// NotificationRouter.dispatch(context, appId, notificationContext, user);
/// ```
class NotificationRouter {
  NotificationRouter._();

  static final List<NotificationDeepLinkHandler> _handlers = [];

  /// Registers one or more deep-link handlers.  Safe to call multiple times;
  /// handlers are appended in registration order.
  static void register(List<NotificationDeepLinkHandler> handlers) {
    _handlers.addAll(handlers);
  }

  /// Dispatches [notificationContext] to the first registered handler whose
  /// [NotificationDeepLinkHandler.canHandle] returns `true` for [appId].
  ///
  /// Returns whether a handler took it: false when [appId] is `null` or no
  /// handler matches.
  static bool dispatch(
    BuildContext context,
    String? appId,
    Map<String, dynamic>? notificationContext,
    fire_auth.User currentUser,
  ) {
    if (appId == null) return false;
    for (final handler in _handlers) {
      if (handler.canHandle(appId)) {
        handler.handle(context, notificationContext ?? {}, currentUser);
        return true;
      }
    }
    return false;
  }

  /// Opens what a notification or To do item is about, the same way from
  /// every entry point (the inbox, the To do tab, an email link):
  ///
  ///  1. switches to [groupId] (a doc id or slug) when it is one of the
  ///     user's groups and isn't active;
  ///  2. hands [notificationContext] to [appId]'s handler ([dispatch]);
  ///  3. with no handler, opens [appId] itself (AppLaunchBridge);
  ///  4. failing that, opens the context's `actionUrl`, if any.
  ///
  /// Returns whether anything opened.
  static bool open(
    BuildContext context, {
    required String? appId,
    required Map<String, dynamic>? notificationContext,
    required fire_auth.User currentUser,
    String? groupId,
  }) {
    if (groupId != null && groupId.isNotEmpty) {
      ActiveGroupService.instance.switchTo(groupId);
    }
    if (dispatch(context, appId, notificationContext, currentUser)) return true;
    if (appId != null &&
        appId.isNotEmpty &&
        AppLaunchBridge.openApp(context, appId, currentUser)) {
      return true;
    }
    final url = Uri.tryParse('${notificationContext?['actionUrl'] ?? ''}');
    if (url != null && (url.scheme == 'https' || url.scheme == 'http')) {
      launchUrl(url, webOnlyWindowName: '_blank');
      return true;
    }
    return false;
  }

  /// Removes every handler, for tests.
  @visibleForTesting
  static void resetForTesting() => _handlers.clear();
}

/// A notification's request to pay one invoice: `context: {action:
/// 'pay_invoice', invoiceId, groupId?}` (sent by the monthly billing
/// auto-charge when it needs the user — a declined card, 3-D Secure, no card
/// on file). The Wallet's handler opens that invoice's checkout.
class PayInvoiceLink {
  const PayInvoiceLink(this.invoiceId, {this.groupId});

  static const String action = 'pay_invoice';

  final String invoiceId;
  final String? groupId;

  /// The link in [notificationContext], or null when it isn't one.
  static PayInvoiceLink? fromContext(Map<String, dynamic>? notificationContext) {
    if (notificationContext == null || notificationContext['action'] != action) return null;
    final id = notificationContext['invoiceId'];
    if (id is! String || id.trim().isEmpty) return null;
    final group = notificationContext['groupId'];
    return PayInvoiceLink(id.trim(), groupId: group is String && group.isNotEmpty ? group : null);
  }
}
