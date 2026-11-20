// Platform-neutral half of document-level Firestore metering: attribution,
// the billing approximation, and the mixins every platform's metered
// classes are built from. The per-platform files
// (firestore_platform_metering_native.dart / _web.dart) only supply
// constructors and the two methods whose signatures differ by platform
// (`update`, `snapshots`); installation is in firestore_platform_metering.dart.

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../metered_firestore.dart' show FirestoreMeteringContext, meterEachEvent;
import '../rules_denial_reporter.dart';
import '../usage_meter.dart';

/// appId for document operations no gateway, collection or foreground app
/// can be tied to. Matches functions/_usage.js UNKNOWN_APP_ID.
const String unknownFirestoreAppId = '~unknown';

/// Which app a document operation is billed to, and the bookkeeping the
/// gateways use to know whether the platform layer metered an operation.
///
/// Attribution is resolved once, when the operation is issued (or the
/// listener is created), and that result is used when it completes, however
/// late. Most specific first:
/// 1. the context of the gateway call issuing the operation
///    (`ScopedCollection.set`, `MeteredCollectionReference.add`, the Usage
///    Meter writer's [FirestoreMeteringContext.unmetered]), set for the
///    duration of that synchronous call by [runAs];
/// 2. the context captured when the reference was created: the gateway call
///    that created it (`BluejayFirestore.forApp(appId).doc(...)`,
///    `collection(...).doc(...)`), or the metered collection or document it
///    was derived from (`collection.doc()`, `doc.collection(...)`, `parent`);
/// 3. for a reference created with neither (`snapshot.reference`, one
///    decoded from document data, the raw `FirebaseFirestore.instance`): the
///    one app whose gateway has used that collection ([noteCollection];
///    a collection several apps use, such as `users`, skips this);
/// 4. the app in the foreground ([UsageMeter.currentAppId]);
/// 5. [unknownFirestoreAppId].
class FirestoreAttribution {
  FirestoreAttribution._();

  static FirestoreMeteringContext? _current;

  /// The gateway context of the synchronous call in progress, if any.
  static FirestoreMeteringContext? get current => _current;

  /// Runs [body] with [context] as the attribution for every reference
  /// created, and every operation issued, synchronously inside it.
  static T runAs<T>(FirestoreMeteringContext context, T Function() body) {
    final previous = _current;
    _current = context;
    try {
      return body();
    } finally {
      _current = previous;
    }
  }

  static int _operationsIssued = 0;
  static int _referencesCreated = 0;

  /// How many document operations the platform layer has metered. A
  /// gateway reads it around issuing a write to tell whether the platform
  /// layer took it ([FirestoreMeteringContext.documentWrite]).
  static int get operationsIssued => _operationsIssued;

  /// How many metered references the platform layer has created (the
  /// install check probes it).
  static int get referencesCreated => _referencesCreated;

  /// Marks an app whose gateway used a collection in two or more apps.
  static const _ambiguous = '';

  /// Collection shape (`groups/members` for `groups/{id}/members`) → appId.
  static final Map<String, String> _byShape = {};

  /// Collection-group id → appId.
  static final Map<String, String> _byGroupId = {};

  /// The collection's shape: its collection ids with document ids dropped,
  /// so the table is bounded by the schema, not by the documents touched.
  static String shapeOf(String collectionPath) {
    final segments = collectionPath.split('/');
    return [for (var i = 0; i < segments.length; i += 2) segments[i]].join('/');
  }

  static void _note(Map<String, String> table, String key, String appId) {
    final seen = table[key];
    if (seen == null) {
      table[key] = appId;
    } else if (seen != appId && seen != _ambiguous) {
      table[key] = _ambiguous;
    }
  }

  /// Records that [context]'s gateway used the collection at
  /// [collectionPath] (directly, or through a `doc('coll/id')` path).
  static void noteCollection(String collectionPath, FirestoreMeteringContext? context) {
    if (context == null || context.isUnmetered) return;
    _note(_byShape, shapeOf(collectionPath), context.appId);
  }

  /// Records that [appId]'s gateway queried the collection group [collectionId].
  static void noteCollectionGroup(String collectionId, String appId) => _note(_byGroupId, collectionId, appId);

  /// The single app whose gateway has used the collection holding
  /// [documentPath], or null when none or several have.
  static String? appForDocument(String documentPath) {
    final slash = documentPath.lastIndexOf('/');
    if (slash <= 0) return null;
    final collectionPath = documentPath.substring(0, slash);
    final byShape = _byShape[shapeOf(collectionPath)];
    if (byShape != null) return byShape == _ambiguous ? null : byShape;
    final id = collectionPath.substring(collectionPath.lastIndexOf('/') + 1);
    final byGroup = _byGroupId[id];
    return byGroup == null || byGroup == _ambiguous ? null : byGroup;
  }

  /// The foreground app (rule 4); replaceable in tests.
  static String? Function() foregroundAppId = () => UsageMeter.instance.currentAppId;

  /// The context to bill an operation on [documentPath] to, issued now by a
  /// reference created with [captured] (see the rules above).
  static FirestoreMeteringContext resolve(FirestoreMeteringContext? captured, String documentPath) {
    final explicit = _current ?? captured;
    if (explicit != null) return explicit;
    final appId = appForDocument(documentPath) ?? foregroundAppId() ?? unknownFirestoreAppId;
    return FirestoreMeteringContext(appId);
  }

  @visibleForTesting
  static void resetForTesting() {
    _current = null;
    _byShape.clear();
    _byGroupId.clear();
    foregroundAppId = () => UsageMeter.instance.currentAppId;
  }
}

/// The billing approximation for one document reference's own operations,
/// shared by every platform's metered reference.
///
/// - `get()`: one read, unless served from the local cache.
/// - `set()`/`update()`: one write; `delete()`: one delete, recorded only
///   once the operation succeeds.
/// - `snapshots()`: see [DocumentListenMeter].
///
/// Each method resolves attribution when it's called (the operation is
/// issued), not when it completes. A rules denial of any of them is
/// reported to [RulesDenialReporter] (the error itself passes through
/// unchanged).
class DocumentOpsMeter {
  DocumentOpsMeter(this.path, this.captured);

  final String path;

  /// The context the reference was created under, if any.
  final FirestoreMeteringContext? captured;

  FirestoreMeteringContext _issue() {
    FirestoreAttribution._operationsIssued++;
    return FirestoreAttribution.resolve(captured, path);
  }

  void Function(Object error) _denials(String op, FirestoreMeteringContext context) =>
      (error) => RulesDenialReporter.instance.firestore(error, op: op, path: () => path, appId: context.appId);

  Future<S> get<S extends DocumentSnapshotPlatform>(Future<S> Function() operation) {
    final context = _issue();
    return RulesDenialReporter.watch(operation(), _denials('get', context)).then((snapshot) {
      if (!snapshot.metadata.isFromCache) context.record(FirestoreMeteringContext.reads, 1);
      return snapshot;
    });
  }

  /// [op] names the write in a denial report: `write` for `set()` (a create
  /// or an update; the client can't tell which), `update` for `update()`.
  Future<void> write(Future<void> Function() operation, {String op = 'write'}) {
    final context = _issue();
    return context.afterSuccess(RulesDenialReporter.watch(operation(), _denials(op, context)), writes: 1);
  }

  Future<void> delete(Future<void> Function() operation) {
    final context = _issue();
    return context.afterSuccess(RulesDenialReporter.watch(operation(), _denials('delete', context)), deletes: 1);
  }

  Stream<S> snapshots<S extends DocumentSnapshotPlatform>(
    Stream<S> Function() open, {
    required bool includeMetadataChanges,
  }) {
    final context = _issue();
    return meterEachEvent<S>(
      open(),
      () => DocumentListenMeter(context.record, includeMetadataChanges: includeMetadataChanges).call,
      onError: _denials('get', context),
    );
  }
}

/// Bills one document listener (one upstream subscription), consistently
/// with `get()`:
/// - snapshots served from the local cache are free, including the first;
/// - the first server snapshot is one read (the initial read), changed or
///   not;
/// - each later server snapshot is one read, except, with
///   `includeMetadataChanges`, one whose data equals the last seen version
///   (a pending-write ack, a cache→server flip).
/// A re-attached listener is billed its first server snapshot again.
@visibleForTesting
class DocumentListenMeter {
  DocumentListenMeter(this._record, {required this.includeMetadataChanges});

  final void Function(String metric, int amount) _record;
  final bool includeMetadataChanges;
  bool _billedInitial = false;
  bool _seen = false;
  Map<String, dynamic>? _lastData;

  static const _equality = DeepCollectionEquality();

  void call(DocumentSnapshotPlatform snapshot) {
    final data = snapshot.data();
    final unchanged = _seen && includeMetadataChanges && _equality.equals(_lastData, data);
    _seen = true;
    _lastData = data;
    if (snapshot.metadata.isFromCache) return;
    if (!_billedInitial) {
      _billedInitial = true;
      _record(FirestoreMeteringContext.reads, 1);
    } else if (!unchanged) {
      _record(FirestoreMeteringContext.reads, 1);
    }
  }
}

// -----------------------------------------------------------------------------
// The shared behaviour of every platform's metered classes. Each platform's
// classes are `PluginClass with <mixin>`, so they stay instances of the
// plugin's own classes (which the codecs type-check) and only supply
// constructors (`newMetered*`) and the methods whose signatures differ.
// -----------------------------------------------------------------------------

/// A platform instance whose collections and documents are metered.
mixin MeteredFirestorePlatform on FirebaseFirestorePlatform {
  /// This platform's metered collection at [path].
  CollectionReferencePlatform newMeteredCollection(String path, FirestoreMeteringContext? metering);

  /// This platform's metered document at [path].
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering);

  @override
  CollectionReferencePlatform collection(String collectionPath) {
    final metering = FirestoreAttribution.current;
    FirestoreAttribution.noteCollection(collectionPath, metering);
    return newMeteredCollection(collectionPath, metering);
  }

  @override
  DocumentReferencePlatform doc(String documentPath) {
    final metering = FirestoreAttribution.current;
    final slash = documentPath.lastIndexOf('/');
    if (slash > 0) FirestoreAttribution.noteCollection(documentPath.substring(0, slash), metering);
    FirestoreAttribution._referencesCreated++;
    return newMeteredDocument(documentPath, metering);
  }
}

/// A collection whose documents and parent are metered references,
/// attributed to the context it was created under. Paths are computed
/// directly; no plugin reference is built just to read its path.
mixin MeteredCollectionReferencePlatform on CollectionReferencePlatform {
  /// The context this collection was created under, if any.
  FirestoreMeteringContext? get metering;

  /// This platform's metered document at [path].
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering);

  @override
  DocumentReferencePlatform doc([String? path]) {
    FirestoreAttribution._referencesCreated++;
    return newMeteredDocument('${this.path}/${path ?? autoId()}', FirestoreAttribution.current ?? metering);
  }

  @override
  DocumentReferencePlatform? get parent {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return null;
    return newMeteredDocument(path.substring(0, slash), FirestoreAttribution.current ?? metering);
  }
}

/// A document reference whose own operations are metered (see
/// [DocumentOpsMeter]). The platform class supplies `update` and
/// `snapshots` (their signatures differ by platform) through [meter].
mixin MeteredDocumentReferencePlatform on DocumentReferencePlatform {
  /// The context this reference was created under, if any.
  FirestoreMeteringContext? get metering;

  /// Created on first use: most references are never operated on directly.
  late final DocumentOpsMeter meter = DocumentOpsMeter(path, metering);

  T _derived<T>(T Function() body) {
    final context = FirestoreAttribution.current ?? metering;
    return context == null ? body() : FirestoreAttribution.runAs(context, body);
  }

  @override
  CollectionReferencePlatform collection(String collectionPath) => _derived(() => super.collection(collectionPath));

  @override
  CollectionReferencePlatform get parent => _derived(() => super.parent);

  @override
  Future<DocumentSnapshotPlatform> get([GetOptions options = const GetOptions()]) =>
      meter.get(() => super.get(options));

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) => meter.write(() => super.set(data, options));

  @override
  Future<void> delete() => meter.delete(() => super.delete());
}

const _autoIdChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
final _autoIdRandom = math.Random.secure();

/// A 20-character random document id, the same shape the SDKs generate.
String autoId() =>
    String.fromCharCodes(List.generate(20, (_) => _autoIdChars.codeUnitAt(_autoIdRandom.nextInt(_autoIdChars.length))));
