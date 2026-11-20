import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

/// Signature matching `lib/routing/app_router.dart`'s `AppRouter.getScreen`.
///
/// Leaf packages (like `packages/wiki` or `packages/blue_ji`) can't import
/// `AppRouter` directly — the root `bluejay` app package already depends on
/// every leaf package, so the reverse dependency would be a cycle. This
/// typedef lets a leaf package describe "a function that opens an app by
/// appId" without depending on the concrete router.
///
/// [args] is a generic string-keyed bag for apps that need more than just
/// `(appId, user)` to land on the right sub-view — e.g. Wiki reads an
/// `'slug'` entry to open a specific article instead of its landing page.
/// Each target app interprets its own keys; a leaf package that doesn't
/// recognize an app ignores [args] entirely.
typedef AppScreenResolver = Widget? Function(
  String appId,
  fire_auth.User? user, {
  bool isDeepLink,
  Map<String, String>? args,
});

/// Static hook wired once by the root app at startup (`lib/main.dart`) to
/// `AppRouter.getScreen`. Leaf packages call [openApp] to open another
/// installed app without a compile-time dependency on the router.
class AppLaunchBridge {
  AppLaunchBridge._();

  static AppScreenResolver? resolveScreen;

  /// Pushes the screen for [appId] onto the navigator, if one can be
  /// resolved. Returns `true` if navigation happened, `false` if the bridge
  /// hasn't been wired yet or no screen could be resolved for [appId].
  ///
  /// Pass [args] to target a specific sub-view within [appId] (see
  /// [AppScreenResolver] for the key convention).
  static bool openApp(
    BuildContext context,
    String appId,
    fire_auth.User? user, {
    Map<String, String>? args,
  }) {
    final screen = resolveScreen?.call(appId, user, args: args);
    if (screen == null) return false;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    return true;
  }
}
