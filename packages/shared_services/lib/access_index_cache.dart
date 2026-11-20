import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'access_index.dart';
import 'bluejay_firestore.dart';

/// One snapshot of `users/{uid}/metadata/access_index`.
typedef AccessIndexSnapshot = DocumentSnapshot<Map<String, dynamic>>;

/// The app-wide cache behind [AccessIndex]: one live Firestore listener on
/// the signed-in user's access index, shared by every screen, service and
/// gate that reads it. Without it each `AccessIndex.get` was a fresh read and
/// each `AccessIndex.snapshots` a fresh listener (many created inside
/// `build()`, so a rebuild re-subscribed and flashed a waiting state).
///
/// The listener starts on first use and lives for the signed-in session: it
/// is dropped when FirebaseAuth reports a different user or a sign-out, and
/// a request for any uid other than the signed-in user's bypasses the cache
/// (the rules only let the owner read it, so that read fails the same way it
/// always did). Because the server updates the doc whenever it rebuilds the
/// index (a role grant, a group join, an accepted invitation), the listener
/// picks those changes up on its own; code that must see a rebuild it just
/// triggered can still read [AccessIndex.ref] directly.
///
/// Usage Meter attribution: the doc is the same whichever app asks, and one
/// listener serves all of them, so its reads are attributed to
/// [platformAppId] (shared platform services), the same as
/// [UserAppEntitlements.load]'s default. The listener is billed like any
/// other: the first server snapshot is one read and each later change one
/// more, so the per-app `appId` callers pass now only attributes the
/// uncached reads described above.
///
/// Most code uses this through [AccessIndex] / [UserAppEntitlements] and
/// never touches it directly.
class AccessIndexCache {
  AccessIndexCache._();

  static AccessIndexListener? _active;
  static StreamSubscription<String?>? _authSub;

  static bool _testMode = false;
  static FirebaseFirestore? _testFirestore;
  static String? Function()? _testSignedInUid;

  /// How long [AccessIndexListener.get] waits for a server-confirmed value
  /// before settling for the cached one (offline).
  static Duration serverWait = const Duration(seconds: 10);

  /// The shared listener for [uid], or null when [uid] is empty or isn't the
  /// signed-in user (callers then read Firestore directly).
  static AccessIndexListener? forUid(String uid) {
    if (uid.isEmpty) return null;
    final signedIn = _signedInUid();
    // Outside tests the signed-in uid must be known and match.
    if (signedIn != uid && !(_testMode && signedIn == null)) return null;
    final active = _active;
    if (active != null && active.uid == uid) return active;
    active?._dispose();
    _watchAuth();
    return _active = AccessIndexListener._(
      uid,
      AccessIndex.ref(uid, appId: platformAppId, firestore: _testFirestore),
    );
  }

  static String? _signedInUid() {
    if (_testMode) return _testSignedInUid?.call();
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // Firebase isn't initialized (a test that didn't call debugReset).
      return null;
    }
  }

  /// Drops the listener once a different user (or nobody) is signed in.
  /// One subscription for the app's lifetime, made on first use.
  static void _watchAuth() {
    if (_authSub != null || _testMode) return;
    try {
      _authSub = FirebaseAuth.instance.authStateChanges().map((user) => user?.uid).listen(_onAuthUid);
    } catch (_) {
      // Firebase isn't initialized; nothing to follow.
    }
  }

  static void _onAuthUid(String? uid) {
    final active = _active;
    if (active == null || active.uid == uid) return;
    active._dispose();
    _active = null;
  }

  /// Disposes the listener and puts the cache in test mode: reads go to
  /// [firestore], [signedInUid] stands in for FirebaseAuth's current user
  /// (null accepts any uid), and [authUidChanges] for its auth state stream.
  /// Call it in `setUp`, and with no arguments in `tearDown`.
  @visibleForTesting
  static void debugReset({
    FirebaseFirestore? firestore,
    String? Function()? signedInUid,
    Stream<String?>? authUidChanges,
    Duration serverWait = const Duration(seconds: 10),
  }) {
    _active?._dispose();
    _active = null;
    _authSub?.cancel();
    _authSub = authUidChanges?.listen(_onAuthUid);
    _testMode = true;
    _testFirestore = firestore;
    _testSignedInUid = signedInUid;
    AccessIndexCache.serverWait = serverWait;
    debugListensOpened = 0;
  }

  /// How many Firestore listeners the cache has opened since the last
  /// [debugReset] (tests).
  @visibleForTesting
  static int debugListensOpened = 0;

  /// The listener currently held, if any (tests).
  @visibleForTesting
  static AccessIndexListener? get debugActive => _active;
}

/// The shared listener on one user's access index (see [AccessIndexCache]).
class AccessIndexListener {
  AccessIndexListener._(this.uid, this._ref);

  final String uid;
  final DocumentReference<Map<String, dynamic>> _ref;

  StreamSubscription<AccessIndexSnapshot>? _sub;
  AccessIndexSnapshot? _latest;
  bool _serverConfirmed = false;
  Object? _error;
  StackTrace? _errorStack;
  Timer? _retry;
  int _failures = 0;
  bool _disposed = false;
  final StreamController<AccessIndexSnapshot> _changes = StreamController.broadcast();
  final List<Completer<AccessIndexSnapshot>> _serverWaiters = [];

  static const _equality = DeepCollectionEquality();

  /// Whether the Firestore listener is open (tests).
  @visibleForTesting
  bool get isListening => _sub != null;

  /// The latest snapshot: what [snapshots] hands a new subscriber first.
  /// Null before the first one arrives, and while the listener is in an
  /// error state (a new subscriber then gets the error instead).
  AccessIndexSnapshot? get current => _error == null ? _latest : null;

  /// The access index as it changes. Every call site gets this same
  /// instance, so a StreamBuilder that reads it in `build()` keeps its
  /// subscription across rebuilds. Each new subscriber is first handed the
  /// latest snapshot (or the listener's error), then every change.
  late final Stream<AccessIndexSnapshot> snapshots = _ReplayStream(this);

  /// [snapshots] mapped to the doc's data (null while it doesn't exist).
  late final Stream<Map<String, dynamic>?> data = snapshots.map((snap) => snap.data());

  /// The latest server-confirmed snapshot: immediate once one has arrived,
  /// otherwise the first one. A cached snapshot alone (from an earlier
  /// session) isn't enough, matching a plain `get()`; offline, the cached
  /// value is used after [AccessIndexCache.serverWait]. While the listener
  /// is in an error state this is a direct read, so errors surface exactly
  /// as they did before.
  Future<AccessIndexSnapshot> get() {
    _ensureStarted();
    final latest = _latest;
    if (_error != null || _disposed) return _ref.get();
    if (latest != null && _serverConfirmed) return Future.value(latest);
    final waiter = Completer<AccessIndexSnapshot>();
    _serverWaiters.add(waiter);
    return waiter.future.timeout(AccessIndexCache.serverWait, onTimeout: () {
      _serverWaiters.remove(waiter);
      final cached = _latest;
      return cached != null ? Future.value(cached) : _ref.get();
    });
  }

  void _ensureStarted() {
    if (_disposed || _sub != null || _retry != null) return;
    AccessIndexCache.debugListensOpened++;
    _sub = _ref.snapshots(includeMetadataChanges: true).listen(_onSnapshot, onError: _onError);
  }

  void _onSnapshot(AccessIndexSnapshot snap) {
    final previous = _latest;
    final recovered = _error != null;
    final changed = previous == null ||
        recovered ||
        previous.exists != snap.exists ||
        !_equality.equals(previous.data(), snap.data());
    _latest = snap;
    _error = null;
    _errorStack = null;
    _failures = 0;
    if (!snap.metadata.isFromCache) {
      _serverConfirmed = true;
      _completeWaiters(() => Future.value(snap));
    }
    // A cache→server flip with identical data isn't news to subscribers.
    if (changed) _changes.add(snap);
  }

  void _onError(Object error, StackTrace stack) {
    _error = error;
    _errorStack = stack;
    _sub?.cancel();
    _sub = null;
    _completeWaiters(_ref.get);
    _changes.addError(error, stack);
    // Firestore ends a listener after an error. Reopen it with backoff while
    // someone is subscribed; otherwise the next read reopens it.
    final delay = Duration(seconds: math.min(60, 1 << math.min(_failures, 6)));
    _failures++;
    _retry = Timer(delay, () {
      _retry = null;
      if (_changes.hasListener) _ensureStarted();
    });
  }

  void _completeWaiters(Future<AccessIndexSnapshot> Function() value) {
    if (_serverWaiters.isEmpty) return;
    final waiters = List.of(_serverWaiters);
    _serverWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete(value());
    }
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _retry?.cancel();
    _retry = null;
    _completeWaiters(_ref.get);
    _changes.close();
  }
}

/// [AccessIndexListener.snapshots]: a broadcast stream that replays the
/// latest snapshot (or error) to each new subscriber.
class _ReplayStream extends Stream<AccessIndexSnapshot> {
  _ReplayStream(this._owner);

  final AccessIndexListener _owner;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<AccessIndexSnapshot> listen(
    void Function(AccessIndexSnapshot event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final owner = _owner;
    StreamSubscription<AccessIndexSnapshot>? upstream;
    late final StreamController<AccessIndexSnapshot> controller;
    controller = StreamController<AccessIndexSnapshot>(
      onListen: () {
        owner._ensureStarted();
        final error = owner._error;
        final latest = owner._latest;
        if (error != null) {
          controller.addError(error, owner._errorStack);
        } else if (latest != null) {
          controller.add(latest);
        }
        upstream = owner._changes.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () => upstream?.cancel(),
    );
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
