/// Screenshot capture mode: the app store screenshot pipeline
/// (scripts/app_screenshots/capture.js, demo/README.md) opens the web app
/// with `?capture=1`, and for a demo account (`users/{uid}.isDemo`, see
/// demo.dart) the app then hides transient chrome that isn't part of the
/// screen being shown: the in-app "Request a change" tab, the update
/// banner and foreground message snackbars.
///
/// Real accounts never get it: the flag is ignored unless the signed-in
/// user's doc marks them as a demo account. While that check is still
/// running, chrome stays hidden, so a capture can't catch it mid-way; a
/// real user who adds the parameter sees it come back once the check fails.
///
/// The pipeline waits for [markerLabel] in the semantics tree before each
/// shot, so a capture never runs with the chrome still showing.
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/widgets.dart';

import 'bluejay_firestore.dart';
import 'demo.dart';

class CaptureMode {
  CaptureMode._();

  /// A separate instance, for tests.
  @visibleForTesting
  factory CaptureMode.forTesting() => CaptureMode._();

  static final CaptureMode instance = CaptureMode._();

  /// The launch query parameter (`?capture=1`) that asks for capture mode.
  static const String queryParameter = 'capture';

  /// The semantics label present while capture mode is on.
  static const String markerLabel = 'Screenshot capture mode';

  /// Whether [launchUri] asks for capture mode.
  static bool isRequested(Uri launchUri) =>
      launchUri.queryParameters[queryParameter] == '1';

  /// [queryParameters] without the capture flag, for code that hands a
  /// URL's query to an app as its launch args.
  static Map<String, String> withoutFlag(Map<String, String> queryParameters) =>
      Map.of(queryParameters)..remove(queryParameter);

  /// Whether transient chrome should be hidden right now: capture mode was
  /// requested and the user is a demo account, or that check is pending.
  final ValueNotifier<bool> hidesChrome = ValueNotifier<bool>(false);

  /// True once the signed-in user is confirmed to be a demo account.
  final ValueNotifier<bool> confirmed = ValueNotifier<bool>(false);

  /// How long to wait for the server's copy of the users doc before giving
  /// up: the chrome comes back rather than staying hidden on a slow or
  /// offline connection.
  static const Duration defaultCheckTimeout = Duration(seconds: 10);

  int _generation = 0;
  StreamSubscription<bool>? _userDoc;
  Timer? _checkTimer;
  Duration _checkTimeout = defaultCheckTimeout;
  Stream<bool> Function(String uid) _demoAccountChanges = _isDemoChanges;

  /// Reads the launch URL and, when capture mode is asked for, checks each
  /// signed-in user. Call once at startup, after Firebase is initialized.
  /// [authChanges] and [demoAccountChanges] stand in for Firebase in tests.
  void init(
    Uri launchUri, {
    Stream<fire_auth.User?>? authChanges,
    Stream<bool> Function(String uid)? demoAccountChanges,
    Duration? checkTimeout,
  }) {
    final requested = isRequested(launchUri);
    hidesChrome.value = requested;
    if (!requested) return;
    if (demoAccountChanges != null) _demoAccountChanges = demoAccountChanges;
    if (checkTimeout != null) _checkTimeout = checkTimeout;
    (authChanges ?? fire_auth.FirebaseAuth.instance.authStateChanges())
        .listen(_resolveFor);
  }

  /// Whether users/{uid} marks a demo account, from the server's copy of the
  /// doc. Snapshots from the cache or with pending local writes are skipped:
  /// right after startup the launcher's lastActive write (a merge) leaves a
  /// local copy holding only that field, which reads as "not a demo
  /// account".
  static Stream<bool> _isDemoChanges(String uid) {
    return BluejayFirestore.forApp(launcherAppId)
        .collection('users')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .where((snap) =>
            !snap.metadata.isFromCache && !snap.metadata.hasPendingWrites)
        .map((snap) {
      final data = snap.data();
      if (!isDemoUser(data)) {
        debugPrint('[CaptureMode] users/$uid from the server has no '
            '$demoField: true (exists=${snap.exists}, '
            'pendingWrites=${snap.metadata.hasPendingWrites}, '
            'fields=${data?.keys.toList()})');
      }
      return isDemoUser(data);
    });
  }

  void _resolveFor(fire_auth.User? user) {
    final generation = ++_generation;
    _userDoc?.cancel();
    _userDoc = null;
    _checkTimer?.cancel();
    _checkTimer = null;
    if (user == null || user.isAnonymous) {
      // Signed out there is no chrome to hide yet, so stay hidden until the
      // next user is checked. An anonymous session is never a demo account
      // (demo accounts sign in with a password), so this tests how the user
      // signed in, which is why it reads isAnonymous rather than GuestStatus.
      _set(generation, hide: user == null, isDemo: false);
      return;
    }
    hidesChrome.value = true;
    confirmed.value = false;
    _checkTimer = Timer(_checkTimeout, () {
      debugPrint('[CaptureMode] off: no server copy of the users doc after '
          '${_checkTimeout.inSeconds}s');
      _set(generation, hide: false, isDemo: false);
    });
    _userDoc = _demoAccountChanges(user.uid).distinct().listen(
      (isDemo) {
        if (generation == _generation) _checkTimer?.cancel();
        debugPrint(isDemo
            ? '[CaptureMode] on: demo account confirmed'
            : '[CaptureMode] off: not a demo account');
        _set(generation, hide: isDemo, isDemo: isDemo);
      },
      onError: (Object e) {
        if (generation == _generation) _checkTimer?.cancel();
        debugPrint('[CaptureMode] demo account check failed: $e');
        _set(generation, hide: false, isDemo: false);
      },
    );
  }

  void _set(int generation, {required bool hide, required bool isDemo}) {
    if (generation != _generation) return;
    hidesChrome.value = hide;
    confirmed.value = isDemo;
  }
}

/// Builds [child], plus an invisible [CaptureMode.markerLabel] semantics
/// node while capture mode is confirmed. Wraps the whole app
/// (MaterialApp.builder), so the marker is there on every screen.
class CaptureModeMarker extends StatelessWidget {
  const CaptureModeMarker({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The Stack is always there, so turning the marker on never remounts
    // the app (and its Navigator) below it.
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        child,
        ValueListenableBuilder<bool>(
          valueListenable: CaptureMode.instance.confirmed,
          builder: (context, on, _) => on
              ? Positioned(
                  left: 0,
                  top: 0,
                  width: 1,
                  height: 1,
                  child: Semantics(
                    label: CaptureMode.markerLabel,
                    container: true,
                    child: const SizedBox.expand(),
                  ),
                )
              : const Positioned(
                  left: 0,
                  top: 0,
                  width: 0,
                  height: 0,
                  child: SizedBox.shrink(),
                ),
        ),
      ],
    );
  }
}
