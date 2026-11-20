// Metering decorators over cloud_firestore's query/collection/batch/
// transaction types.
//
// cloud_firestore marks Query with `meta`'s @sealed, which is an analyzer
// hint and not a Dart 3 class modifier, so these `implements` compile. The
// ignore below acknowledges the hint. Verified against cloud_firestore
// 6.10.x (plans/usage-meter, Phase 0 spike and Phase 4).
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'generated/collection_policies.g.dart';

import 'rules_denial_reporter.dart';
import 'src/document_metering.dart' show FirestoreAttribution;
import 'usage_meter.dart';

/// Where metered operations are reported: `(appId, metric, amount)`.
/// Defaults to [UsageMeter.record] on [UsageMeter.instance].
typedef FirestoreUsageRecorder = void Function(String appId, String metric, num amount);

/// How a debug build treats a raw `MeteredFirestore.collection()` of a
/// tenant-kind collection (see `MeteredFirestore.rawCollectionCheck`).
enum RawCollectionCheck {
  /// No check.
  off,

  /// debugPrint once per collection.
  warn,

  /// Fail the assert.
  fail,
}

/// The appId usage is attributed to, plus where it's recorded. Shared by
/// every object derived from one [MeteredFirestore].
class FirestoreMeteringContext {
  /// Metric names; priced in functions/_usage_pricing.js.
  static const reads = 'fsReads';
  static const writes = 'fsWrites';
  static const deletes = 'fsDeletes';

  final String appId;
  final FirestoreUsageRecorder? _recorder;
  final bool isUnmetered;

  const FirestoreMeteringContext(this.appId, [this._recorder]) : isUnmetered = false;

  const FirestoreMeteringContext._unmetered()
      : appId = '~unmetered',
        _recorder = null,
        isUnmetered = true;

  /// Records nothing. Only Usage Meter's own writer runs under it
  /// (usage_meter.dart): metering the meter's writes would count itself.
  static const unmetered = FirestoreMeteringContext._unmetered();

  /// The same recorder, attributing to [appId] instead.
  FirestoreMeteringContext withAppId(String appId) =>
      appId == this.appId ? this : FirestoreMeteringContext(appId, _recorder);

  void record(String metric, num amount) {
    if (amount <= 0 || isUnmetered) return;
    final recorder = _recorder;
    if (recorder != null) {
      recorder(appId, metric, amount);
    } else {
      UsageMeter.instance.record(appId, metric, amount);
    }
  }

  /// A one-off query result: Firestore bills one read per document returned,
  /// and one read for a query that returns nothing. Cache-served results are
  /// free.
  void recordQueryResult(QuerySnapshot<Object?> snapshot) {
    if (snapshot.metadata.isFromCache) return;
    record(reads, math.max(1, snapshot.size));
  }

  /// Records [writes]/[deletes] once [operation] has succeeded. A write that
  /// fails (rejected by rules, aborted) isn't billed.
  Future<R> afterSuccess<R>(Future<R> operation, {int writes = 0, int deletes = 0}) =>
      operation.then((result) {
        record(FirestoreMeteringContext.writes, writes);
        record(FirestoreMeteringContext.deletes, deletes);
        return result;
      });

  /// Issues a single-document write ([issue], e.g. `() => ref.set(data)`)
  /// billed to this context, whatever the reference came from.
  ///
  /// When the platform layer meters the write (firestore_platform_metering.dart
  /// is installed and the reference is one of its own), it bills it to this
  /// context. Otherwise (metering not installed, a reference from an
  /// instance resolved before install, a test fake) this records it here
  /// once it succeeds, so a gateway write is never left uncounted.
  Future<R> documentWrite<R>(Future<R> Function() issue, {int writes = 0, int deletes = 0}) {
    final before = FirestoreAttribution.operationsIssued;
    final operation = FirestoreAttribution.runAs(this, issue);
    if (FirestoreAttribution.operationsIssued != before) return operation;
    return afterSuccess(operation, writes: writes, deletes: deletes);
  }
}

// -----------------------------------------------------------------------------
// Design note: DocumentReferences are never wrapped here.
//
// cloud_firestore turns a DocumentReference into a storable value by reading
// its library-private `_delegate`, which only the plugin's own classes have.
// It does this in places a decorator can't intercept, such as
// `FieldValue.arrayUnion([ref])` and `Filter('f', isEqualTo: ref)`, which
// encode when they're constructed, and in plain plugin objects reached from
// snapshot data. A wrapped reference that ever reached one of those would
// throw. So every DocumentReference this file hands out (`doc()`, `add()`'s
// result, `parent`, `snapshot.reference`) is the plugin's own object, and the
// decorators here meter the things that can never be field values: queries,
// collections, batches, transactions, and the Firestore instance itself.
//
// Operations called directly on a DocumentReference (get/listen/set/update/
// delete, and `add()`, which is a `doc().set()`) are metered one layer down,
// by the platform references firestore_platform_metering.dart installs. The
// decorators tell that layer which app a reference or write belongs to: each
// call that creates one runs inside `FirestoreAttribution.runAs(metering)`.
// Gateway writes (`add()`, `ScopedCollection.set()`) go through
// `FirestoreMeteringContext.documentWrite`, which records them itself if
// the platform layer didn't, so they're counted even when it isn't active.
// -----------------------------------------------------------------------------

/// A [FirebaseFirestore] whose collections, queries, batches and transactions
/// record what Firestore bills (reads, writes, deletes) against one app via
/// [UsageMeter]. Obtain one with `BluejayFirestore.forApp`.
///
/// It is a drop-in `FirebaseFirestore`: anything typed as one accepts it.
/// The underlying instance is resolved lazily on first use, so creating one
/// before Firebase is initialized is safe.
class MeteredFirestore implements FirebaseFirestore {
  MeteredFirestore(this.metering, {FirebaseFirestore Function()? resolve})
      : _resolve = resolve ?? (() => FirebaseFirestore.instance);

  final FirestoreMeteringContext metering;
  final FirebaseFirestore Function() _resolve;
  FirebaseFirestore? _resolved;

  /// The plugin's own (unmetered) instance.
  FirebaseFirestore get unmetered => _resolved ??= _resolve();

  String get appId => metering.appId;

  @override
  FirebaseApp get app => unmetered.app;

  @override
  set app(FirebaseApp value) => unmetered.app = value;

  @override
  String get databaseId => unmetered.databaseId;

  @override
  set databaseId(String value) => unmetered.databaseId = value;

  @override
  Map<dynamic, dynamic> get pluginConstants => unmetered.pluginConstants;

  /// A raw collection. Expected only for pass-through kinds (every kind but
  /// `tenant` in security/collections.json, mirrored in
  /// generated/collection_policies.g.dart): tenant data goes through a
  /// `ScopedCollection`, which stamps and filters the tenant fields the
  /// rules prove. Debug builds check that here ([rawCollectionCheck]);
  /// scripts/check_gateways.js (`raw-collection`) checks it statically.
  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    assert(checkRawCollection(collectionPath));
    return scopedCollection(collectionPath);
  }

  /// [collection] without the raw-collection check: `ScopedCollection`'s own
  /// entry point (scripts/check_gateways.js `gateway-collection` allows it
  /// nowhere else).
  CollectionReference<Map<String, dynamic>> scopedCollection(String collectionPath) => MeteredCollectionReference(
      FirestoreAttribution.runAs(metering, () => unmetered.collection(collectionPath)), metering);

  /// What a debug build does when [collection] is asked for a tenant-kind
  /// collection. Defaults to [RawCollectionCheck.warn] (one debugPrint per
  /// collection) while existing raw call sites are migrated (the
  /// check_gateways `raw-collection` ratchet lists them); tests and, once
  /// the ratchet is at zero, debug builds can set [RawCollectionCheck.fail].
  static RawCollectionCheck rawCollectionCheck = RawCollectionCheck.warn;

  static final Set<String> _warnedRawCollections = {};

  /// Whether a raw [collectionPath] passes [rawCollectionCheck]: true for a
  /// pass-through kind, or when the check only warns. Called from an
  /// `assert`, so release builds never run it.
  @visibleForTesting
  static bool checkRawCollection(String collectionPath) {
    if (rawCollectionCheck == RawCollectionCheck.off) return true;
    final name = collectionPath.split('/').first;
    if (collectionPolicyFor(name).isPassThrough) return true;
    if (rawCollectionCheck == RawCollectionCheck.fail) return false;
    if (_warnedRawCollections.add(name)) {
      debugPrint(
        'MeteredFirestore: raw collection("$collectionPath") of tenant collection "$name". '
        'Use a ScopedCollection (sub() / docForKey()), or declare a pass-through kind in '
        'security/collections.json.',
      );
    }
    return true;
  }

  /// The plugin's own reference (see the design note above), attributed to
  /// this app.
  @override
  DocumentReference<Map<String, dynamic>> doc(String documentPath) =>
      FirestoreAttribution.runAs(metering, () => unmetered.doc(documentPath));

  @override
  Query<Map<String, dynamic>> collectionGroup(String collectionPath) {
    FirestoreAttribution.noteCollectionGroup(collectionPath, appId);
    return MeteredQuery(unmetered.collectionGroup(collectionPath), metering,
        source: collectionPath, collectionGroup: true);
  }

  @override
  WriteBatch batch() => MeteredWriteBatch(unmetered.batch(), metering);

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    // A handler can run more than once (contention retries). Every attempt's
    // reads are billed; only the attempt that commits writes anything.
    MeteredTransaction? lastAttempt;
    final T result;
    try {
      result = await unmetered.runTransaction<T>(
        (tx) {
          final attempt = MeteredTransaction(tx, metering);
          lastAttempt = attempt;
          return transactionHandler(attempt);
        },
        timeout: timeout,
        maxAttempts: maxAttempts,
      );
    } catch (error) {
      // A denied tx.get() was already reported by MeteredTransaction; this
      // reports a refused commit, naming the collections it wrote.
      final written = lastAttempt?._writtenPaths ?? const <String>[];
      if (written.isNotEmpty) {
        RulesDenialReporter.instance.firestoreMulti(error, op: 'transaction', paths: written, appId: appId);
      }
      rethrow;
    }
    lastAttempt?._recordCommitted();
    return result;
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> namedQueryGet(
    String name, {
    GetOptions options = const GetOptions(),
  }) async {
    final snapshot = await unmetered.namedQueryGet(name, options: options);
    metering.recordQueryResult(snapshot);
    return snapshot;
  }

  @override
  Future<QuerySnapshot<T>> namedQueryWithConverterGet<T>(
    String name, {
    GetOptions options = const GetOptions(),
    required FromFirestore<T> fromFirestore,
    required ToFirestore<T> toFirestore,
  }) async {
    final snapshot = await unmetered.namedQueryWithConverterGet<T>(name,
        options: options, fromFirestore: fromFirestore, toFirestore: toFirestore);
    metering.recordQueryResult(snapshot);
    return snapshot;
  }

  @override
  LoadBundleTask loadBundle(Uint8List bundle) => unmetered.loadBundle(bundle);

  @override
  Future<void> clearPersistence() => unmetered.clearPersistence();

  @override
  Future<void> disableNetwork() => unmetered.disableNetwork();

  @override
  Future<void> enableNetwork() => unmetered.enableNetwork();

  @override
  Stream<void> snapshotsInSync() => unmetered.snapshotsInSync();

  @override
  Settings get settings => unmetered.settings;

  @override
  set settings(Settings settings) => unmetered.settings = settings;

  @override
  Future<void> terminate() => unmetered.terminate();

  @override
  Future<void> waitForPendingWrites() => unmetered.waitForPendingWrites();

  @override
  void useFirestoreEmulator(String host, int port, {bool sslEnabled = false, bool automaticHostMapping = true}) =>
      unmetered.useFirestoreEmulator(host, port, sslEnabled: sslEnabled, automaticHostMapping: automaticHostMapping);

  @override
  PersistentCacheIndexManager? persistentCacheIndexManager() => unmetered.persistentCacheIndexManager();

  /// Not metered: pipelines are a preview API nothing here uses yet.
  @override
  PipelineSource pipeline() => unmetered.pipeline();

  @override
  // ignore: experimental_member_use
  Future<void> setIndexConfigurationFromJSON(String json) => unmetered.setIndexConfigurationFromJSON(json);

  @override
  bool operator ==(Object other) => unmetered == (other is MeteredFirestore ? other.unmetered : other);

  @override
  int get hashCode => unmetered.hashCode;

  @override
  String toString() => unmetered.toString();
}

// -----------------------------------------------------------------------------
// Query / CollectionReference
// -----------------------------------------------------------------------------

/// A [Query] that records the reads its `get()`/`snapshots()` are billed for.
/// Every refinement (`where`, `orderBy`, `limit`, cursors, `withConverter`)
/// returns another [MeteredQuery]. Values (filters, cursors) pass straight
/// through, so anything the plugin accepts is accepted unchanged.
class MeteredQuery<T extends Object?> implements Query<T> {
  MeteredQuery(
    this._inner,
    this.metering, {
    String? source,
    this.collectionGroup = false,
    List<String> filterFields = const [],
  })  : _source = source,
        _filterFields = filterFields;

  final Query<T> _inner;
  final FirestoreMeteringContext metering;

  /// The collection path (or collection-group id) this query reads, for
  /// denial reports; null when unknown.
  final String? _source;

  /// Whether the source is a collection-group id.
  final bool collectionGroup;

  /// The field names (never values) this query filters on, for denial
  /// reports.
  final List<String> _filterFields;

  /// The plugin's own (unmetered) query.
  Query<T> get unmetered => _inner;

  String get _sourcePath => _source ?? '?';

  MeteredQuery<T> _wrap(Query<T> q, {String? filterField}) => MeteredQuery<T>(q, metering,
      source: _sourcePath,
      collectionGroup: collectionGroup,
      filterFields: filterField == null ? _filterFields : [..._filterFields, filterField]);

  /// Reports [error] to [RulesDenialReporter] if it's a rules denial of this
  /// query (a `list`, in rules terms).
  void reportDenial(Object error) => RulesDenialReporter.instance.firestore(error,
      op: 'list',
      path: () => _sourcePath,
      appId: metering.appId,
      isQuery: true,
      collectionGroup: collectionGroup,
      filterFields: _filterFields);

  @override
  FirebaseFirestore get firestore => MeteredFirestore(metering, resolve: () => _inner.firestore);

  @override
  Map<String, dynamic> get parameters => _inner.parameters;

  @override
  Future<QuerySnapshot<T>> get([GetOptions? options]) async {
    final QuerySnapshot<T> snapshot;
    try {
      snapshot = await _inner.get(options);
    } catch (error) {
      reportDenial(error);
      rethrow;
    }
    metering.recordQueryResult(snapshot);
    return snapshot;
  }

  @override
  Stream<QuerySnapshot<T>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      meterEachEvent<QuerySnapshot<T>>(
        _inner.snapshots(includeMetadataChanges: includeMetadataChanges, source: source),
        () => QueryListenMeter<T>(metering, includeMetadataChanges: includeMetadataChanges).call,
        onError: reportDenial,
      );

  @override
  AggregateQuery count() => MeteredAggregateQuery(_inner.count(), this);

  @override
  AggregateQuery aggregate(
    AggregateField aggregateField1, [
    AggregateField? aggregateField2,
    AggregateField? aggregateField3,
    AggregateField? aggregateField4,
    AggregateField? aggregateField5,
    AggregateField? aggregateField6,
    AggregateField? aggregateField7,
    AggregateField? aggregateField8,
    AggregateField? aggregateField9,
    AggregateField? aggregateField10,
    AggregateField? aggregateField11,
    AggregateField? aggregateField12,
    AggregateField? aggregateField13,
    AggregateField? aggregateField14,
    AggregateField? aggregateField15,
    AggregateField? aggregateField16,
    AggregateField? aggregateField17,
    AggregateField? aggregateField18,
    AggregateField? aggregateField19,
    AggregateField? aggregateField20,
    AggregateField? aggregateField21,
    AggregateField? aggregateField22,
    AggregateField? aggregateField23,
    AggregateField? aggregateField24,
    AggregateField? aggregateField25,
    AggregateField? aggregateField26,
    AggregateField? aggregateField27,
    AggregateField? aggregateField28,
    AggregateField? aggregateField29,
    AggregateField? aggregateField30,
  ]) =>
      MeteredAggregateQuery(
        _inner.aggregate(
          aggregateField1,
          aggregateField2,
          aggregateField3,
          aggregateField4,
          aggregateField5,
          aggregateField6,
          aggregateField7,
          aggregateField8,
          aggregateField9,
          aggregateField10,
          aggregateField11,
          aggregateField12,
          aggregateField13,
          aggregateField14,
          aggregateField15,
          aggregateField16,
          aggregateField17,
          aggregateField18,
          aggregateField19,
          aggregateField20,
          aggregateField21,
          aggregateField22,
          aggregateField23,
          aggregateField24,
          aggregateField25,
          aggregateField26,
          aggregateField27,
          aggregateField28,
          aggregateField29,
          aggregateField30,
        ),
        this,
      );

  @override
  Query<T> endAtDocument(DocumentSnapshot documentSnapshot) => _wrap(_inner.endAtDocument(documentSnapshot));

  @override
  Query<T> endAt(Iterable<Object?> values) => _wrap(_inner.endAt(values));

  @override
  Query<T> endBeforeDocument(DocumentSnapshot documentSnapshot) => _wrap(_inner.endBeforeDocument(documentSnapshot));

  @override
  Query<T> endBefore(Iterable<Object?> values) => _wrap(_inner.endBefore(values));

  @override
  Query<T> limit(int limit) => _wrap(_inner.limit(limit));

  @override
  Query<T> limitToLast(int limit) => _wrap(_inner.limitToLast(limit));

  @override
  Query<T> orderBy(Object field, {bool descending = false}) => _wrap(_inner.orderBy(field, descending: descending));

  @override
  Query<T> startAfterDocument(DocumentSnapshot documentSnapshot) =>
      _wrap(_inner.startAfterDocument(documentSnapshot));

  @override
  Query<T> startAfter(Iterable<Object?> values) => _wrap(_inner.startAfter(values));

  @override
  Query<T> startAtDocument(DocumentSnapshot documentSnapshot) => _wrap(_inner.startAtDocument(documentSnapshot));

  @override
  Query<T> startAt(Iterable<Object?> values) => _wrap(_inner.startAt(values));

  @override
  Query<T> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) =>
      _wrap(
          _inner.where(
            field,
        isEqualTo: isEqualTo,
        isNotEqualTo: isNotEqualTo,
        isLessThan: isLessThan,
        isLessThanOrEqualTo: isLessThanOrEqualTo,
        isGreaterThan: isGreaterThan,
        isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
        arrayContains: arrayContains,
        arrayContainsAny: arrayContainsAny,
        whereIn: whereIn,
            whereNotIn: whereNotIn,
            isNull: isNull,
          ),
          filterField: RulesDenialReporter.filterFieldName(field));

  @override
  Query<R> withConverter<R>({
    required FromFirestore<R> fromFirestore,
    required ToFirestore<R> toFirestore,
  }) =>
      MeteredQuery<R>(_inner.withConverter<R>(fromFirestore: fromFirestore, toFirestore: toFirestore), metering,
          source: _source, collectionGroup: collectionGroup, filterFields: _filterFields);

  @override
  bool operator ==(Object other) => _inner == (other is MeteredQuery ? other._inner : other);

  @override
  int get hashCode => _inner.hashCode;

  @override
  String toString() => _inner.toString();
}

/// A [CollectionReference] whose queries are metered. `doc()`, `add()`'s
/// result and `parent` are the plugin's own references, attributed to this
/// collection's app; their operations (including the `set()` that `add()`
/// is) are metered by the platform layer (see the design note above).
class MeteredCollectionReference<T extends Object?> extends MeteredQuery<T> implements CollectionReference<T> {
  MeteredCollectionReference(CollectionReference<T> super.inner, super.metering);

  CollectionReference<T> get _collection => _inner as CollectionReference<T>;

  /// Read lazily: only a denial report needs it.
  @override
  String get _sourcePath => _collection.path;

  @override
  CollectionReference<T> get unmetered => _collection;

  @override
  String get id => _collection.id;

  @override
  String get path => _collection.path;

  @override
  DocumentReference<Map<String, dynamic>>? get parent => _collection.parent;

  /// `add()` is a `doc().set()`: billed one write to this collection's app,
  /// by the platform layer or, when it isn't active, here.
  @override
  Future<DocumentReference<T>> add(T data) => metering.documentWrite(() => _collection.add(data), writes: 1);

  @override
  DocumentReference<T> doc([String? path]) => FirestoreAttribution.runAs(metering, () => _collection.doc(path));

  @override
  CollectionReference<R> withConverter<R extends Object?>({
    required FromFirestore<R> fromFirestore,
    required ToFirestore<R> toFirestore,
  }) =>
      MeteredCollectionReference<R>(
          _collection.withConverter<R>(fromFirestore: fromFirestore, toFirestore: toFirestore), metering);
}

/// `count()` / `aggregate()`: billed one read per batch of up to 1000 index
/// entries scanned, which the client can't see, so it's approximated as one
/// read.
class MeteredAggregateQuery implements AggregateQuery {
  MeteredAggregateQuery(this._inner, this.query);

  final AggregateQuery _inner;

  @override
  final MeteredQuery query;

  @override
  Future<AggregateQuerySnapshot> get({AggregateSource source = AggregateSource.server}) async {
    final AggregateQuerySnapshot snapshot;
    try {
      snapshot = await _inner.get(source: source);
    } catch (error) {
      query.reportDenial(error);
      rethrow;
    }
    query.metering.record(FirestoreMeteringContext.reads, 1);
    return snapshot;
  }

  @override
  AggregateQuery count() => MeteredAggregateQuery(_inner.count(), query);

  @override
  String toString() => _inner.toString();
}

// -----------------------------------------------------------------------------
// Listeners
// -----------------------------------------------------------------------------

/// [source], with [newMeter]'s callback run exactly once per event the
/// source emits, however many times the result is listened to.
///
/// The source is subscribed once per active listen. For a broadcast source,
/// every listener shares that one upstream subscription (and one meter), so
/// N listeners don't bill an event N times. A fresh upstream subscription
/// (after everyone cancelled) gets a fresh meter, because Firestore bills a
/// re-attached listener again.
///
/// [onError], if given, sees each error the source emits before it is
/// passed on unchanged (denial reporting).
Stream<S> meterEachEvent<S>(
  Stream<S> source,
  void Function(S event) Function() newMeter, {
  void Function(Object error)? onError,
}) {
  StreamSubscription<S>? upstream;
  late final StreamController<S> controller;

  void onListen() {
    final meter = newMeter();
    upstream = source.listen(
      (event) {
        meter(event);
        controller.add(event);
      },
      onError: (Object error, StackTrace stack) {
        onError?.call(error);
        controller.addError(error, stack);
      },
      onDone: controller.close,
    );
  }

  Future<void>? onCancel() {
    final sub = upstream;
    upstream = null;
    return sub?.cancel();
  }

  controller = source.isBroadcast
      ? StreamController<S>.broadcast(onListen: onListen, onCancel: onCancel, sync: true)
      : StreamController<S>(
          onListen: onListen,
          onPause: () => upstream?.pause(),
          onResume: () => upstream?.resume(),
          onCancel: onCancel,
          sync: true,
        );
  return controller.stream;
}

/// Bills one query listener (one upstream subscription).
///
/// Approximation of Firestore's listener billing:
/// - The initial result set is billed once (min 1), on the first snapshot,
///   whether it arrives from the local cache (a warm, persisted cache may
///   never be followed by a server snapshot) or from the server. A
///   cache-then-server pair bills the server snapshot's changes only.
/// - Later snapshots bill one read per changed document (`docChanges`).
/// - Later snapshots served from cache (offline edits) are free.
/// - With `includeMetadataChanges`, a change whose data is identical to the
///   last seen version (pending-write ack, cache→server flip) is free.
///
/// It over-counts a listener re-attached within Firestore's 30-minute resume
/// window (billed only for changes) and an offline-only first snapshot.
@visibleForTesting
class QueryListenMeter<T extends Object?> {
  QueryListenMeter(this._metering, {required this.includeMetadataChanges});

  final FirestoreMeteringContext _metering;
  final bool includeMetadataChanges;
  bool _initialCounted = false;

  /// Last seen data per doc id, only kept to spot metadata-only changes.
  final Map<String, Object?> _lastData = {};

  static const _equality = DeepCollectionEquality();

  void call(QuerySnapshot<T> snapshot) {
    if (!_initialCounted) {
      _initialCounted = true;
      _metering.record(FirestoreMeteringContext.reads, math.max(1, snapshot.size));
      if (includeMetadataChanges) {
        for (final doc in snapshot.docs) {
          _lastData[doc.id] = doc.data();
        }
      }
      return;
    }
    var billed = 0;
    for (final change in snapshot.docChanges) {
      final id = change.doc.id;
      if (change.type == DocumentChangeType.removed) {
        _lastData.remove(id);
        billed++;
        continue;
      }
      final data = includeMetadataChanges ? change.doc.data() : null;
      final metadataOnly = includeMetadataChanges &&
          change.type == DocumentChangeType.modified &&
          _lastData.containsKey(id) &&
          _equality.equals(_lastData[id], data);
      if (includeMetadataChanges) _lastData[id] = data;
      if (!metadataOnly) billed++;
    }
    if (!snapshot.metadata.isFromCache) {
      _metering.record(FirestoreMeteringContext.reads, billed);
    }
  }
}

// -----------------------------------------------------------------------------
// WriteBatch / Transaction
// -----------------------------------------------------------------------------

/// A [WriteBatch] that records its writes/deletes once its commit succeeds.
class MeteredWriteBatch implements WriteBatch {
  MeteredWriteBatch(this._inner, this.metering);

  final WriteBatch _inner;
  final FirestoreMeteringContext metering;
  int _writes = 0;
  int _deletes = 0;

  /// Paths written, for a denial report naming the batch's collections.
  final Set<String> _paths = {};

  WriteBatch get unmetered => _inner;

  @override
  Future<void> commit() {
    final writes = _writes;
    final deletes = _deletes;
    final paths = _paths.toList();
    _writes = 0;
    _deletes = 0;
    _paths.clear();
    return metering.afterSuccess(
      RulesDenialReporter.watch(
        _inner.commit(),
        (error) => RulesDenialReporter.instance.firestoreMulti(error, op: 'commit', paths: paths, appId: metering.appId),
      ),
      writes: writes,
      deletes: deletes,
    );
  }

  void _note(DocumentReference document) {
    try {
      _paths.add(document.path);
    } catch (_) {
      // A test fake without a path: nothing to report on.
    }
  }

  @override
  void delete(DocumentReference document) {
    _deletes++;
    _note(document);
    _inner.delete(document);
  }

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) {
    _writes++;
    _note(document);
    _inner.set<T>(document, data, options);
  }

  @override
  void update<T>(DocumentReference<T> document, T data) {
    _writes++;
    _note(document);
    _inner.update<T>(document, data);
  }
}

/// A [Transaction] whose reads are recorded as they happen (every attempt
/// is billed) and whose writes are recorded only once the transaction
/// commits (see [MeteredFirestore.runTransaction]).
class MeteredTransaction implements Transaction {
  MeteredTransaction(this._inner, this.metering);

  Transaction _inner;
  final FirestoreMeteringContext metering;
  int _writes = 0;
  int _deletes = 0;

  /// Paths written, for a denial report if the commit is refused.
  final List<String> _writtenPaths = [];

  void _note(DocumentReference document) {
    try {
      _writtenPaths.add(document.path);
    } catch (_) {
      // A test fake without a path: nothing to report on.
    }
  }

  Transaction get unmetered => _inner;

  void _recordCommitted() {
    metering.record(FirestoreMeteringContext.writes, _writes);
    metering.record(FirestoreMeteringContext.deletes, _deletes);
  }

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(DocumentReference<T> documentReference) async {
    final DocumentSnapshot<T> snapshot;
    try {
      snapshot = await _inner.get<T>(documentReference);
    } catch (error) {
      RulesDenialReporter.instance.firestore(error, op: 'get', path: () => documentReference.path, appId: metering.appId);
      rethrow;
    }
    metering.record(FirestoreMeteringContext.reads, 1);
    return snapshot;
  }

  @override
  Transaction delete(DocumentReference documentReference) {
    _deletes++;
    _note(documentReference);
    _inner = _inner.delete(documentReference);
    return this;
  }

  @override
  Transaction update(DocumentReference documentReference, Map<Object, Object?> data) {
    _writes++;
    _note(documentReference);
    _inner = _inner.update(documentReference, data);
    return this;
  }

  @override
  Transaction set<T>(DocumentReference<T> documentReference, T data, [SetOptions? options]) {
    _writes++;
    _note(documentReference);
    _inner = _inner.set<T>(documentReference, data, options);
    return this;
  }
}
