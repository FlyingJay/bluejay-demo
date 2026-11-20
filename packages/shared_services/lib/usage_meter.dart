import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'active_group_service.dart';
import 'firestore_web_cache.dart' show clearFirestoreWebCacheAndReload;
import 'metered_firestore.dart' show FirestoreMeteringContext;
import 'src/document_metering.dart' show FirestoreAttribution;

/// One buffered `usage_daily/{date}_{groupId}_{uid}` doc's worth of counts.
class UsageDayEntry {
  final String date;
  final String groupId;
  final String uid;

  /// appId → metric → amount.
  final Map<String, Map<String, num>> apps = {};

  UsageDayEntry({required this.date, required this.groupId, required this.uid});

  String get docId => '${date}_${groupId}_$uid';

  void add(String appId, String metric, num amount) {
    final metrics = apps.putIfAbsent(appId, () => {});
    metrics[metric] = (metrics[metric] ?? 0) + amount;
  }
}

/// Persists one flushed [UsageDayEntry]. The future completes when the
/// write is acknowledged (or fails); it must not throw synchronously.
typedef UsageEntryWriter = Future<void> Function(UsageDayEntry entry);

/// Client half of Usage Meter (see plans/usage-meter/IMPLEMENTATION_PLAN.md;
/// the server half is functions/_usage.js).
///
/// Apps never call this. Shared choke points do — [UsageSessionScope]
/// (wrapped around every launched app by `AppRouter`) records opens and
/// active time; later phases meter Firestore/Storage/AI through their shared
/// wrappers the same way.
///
/// Counts are buffered in memory and written as ONE increment-only merge per
/// (day, group, user) doc every [flushInterval], when the app is backgrounded,
/// and on group change — never one write per recorded event. Firestore's
/// offline queue persists a flushed write, so routine flushes don't await
/// the server. Signing out must go through [signOutWithUsageFlush], which
/// awaits the final flush while the user's credentials are still valid
/// (usage_daily only accepts a user's own writes).
class UsageMeter with WidgetsBindingObserver {
  /// Matches functions/_usage.js — the appId stamped on usage docs themselves.
  static const usageAppId = 'usage-meter';
  static const collection = 'usage_daily';

  /// Active time stops accruing this long after the last pointer/key input,
  /// so an app left open on an idle screen doesn't count as hours of use.
  static const idleGrace = Duration(minutes: 2);
  static const flushInterval = Duration(minutes: 5);

  static final UsageMeter instance = UsageMeter();

  UsageMeter({DateTime Function()? clock, UsageEntryWriter? writer})
      : _clock = clock ?? DateTime.now,
        _writer = writer ?? _firestoreWriter;

  final DateTime Function() _clock;
  final UsageEntryWriter _writer;

  final Map<String, UsageDayEntry> _pending = {};

  /// `{groupId}/{appId}` ([openKey]) for every app opened since the meter
  /// started, so a listener (the launcher's "New" badges) sees an open
  /// right away instead of after the next flush writes it.
  final ValueNotifier<Set<String>> sessionOpens = ValueNotifier(const {});

  static String openKey(String groupId, String appId) => '$groupId/$appId';
  final List<_Session> _sessions = [];
  int _nextToken = 0;

  String? _uid;
  String? _groupId;
  bool _foreground = true;
  DateTime? _segmentStart;
  DateTime? _lastInteraction;

  bool _started = false;
  Timer? _timer;
  StreamSubscription<User?>? _authSub;

  /// Wires the meter to auth, the active group, app lifecycle, and user
  /// input. Idempotent; call once after Firebase is initialized.
  void start() {
    if (_started) return;
    _started = true;
    setUser(FirebaseAuth.instance.currentUser?.uid);
    setGroup(ActiveGroupService.instance.activeGroupId);
    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) => setUser(u?.uid));
    ActiveGroupService.instance.addListener(_onActiveGroupChanged);
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Tears down what [start] wired up (tests / hot restart).
  void stop() {
    if (!_started) return;
    unawaited(flush());
    _started = false;
    _timer?.cancel();
    _authSub?.cancel();
    ActiveGroupService.instance.removeListener(_onActiveGroupChanged);
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
  }

  void _onActiveGroupChanged() => setGroup(ActiveGroupService.instance.activeGroupId);

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerScrollEvent) {
      markInteraction();
    }
  }

  bool _onKey(KeyEvent event) {
    markInteraction();
    return false;
  }

  // ---------------------------------------------------------------------------
  // Attribution state
  // ---------------------------------------------------------------------------

  /// Signed-in user changed. By now FirebaseAuth already holds the new
  /// user, so anything still buffered for the previous one can no longer be
  /// written (usage_daily only accepts a user's own writes) — it's dropped.
  /// [signOutWithUsageFlush] flushes before signing out, so normally nothing
  /// is left to drop.
  void setUser(String? uid) {
    if (uid == _uid) return;
    _closeSegment();
    final stale = _pending.values.where((e) => e.uid != uid).length;
    if (stale > 0) {
      debugPrint('[UsageMeter] dropping $stale unflushed entries for the previous user');
      _pending.removeWhere((_, e) => e.uid != uid);
    }
    // Another account's opens aren't this one's.
    sessionOpens.value = const {};
    _uid = uid;
    _openSegment();
    _drainDeferred();
  }

  /// Active group changed; same close-out as [setUser].
  void setGroup(String? groupId) {
    if (groupId == _groupId) return;
    _closeSegment();
    _groupId = groupId;
    _openSegment();
    _drainDeferred();
  }

  final List<(String, String, num)> _deferred = [];

  /// [record], or, while no user or group is known yet (e.g. a health
  /// signal raised at startup, before sign-in), as soon as both are.
  void recordWhenAttributed(String appId, String metric, [num amount = 1]) {
    _deferred.add((appId, metric, amount));
    _drainDeferred();
  }

  void _drainDeferred() {
    if (_uid == null || _groupId == null || _deferred.isEmpty) return;
    final due = List.of(_deferred);
    _deferred.clear();
    for (final (appId, metric, amount) in due) {
      record(appId, metric, amount);
    }
  }

  /// User input. Coming back from idle (past the previous input's
  /// [idleGrace]) starts a fresh segment, so the idle gap — which a periodic
  /// flush may have opened a segment across — is never credited.
  void markInteraction() {
    final now = _clock();
    final last = _lastInteraction;
    if (_segmentStart != null && last != null && now.isAfter(last.add(idleGrace))) {
      _closeSegment();
      _lastInteraction = now;
      _openSegment();
      return;
    }
    _lastInteraction = now;
  }

  // ---------------------------------------------------------------------------
  // Recording
  // ---------------------------------------------------------------------------

  /// Adds [amount] of [metric] for [appId] against the current user and
  /// group. Dropped when signed out or no group is active: usage_daily
  /// writes are only permitted for one of the caller's own groups.
  void record(String appId, String metric, [num amount = 1]) {
    final uid = _uid;
    final groupId = _groupId;
    if (uid == null || groupId == null || appId.isEmpty || amount == 0) return;
    final date = utcDateKey(_clock());
    final key = '$date|$groupId|$uid';
    _pending
        .putIfAbsent(key, () => UsageDayEntry(date: date, groupId: groupId, uid: uid))
        .add(appId, metric, amount);
  }

  /// The top-most open app (the one active time accrues to), or null when
  /// none is open (the launcher's own screens). Shared widgets used from
  /// many apps attribute their usage to it.
  String? get currentAppId => _sessions.isEmpty ? null : _sessions.last.appId;

  /// An app's root screen mounted: counts an open and makes it the app
  /// active time accrues to until it ends or another app opens over it.
  int beginSession(String appId) {
    _closeSegment();
    final token = _nextToken++;
    _sessions.add(_Session(token, appId));
    record(appId, 'opens');
    final groupId = _groupId;
    if (_uid != null && groupId != null && appId.isNotEmpty) {
      final key = openKey(groupId, appId);
      if (!sessionOpens.value.contains(key)) {
        sessionOpens.value = {...sessionOpens.value, key};
      }
    }
    markInteraction();
    _openSegment();
    return token;
  }

  void endSession(int token) {
    _closeSegment();
    _sessions.removeWhere((s) => s.token == token);
    _openSegment();
  }

  /// Writes everything buffered so far (accruing in-progress active time
  /// first). Safe to call any time; the returned future completes when the
  /// writes are acknowledged, which only [flushAndWait] waits for.
  Future<void> flush() {
    _closeSegment();
    _openSegment();
    if (_pending.isEmpty) return Future.value();
    final entries = _pending.values.toList();
    _pending.clear();
    final writes = <Future<void>>[];
    for (final entry in entries) {
      try {
        writes.add(_writer(entry).catchError((Object e) => debugPrint('[UsageMeter] write failed: $e')));
      } catch (e) {
        debugPrint('[UsageMeter] flush failed: $e');
      }
    }
    return Future.wait(writes).then((_) {});
  }

  /// [flush], waiting (up to [timeout]) for the server to acknowledge — for
  /// moments the current credentials are about to go away.
  Future<void> flushAndWait({Duration timeout = const Duration(seconds: 3)}) =>
      flush().timeout(timeout, onTimeout: () {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      markInteraction();
      _openSegment();
    } else {
      _closeSegment();
      _foreground = false;
      unawaited(flush());
    }
  }

  // ---------------------------------------------------------------------------
  // Active-time segments: time accrues to the top session while foregrounded,
  // capped at [idleGrace] past the last input.
  // ---------------------------------------------------------------------------

  void _openSegment() {
    _segmentStart = (_foreground && _sessions.isNotEmpty) ? _clock() : null;
  }

  void _closeSegment() {
    final start = _segmentStart;
    _segmentStart = null;
    if (start == null || _sessions.isEmpty) return;
    final now = _clock();
    // Measured from the last input, not the segment start: segments are
    // re-opened every flush, and an idle app must not re-earn the grace
    // period each time.
    final idleCutoff = (_lastInteraction ?? start).add(idleGrace);
    final end = now.isBefore(idleCutoff) ? now : idleCutoff;
    final seconds = end.difference(start).inMilliseconds / 1000;
    if (seconds > 0) {
      record(_sessions.last.appId, 'activeSec', (seconds * 10).round() / 10);
    }
  }

  /// Buffered state, for tests.
  @visibleForTesting
  List<UsageDayEntry> get pendingEntries => _pending.values.toList();

  static String utcDateKey(DateTime time) {
    final d = time.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// The merge payload. The user is this doc's only creator/owner and its
  /// `uid`, and the id is `{date}_{groupId}_{uid}`: firestore.rules
  /// (usage_daily's `memberWrite` and `idPattern` in
  /// security/collections.json) let any non-guest member of the group write
  /// exactly that doc, without holding the Usage Meter app, and nothing else.
  /// Server-recorded usage goes to separate docs (functions/_usage.js) they
  /// can't touch. Identity fields are immutable after create.
  static Map<String, dynamic> buildDocData(UsageDayEntry entry) => {
        'date': entry.date,
        'groupId': entry.groupId,
        'uid': entry.uid,
        'appId': usageAppId,
        'creatorId': entry.uid,
        'ownerIds': [entry.uid],
        'apps': {
          for (final app in entry.apps.entries)
            app.key: {
              for (final m in app.value.entries) m.key: FieldValue.increment(m.value),
            },
        },
        'updatedAt': FieldValue.serverTimestamp(),
      };

  // Deliberately the raw instance, written under the unmetered context:
  // metering Usage Meter's own writes would count itself and re-enter
  // record() from inside flush().
  static Future<void> _firestoreWriter(UsageDayEntry entry) => FirestoreAttribution.runAs(
        FirestoreMeteringContext.unmetered,
        () => FirebaseFirestore.instance
            .collection(collection)
            .doc(entry.docId)
            .set(buildDocData(entry), SetOptions(merge: true)),
      );
}

/// The one way to sign a user out: flushes their buffered usage while their
/// credentials are still valid, then signs out. Enforced by
/// scripts/check_gateways.js — raw `FirebaseAuth.signOut()` calls elsewhere
/// fail CI.
///
/// Pass [clearLocalCache] when the user chose to sign out: on web it wipes
/// their cached Firestore data from the browser and reloads the tab (see
/// [clearFirestoreWebCacheAndReload]). Leave it off for sign-outs inside a
/// flow that keeps running, such as cleaning up a failed guest session.
Future<void> signOutWithUsageFlush({FirebaseAuth? auth, bool clearLocalCache = false}) async {
  await UsageMeter.instance.flushAndWait();
  await (auth ?? FirebaseAuth.instance).signOut();
  if (clearLocalCache) await clearFirestoreWebCacheAndReload();
}

class _Session {
  final int token;
  final String appId;
  const _Session(this.token, this.appId);
}

/// Wraps a launched app's root screen so [UsageMeter] records the open and
/// accrues active time to it while it is the top-most app. Applied
/// generically by `AppRouter`, so no app needs any usage code of its own.
class UsageSessionScope extends StatefulWidget {
  final String appId;
  final Widget child;

  /// Defaults to [UsageMeter.instance]; injectable for tests.
  final UsageMeter? meter;

  const UsageSessionScope({
    super.key,
    required this.appId,
    required this.child,
    this.meter,
  });

  @override
  State<UsageSessionScope> createState() => _UsageSessionScopeState();
}

class _UsageSessionScopeState extends State<UsageSessionScope> {
  late final UsageMeter _meter = widget.meter ?? UsageMeter.instance;
  late final int _token = _meter.beginSession(widget.appId);

  @override
  void initState() {
    super.initState();
    _token; // Begin the session now, not lazily on first read.
  }

  @override
  void dispose() {
    _meter.endSession(_token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
