// Production permission-denied reporter: the client half of
// functions/rules_denials.js (rulesDenialReport).
//
// The Firestore gateways (metered_firestore.dart, the platform-level
// document metering in src/document_metering.dart) and the Storage platform
// wrapper (storage_denial_reporting.dart) hand every error they see to
// [RulesDenialReporter.instance]. Errors that are rules denials (Firestore
// `permission-denied`, Storage `unauthorized`) are reduced to a shape —
// service, operation, collection shape or Storage path family, app, group,
// query filter field names — reported once per (service, operation,
// collection) per session, and sent in small batches a few seconds later.
// Nothing here ever throws into, delays or changes the caller's operation:
// the gateways rethrow the original error with its original stack trace.
//
// Privacy: no document ids, field values, document contents, file names or
// error messages leave the device. Collection paths are reduced to their
// collection ids (`groups/{id}/members/{id}` → `groups/members`), Storage
// paths to their rules family (`groups/{groupId}/apps/<app>/<folder>`).
// The server re-validates and masks again (functions/rules_denials.js).
//
// After a staged rules deploy, `node security/tools/denials.js --since <t>`
// lists what clients reported.

import 'dart:async';

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart';

import 'active_group_service.dart';
import 'usage_meter.dart';
import 'package:shared_services/cloud_functions.dart';

/// Sends one batch (`{reports, clientVersion, platform}`) to the server.
typedef RulesDenialSender = Future<void> Function(Map<String, Object?> payload);

/// Which backend refused the request.
enum DeniedService { firestore, storage }

/// Collects rules denials from the gateways and reports them, deduplicated
/// and batched, to the `rulesDenialReport` callable.
class RulesDenialReporter {
  RulesDenialReporter({
    RulesDenialSender? send,
    this.flushDelay = const Duration(seconds: 3),
    this.maxPerSession = 100,
    String? clientVersion,
    String? platform,
    String? Function()? groupId,
    String? Function()? foregroundAppId,
    int Function()? nowMs,
  })  : _send = send ?? _callableSender,
        clientVersion = clientVersion ?? _defaultClientVersion,
        platform = platform ?? _defaultPlatform(),
        _groupId = groupId ?? (() => ActiveGroupService.instance.activeGroupId),
        _foregroundAppId = foregroundAppId ?? (() => UsageMeter.instance.currentAppId),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The reporter the gateways use. Replaceable in tests.
  static RulesDenialReporter instance = RulesDenialReporter();

  /// Most reports per call (the server's limit, functions/rules_denials.js).
  static const int maxBatch = 25;

  /// The build (`--dart-define=GIT_SHA=...`, set by deploy.yml).
  static const String _defaultClientVersion =
      String.fromEnvironment('GIT_SHA', defaultValue: 'dev');

  final RulesDenialSender _send;
  final Duration flushDelay;

  /// Distinct (service, op, collection) keys reported per session at most:
  /// a broken ruleset can't turn one client into a flood.
  final int maxPerSession;
  final String clientVersion;
  final String platform;
  final String? Function() _groupId;
  final String? Function() _foregroundAppId;
  final int Function() _nowMs;

  final Set<String> _seen = {};
  final List<Map<String, Object?>> _pending = [];
  Timer? _timer;
  Future<void>? _inFlight;

  static Future<void> _callableSender(Map<String, Object?> payload) async {
    await BluejayFunctions.instance.httpsCallable('rulesDenialReport').call<Object?>(payload);
  }

  static String _defaultPlatform() => kIsWeb ? 'web' : defaultTargetPlatform.name;

  // ---------------------------------------------------------------------------
  // Classification and shapes (pure)
  // ---------------------------------------------------------------------------

  /// Whether [error] is Firestore refusing the request under security rules.
  static bool isFirestoreDenial(Object error) =>
      error is FirebaseException && error.code == 'permission-denied';

  /// Whether [error] is Storage refusing the request under security rules.
  static bool isStorageDenial(Object error) =>
      error is FirebaseException && (error.code == 'unauthorized' || error.code == 'permission-denied');

  /// The collection shape of a Firestore document or collection [path]:
  /// its collection ids, with every document id dropped
  /// (`groups/g1/members/u2` → `groups/members`, `notes` → `notes`).
  static String firestoreShape(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    // An even count is a document path: its last segment is the doc id.
    if (segments.length.isEven && segments.isNotEmpty) segments.removeLast();
    return [for (var i = 0; i < segments.length; i += 2) segments[i]].join('/');
  }

  /// The storage.rules family of an object [fullPath], with group ids, user
  /// ids and file names dropped:
  /// - `groups/{groupId}/apps/<appId>/<folder>` for ScopedStorage files
  ///   (the folder of a listed folder too);
  /// - `groups/{groupId}/logo.jpg` for the group logo;
  /// - `<root>/*` for platform roots (`profile_pictures`, `app_icons`, ...).
  static String storageFamily(String fullPath, {bool isListing = false}) {
    final s = fullPath.split('/').where((x) => x.isNotEmpty).toList();
    if (s.isEmpty) return '/';
    if (s[0] == 'groups' && s.length >= 2) {
      if (s.length >= 4 && s[2] == 'apps') {
        final hasFolder = s.length >= 6 || (s.length == 5 && isListing);
        return ['groups', '{groupId}', 'apps', s[3], if (hasFolder) s[4]].join('/');
      }
      if (s.length == 3 && s[2] == 'logo.jpg') return 'groups/{groupId}/logo.jpg';
      return 'groups/{groupId}/*';
    }
    return s.length == 1 && isListing ? s[0] : '${s[0]}/*';
  }

  /// The app a Storage object belongs to: the `<appId>` segment of a
  /// `groups/{groupId}/apps/<appId>/...` path, else null.
  static String? storageAppId(String fullPath) {
    final s = fullPath.split('/').where((x) => x.isNotEmpty).toList();
    return s.length >= 4 && s[0] == 'groups' && s[2] == 'apps' ? s[3] : null;
  }

  /// A field name from a `where()` field ([String] or [FieldPath]); values
  /// are never looked at. Other filter objects (`Filter.or(...)`) are named
  /// by kind only.
  static String filterFieldName(Object field) {
    if (field is String) return field;
    try {
      // FieldPath: its components are field names, joined as Firestore does.
      final components = (field as dynamic).components;
      if (components is List) return components.join('.');
    } catch (_) {}
    return '<filter>';
  }

  // ---------------------------------------------------------------------------
  // Gateway entry points: never throw
  // ---------------------------------------------------------------------------

  /// Reports [error] if it is a Firestore rules denial of [op] on [path]
  /// (a document or collection path, or a collection-group id when
  /// [collectionGroup]). [path] is reduced to its shape here.
  void firestore(
    Object error, {
    required String op,
    required String Function() path,
    required String appId,
    bool isQuery = false,
    bool collectionGroup = false,
    Iterable<String> filterFields = const [],
  }) {
    try {
      if (!isFirestoreDenial(error)) return;
      final raw = path();
      _enqueue(DeniedService.firestore, op,
          collectionGroup ? '**/${firestoreShape(raw)}' : firestoreShape(raw), appId,
          isQuery: isQuery, filterFields: filterFields);
    } catch (e) {
      debugPrint('[RulesDenialReporter] could not record a denial: $e');
    }
  }

  /// Like [firestore], for a write batch or transaction that touched
  /// [paths] (document paths): one report naming every collection shape.
  void firestoreMulti(Object error, {required String op, required Iterable<String> paths, required String appId}) {
    try {
      if (!isFirestoreDenial(error)) return;
      final shapes = {for (final p in paths) firestoreShape(p)}.toList()..sort();
      _enqueue(DeniedService.firestore, op, shapes.isEmpty ? '?' : shapes.take(10).join(','), appId);
    } catch (e) {
      debugPrint('[RulesDenialReporter] could not record a denial: $e');
    }
  }

  /// Reports [error] if it is a Storage rules denial of [op] on the object
  /// or folder at [fullPath].
  void storage(Object error, {required String op, required String Function() fullPath}) {
    try {
      if (!isStorageDenial(error)) return;
      final raw = fullPath();
      final appId = storageAppId(raw) ?? _foregroundAppId() ?? '~unknown';
      _enqueue(DeniedService.storage, op, storageFamily(raw, isListing: op == 'list'), appId);
    } catch (e) {
      debugPrint('[RulesDenialReporter] could not record a denial: $e');
    }
  }

  /// [operation], reporting a denial through [report] if it fails. The
  /// returned future completes exactly as [operation] does, with the same
  /// error and stack trace.
  static Future<T> watch<T>(Future<T> operation, void Function(Object error) report) =>
      operation.then((value) => value, onError: (Object error, StackTrace stack) {
        report(error);
        Error.throwWithStackTrace(error, stack);
      });

  // ---------------------------------------------------------------------------
  // Queue
  // ---------------------------------------------------------------------------

  void _enqueue(
    DeniedService service,
    String op,
    String collection,
    String appId, {
    bool isQuery = false,
    Iterable<String> filterFields = const [],
  }) {
    final key = '${service.name}|$op|$collection';
    if (_seen.length >= maxPerSession || !_seen.add(key)) return;
    final fields = {for (final f in filterFields) f}.toList()..sort();
    _pending.add({
      'service': service.name,
      'op': op,
      'collection': collection,
      'appId': appId,
      'groupId': _groupId(),
      'isQuery': isQuery,
      'filterFields': fields.take(10).toList(),
      'clientTime': _nowMs(),
    });
    if (_pending.length >= maxBatch) {
      unawaited(flush());
    } else {
      _timer ??= Timer(flushDelay, () => unawaited(flush()));
    }
  }

  /// Sends everything pending now. Failures are logged and dropped: a
  /// report is best-effort and must never surface to the user.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _inFlight ??= _drain().whenComplete(() => _inFlight = null);
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final batch = _pending.take(maxBatch).toList();
      _pending.removeRange(0, batch.length);
      try {
        await _send({'reports': batch, 'clientVersion': clientVersion, 'platform': platform});
      } catch (e) {
        debugPrint('[RulesDenialReporter] report failed (dropped): $e');
      }
    }
  }

  /// Reports waiting to be sent (tests).
  @visibleForTesting
  List<Map<String, Object?>> get pending => List.unmodifiable(_pending);
}
