import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/app_launch_bridge.dart';

/// Opening the Automations app from another app. Reads nothing: whether
/// the group has the app installed comes from the caller (an
/// `automationsList` result's `installed`), and the Automations app itself
/// explains when it isn't. Kept free of Firestore so Group Admin can link
/// to the app and still write only through callables (SECURITY_TIERS.md).

/// The Automations app's id (packages/automations/lib/constants.dart).
const automationsAppId = 'automations';

/// The Add Apps app's id, where a group installs Automations.
const addAppsAppId = 'add-apps';

/// Launch args the Automations app reads (lib/routing/app_router.dart).
abstract final class AutomationsArgs {
  /// Opens the Rules tab filtered to one app.
  static const app = 'app';

  /// '1' opens a new automation in the editor (for [app] when given).
  static const create = 'new';
}

/// Opens another app by id; returns whether it opened. Tests pass their own.
typedef AutomationsAppOpener = bool Function(BuildContext context, String appId, Map<String, String>? args);

/// Opens Add Apps, or says how to get there when it can't be opened.
Future<void> offerAddAutomations(BuildContext context, {fire_auth.User? user, AutomationsAppOpener? open}) async {
  final add = await showBjConfirm(
    context,
    title: 'Automations isn\'t installed',
    message: 'Add the Automations app to this group from Add Apps to set up and review automations. '
        'Built-in automations keep running without it.',
    confirmLabel: 'Open Add Apps',
    icon: Icons.bolt_rounded,
  );
  if (!add || !context.mounted) return;
  final opener = open ?? _launcher(user);
  if (!opener(context, addAppsAppId, null)) {
    BjSnack.info(context, 'Open Add Apps from the launcher to install Automations.');
  }
}

/// Opens the Automations app, on [appFilter]'s rules and with a new
/// automation open when [create] is set. When [installed] is false, offers
/// Add Apps instead; null means unknown, and the app explains if needed.
Future<void> openAutomationsApp(
  BuildContext context, {
  fire_auth.User? user,
  String? appFilter,
  bool create = false,
  bool? installed,
  AutomationsAppOpener? open,
}) async {
  if (installed == false) return offerAddAutomations(context, user: user, open: open);
  final args = <String, String>{
    if (appFilter != null && appFilter.isNotEmpty) AutomationsArgs.app: appFilter,
    if (create) AutomationsArgs.create: '1',
  };
  final opener = open ?? _launcher(user);
  if (!opener(context, automationsAppId, args.isEmpty ? null : args)) {
    BjSnack.info(context, 'Open Automations from the launcher.');
  }
}

AutomationsAppOpener _launcher(fire_auth.User? user) =>
    (context, appId, args) => AppLaunchBridge.openApp(context, appId, user ?? _signedInUser(), args: args);

fire_auth.User? _signedInUser() {
  try {
    return fire_auth.FirebaseAuth.instance.currentUser;
  } catch (_) {
    return null;
  }
}
