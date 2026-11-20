import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/widgets.dart';

/// Opens the "Request a change" chooser from the queue screen.
typedef DevQueueNewRequest = Future<void> Function(BuildContext context);

/// What the launcher shell supplies to the queue. Packages that open the
/// queue screen (the ticket screens' "Open in your queue") cannot depend on
/// `improve_bluejay`, where the request chooser lives, so the shell sets
/// these once at startup and [DevQueueScreen] falls back to them.
class DevQueueHost {
  DevQueueHost._();

  /// Opens the new-request chooser (`showNewRequestSheet` in improve_bluejay).
  static Future<void> Function(BuildContext context, fire_auth.User? user)? newRequest;

  /// Whether [appId] is installed in the active group, for Shipped's
  /// "Open {app name}". Unset reads as installed.
  static bool Function(String appId)? isAppInstalled;

  /// The active group's id. Shipped shows that group's requests and the
  /// changes to its apps; unset (or null) shows every finished item.
  static String? Function()? activeGroupId;
}
