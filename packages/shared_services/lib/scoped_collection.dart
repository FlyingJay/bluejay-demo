import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/generated/collection_policies.g.dart';
import 'package:shared_services/rules_contract_recorder.dart';

import 'src/document_metering.dart' show FirestoreAttribution;

export 'package:shared_services/generated/collection_policies.g.dart'
    show CollectionKind, CollectionPolicy, collectionPolicyFor;

/// A scoped wrapper around a Firestore collection that automatically applies
/// multi-tenant access controls.
///
/// Every package that reads or writes tenant-scoped data should create one
/// instance of this class (typically as a file-level or class-level constant)
/// instead of calling [FirebaseFirestore.instance.collection()] directly.
/// The Firestore reference is created lazily the first time it is needed, so
/// instances can safely be declared at the top-level before Firebase is
/// initialised.
///
/// It is convenience, not the security boundary: firestore.rules decides
/// every request. What it buys is that default code makes requests the
/// rules can prove (plans/firestore-rules/IMPLEMENTATION_PLAN.md §2.2,
/// pillar 3). Each collection's kind and owning apps come from the policy
/// table (security/collections.json, mirrored in
/// generated/collection_policies.g.dart).
///
/// **Reading**
///
/// Use [query] to get a [Query] that is already filtered to the active group
/// (and, for a collection several apps own, to this app):
///
/// ```dart
/// final _notes = ScopedCollection(collection: 'notes', appId: notesAppId);
///
/// _notes.query.snapshots();
/// _notes.query
///     .where('creatorId', isEqualTo: uid)
///     .orderBy('lastEdited', descending: true)
///     .snapshots();
/// ```
///
/// **Writing**
///
/// [add], [create] and [batchSet] create documents, stamping the tenant and
/// ownership fields. [set] stamps them only when the document doesn't exist
/// yet: an update never rewrites `groupId`, `appId`, `creatorId` or
/// `ownerIds` (§4.3), whatever the caller passes, except that an explicit
/// `ownerIds` is kept (sharing).
///
/// | Field       | On create                                   | On update |
/// |-------------|---------------------------------------------|-----------|
/// | `groupId`   | [ActiveGroupService.activeGroupId]          | unchanged |
/// | `appId`     | [appId]                                     | unchanged |
/// | `creatorId` | current user UID                            | unchanged |
/// | `ownerIds`  | `[currentUserUid]` unless provided by caller| caller's, if given |
///
/// **Subcollections** go through [sub], which stamps the parent document's
/// `groupId`/`appId` on what it creates. **Natural-key ids** (a uid, a
/// slug) go through [docForKey] and the `*ForKey` helpers, which tag the id
/// with the tenant (`{groupId}__{key}`) so two groups never share a doc.
///
/// **Document-level operations (update / delete)**
///
/// Use [doc] to get a [DocumentReference] for updates and deletes:
///
/// ```dart
/// await _notes.doc(noteId).update({'title': 'Updated'});
/// ```
///
/// **Usage metering**
///
/// [query], the other `query*` variants and whatever is chained off them,
/// [add], [set], [batchSet] (through a batch from `BluejayFirestore`) and
/// operations on the references [doc] returns all record the reads and
/// writes Firestore bills against [appId] through `UsageMeter` (see
/// [BluejayFirestore]). Callers need do nothing. [doc] returns the plugin's
/// own reference type; its operations are metered at the platform layer
/// (firestore_platform_metering.dart).
class ScopedCollection {
  /// The Firestore collection path: a top-level name (e.g. `'notes'`), or
  /// `parent/{parentId}/name` for a [sub] collection.
  final String collection;

  /// Sentinel value used as the `groupId` filter when no group is active,
  /// ensuring the query matches nothing rather than leaking cross-group data.
  static const String _noActiveGroupSentinel = '__no_active_group__';

  /// The permission fields a create stamps, and an update never rewrites.
  static const identityFields = ['groupId', 'appId', 'creatorId', 'ownerIds'];

  /// The app ID registered in `apps/{appId}` that owns this collection.
  ///
  /// This value is written to every document as the `appId` field and is
  /// combined with [ActiveGroupService.activeGroupId] to form the permission
  /// scope string (`groupId:appId`) checked by the Firestore security rules.
  final String appId;

  /// Underlying Firestore override for tests; defaults to the app's
  /// metered instance ([BluejayFirestore.forApp]).
  final FirebaseFirestore? _firestore;

  /// Current-user override for tests; defaults to FirebaseAuth.
  final String Function()? _currentUid;

  /// For a [sub] collection: the parent document's path.
  final String? _parentPath;

  /// Policy override for tests; defaults to the generated table's entry.
  final CollectionPolicy? _policy;

  ScopedCollection({
    required this.collection,
    required this.appId,
    @visibleForTesting FirebaseFirestore? firestore,
    @visibleForTesting String Function()? currentUid,
    @visibleForTesting CollectionPolicy? policy,
  })  : _firestore = firestore,
        _currentUid = currentUid,
        _policy = policy,
        _parentPath = null;

  ScopedCollection._sub(
    ScopedCollection parent,
    String parentId,
    String name,
  )   : collection = '${parent.collection}/$parentId/$name',
        appId = parent.appId,
        _firestore = parent._firestore,
        _currentUid = parent._currentUid,
        _policy = parent._policy,
        _parentPath = '${parent.collection}/$parentId';

  /// This collection's app's metered Firestore. [BluejayFirestore.forApp]
  /// resolves the plugin instance lazily, so this is safe before Firebase is
  /// initialised; an injected test instance keeps its own recorder.
  late final MeteredFirestore _db =
      BluejayFirestore.forApp(appId, firestore: _firestore) as MeteredFirestore;

  /// Metered Firestore collection reference. Goes through
  /// [MeteredFirestore.scopedCollection], which skips the raw-collection
  /// debug check meant for code that bypasses this class.
  CollectionReference<Map<String, dynamic>> get _ref =>
      _db.scopedCollection(collection);

  String get _groupId => ActiveGroupService.instance.activeGroupId ?? '';
  String get _uid =>
      _currentUid?.call() ?? FirebaseAuth.instance.currentUser?.uid ?? '';

  /// The top-level collection this one is (or sits under).
  String get rootCollection => collection.split('/').first;

  /// Whether this is a [sub] collection.
  bool get isSubcollection => _parentPath != null;

  /// The policy-table entry for [rootCollection].
  CollectionPolicy get policy => _policy ?? collectionPolicyFor(rootCollection);

  /// Whether this collection's docs are on the audit trail: the table's
  /// `auditTrail` for a top-level collection, or the subcollection's own
  /// `auditTrail` (`subcollections.<name>.auditTrail`, or the comment thread
  /// a `commentThread` entry carries) for a [sub] collection.
  bool get isAudited => isSubcollection
      ? policy.auditedSubcollections.contains(collection.split('/').last)
      : policy.auditTrail;

  /// Whether this is a [sub] collection declared `selfKeyed.selfRead`: each
  /// doc is readable only by the uid it is keyed by (and platform admins),
  /// so it is read by id, never listed.
  bool get isSelfRead =>
      isSubcollection &&
      policy.selfReadSubcollections.contains(collection.split('/').last);

  /// The fields every write to an audited collection must carry: the writer
  /// and the server's time, which the rules require and the audit trail
  /// records as the actor. Empty for a collection that isn't audited.
  Map<String, dynamic> auditStamp() => isAudited
      ? {'lastModifiedBy': _uid, 'lastModifiedAt': FieldValue.serverTimestamp()}
      : const {};

  /// Whether [query] also filters on `appId`: the collection is owned by
  /// several apps and this is one of them (§4.8). A collection the table
  /// hasn't declared apps for yet is treated as single-app.
  bool get filtersByApp =>
      !isSubcollection && policy.isMultiApp && policy.apps.contains(appId);

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  /// A [Query] the rules can prove: pre-filtered to the active group and, for
  /// a multi-app collection ([filtersByApp]), to this app.
  ///
  /// Chain additional `.where()`, `.orderBy()`, `.limit()` etc. on this to
  /// add app-specific constraints.
  ///
  /// When no group is active (e.g. during sign-out) this returns a query that
  /// matches no documents, preventing accidental cross-group data exposure.
  ///
  /// For a [sub] collection this is the subcollection itself: its rule
  /// proves the tenant through the parent document, and subcollection docs
  /// written before [sub] existed don't carry `groupId` (M5 backfills it).
  Query<Map<String, dynamic>> get query => queryInGroup(_groupId);

  /// [query] for an explicit [groupId] instead of the active group: for
  /// code bound to a group it was handed (a detail screen opened for one
  /// group) rather than whichever group is active. The rules prove it the
  /// same way; an empty [groupId] matches nothing. For a [sub] collection
  /// this is the subcollection itself, as for [query].
  Query<Map<String, dynamic>> queryInGroup(String groupId) {
    assert(
      !isSelfRead,
      '$collection is selfKeyed.selfRead: the rules let a member read only '
      'their own doc there, so get it by id (doc(uid)) instead of listing.',
    );
    if (isSubcollection || groupId.isNotEmpty) _recordList(_baseFilters);
    return _groupQuery(groupId);
  }

  /// The contract filters of [queryInGroup] (none for a [sub] collection).
  List<List<Object?>> get _baseFilters => isSubcollection
      ? const []
      : [
          ['groupId', '==', RulesContractRecorder.group],
          if (filtersByApp) ['appId', '==', appId],
        ];

  Query<Map<String, dynamic>> _groupQuery(String groupId) {
    if (isSubcollection) return _ref;
    if (groupId.isEmpty) {
      // Safety guard — matches nothing when no group is selected.
      return _ref.where('groupId', isEqualTo: _noActiveGroupSentinel);
    }
    Query<Map<String, dynamic>> q = _ref.where('groupId', isEqualTo: groupId);
    if (filtersByApp) q = q.where('appId', isEqualTo: appId);
    return q;
  }

  /// [query] narrowed to the documents the signed-in user owns:
  /// `ownerIds array-contains <uid>`. Every list of an `ownerScoped`
  /// collection (security/collections.json) must be this shape, or filter
  /// `creatorId == <uid>`: there the rules let a member read only docs they
  /// own, and a query they can't prove is rejected whole. Sharing a doc adds
  /// the sharee to `ownerIds`, so this lists what was shared with them too.
  /// Chain further filters as with [query]. With no signed-in user it
  /// matches nothing.
  Query<Map<String, dynamic>> queryOwned() {
    final uid = _uid;
    _recordList([
      ..._baseFilters,
      ['ownerIds', 'array-contains', RulesContractRecorder.user],
    ]);
    return _groupQuery(_groupId).where('ownerIds',
        arrayContains: uid.isEmpty ? _noActiveGroupSentinel : uid);
  }

  /// [queryInGroup] narrowed to the documents the signed-in user created:
  /// `creatorId == <uid>`, the other list shape the rules prove for an
  /// `ownerScoped` collection. Use it where [queryOwned]'s
  /// `array-contains` is taken by another filter (record search's
  /// `searchPrefixes`; Firestore allows one per query). With no signed-in
  /// user it matches nothing.
  Query<Map<String, dynamic>> queryCreatedInGroup(String groupId) {
    final uid = _uid;
    _recordList([
      ..._baseFilters,
      ['creatorId', '==', RulesContractRecorder.user],
    ]);
    return _groupQuery(groupId).where('creatorId',
        isEqualTo: uid.isEmpty ? _noActiveGroupSentinel : uid);
  }

  /// A [Query] in the active group for the signed-in portal client's copies
  /// of this collection's records: `client_<collection>` (each record's
  /// client-safe projection, same doc id, written only by
  /// functions/_client_links.js), filtered `groupId ==` and
  /// `clientUids array-contains <uid>`. Clients never read the records
  /// themselves; the rules grant the projection's read only while the client
  /// is an admitted guest of this app in the group. Chain further equality
  /// filters freely; an orderBy needs a composite index. Throws
  /// [StateError] when neither this collection nor its `client_` projection
  /// declares a clientReaderListField. With no signed-in user it matches
  /// nothing.
  Query<Map<String, dynamic>> queryAsClient() {
    final field = policy.clientReaderListField;
    if (field == null || field.isEmpty) {
      final projection = 'client_$rootCollection';
      if (_policy == null &&
          (collectionPolicyFor(projection).clientReaderListField ?? '').isNotEmpty) {
        return ScopedCollection(
          collection: projection,
          appId: appId,
          firestore: _firestore,
          currentUid: _currentUid,
        ).queryAsClient();
      }
      throw StateError(
          '"$rootCollection" declares no clientReaderListField, and has no client_ projection, in security/collections.json');
    }
    final uid = _uid;
    _recordList([
      ..._baseFilters,
      [field, 'array-contains', RulesContractRecorder.user],
    ]);
    return _groupQuery(_groupId).where(field,
        arrayContains: uid.isEmpty ? _noActiveGroupSentinel : uid);
  }

  /// A [Query] for the documents [uid] is a named reader of, whatever their
  /// group: `readerField == uid` or `readerListField array-contains uid`
  /// (security/collections.json). The rules grant that read on its own
  /// (a notification's recipient, a marketplace thread's participants), so
  /// chain any further filters (`groupId ==`, `threadId ==`) freely.
  ///
  /// There is no other cross-group read: tenant docs are readable only in
  /// their own group (plans/firestore-rules §2.4, D1), and content other
  /// groups browse is published ([PublicCollection], D2). Throws
  /// [StateError] for a collection that declares no reader field. An empty
  /// [uid] matches nothing.
  Query<Map<String, dynamic>> queryAsReader(String uid) {
    final list = policy.readerListField;
    final single = policy.readerField;
    final value = uid.isEmpty ? _noActiveGroupSentinel : uid;
    if (list != null && list.isNotEmpty) {
      _recordList([
        [list, 'array-contains', RulesContractRecorder.user]
      ]);
      return _ref.where(list, arrayContains: value);
    }
    if (single != null && single.isNotEmpty) {
      _recordList([
        [single, '==', RulesContractRecorder.user]
      ]);
      return _ref.where(single, isEqualTo: value);
    }
    throw StateError(
        '"$rootCollection" declares no readerField/readerListField in security/collections.json');
  }

  /// A [Query] across every group for this app's documents whose
  /// `relatedAppId` is [relatedAppId] — the change requests a steward of
  /// that app may read (see app_stewardship.dart). One equality value per
  /// query so firestore.rules' stewardship branch can prove it; combine
  /// several with `combineLatestUniqueById` rather than a `whereIn`. Writes
  /// still always target the active group via [add]/[set].
  ///
  /// An empty [relatedAppId] matches nothing.
  Query<Map<String, dynamic>> queryForRelatedApp(String relatedAppId) {
    return _ref.where('appId', isEqualTo: appId).where(
          'relatedAppId',
          isEqualTo:
              relatedAppId.isEmpty ? _noActiveGroupSentinel : relatedAppId,
        );
  }

  /// A [Query] across every group for this app's documents — no `groupId`
  /// filter at all. Only the platform-admin read grant (EX-ADMIN-1, an
  /// ACTIVE platform `admin`) can prove a read of this, so gate the UI on
  /// `UserAppEntitlements.isActivePlatformAdmin` before running it; for
  /// anyone else the query is rejected outright. This is the sanctioned
  /// replacement for a raw `FirebaseFirestore.instance.collection()` call in
  /// an admin-only cross-group view (see FIRESTORE_PERMISSIONS.md §6). Writes
  /// still always target the active group via [add]/[set].
  Query<Map<String, dynamic>> queryAcrossAllGroups() {
    return _ref.where('appId', isEqualTo: appId);
  }

  /// A collection-group [Query] over every `name` subcollection under this
  /// collection's documents, filtered to the active group so the rules can
  /// prove it. Matches only subcollection docs that carry `groupId`: ones
  /// written through [sub], or stamped by the M5 backfill.
  Query<Map<String, dynamic>> subcollectionGroup(String name) {
    final gid = _groupId;
    return _db.collectionGroup(name).where(
          'groupId',
          isEqualTo: gid.isEmpty ? _noActiveGroupSentinel : gid,
        );
  }

  /// Returns a [DocumentReference] for the document with [id].
  ///
  /// Use this for reads, updates, and deletes of a known document ID, and
  /// for random ids (no [id]). A natural-key id (a uid, a slug, anything two
  /// groups could both use) goes through [docForKey] instead.
  DocumentReference<Map<String, dynamic>> doc([String? id]) => _ref.doc(id);

  /// The [ScopedCollection] for subcollection [name] of document [parentId].
  ///
  /// Its writes stamp the parent document's `groupId` and `appId` (read
  /// once per [sub] instance; the active group and [appId] if the parent
  /// can't be read or predates them), so subcollection docs carry their own
  /// tenant, as collection-group queries ([subcollectionGroup]) and the
  /// rules need. Its [query] is the subcollection itself (the rules prove
  /// it through the parent).
  ///
  /// Throws [UnsupportedError] on a collection that is itself a [sub]: the
  /// rules reach one subcollection level, so nothing deeper can be read or
  /// written. Keep such docs one level down, tagged with what they belong to
  /// (a recipe photo's comments are `recipes/{id}/photo_comments` with a
  /// `photoId`).
  ScopedCollection sub(String parentId, String name) {
    if (isSubcollection) {
      throw UnsupportedError(
          'ScopedCollection: "$collection/$parentId/$name" is below one '
          'subcollection level, which the rules never reach.');
    }
    return ScopedCollection._sub(this, parentId, name);
  }

  /// [sub] collection [name] of the document at [parent], for shared code
  /// that is handed a document reference rather than the [ScopedCollection]
  /// it came from (a ledger writer, a dialog). [appId] is the app the
  /// writes are attributed to, and the fallback tenant app if the parent
  /// has none.
  static ScopedCollection subOf(
    DocumentReference<Object?> parent,
    String name, {
    required String appId,
    @visibleForTesting FirebaseFirestore? firestore,
    @visibleForTesting String Function()? currentUid,
  }) {
    if (parent.path.split('/').length != 2) {
      throw UnsupportedError(
          'ScopedCollection.subOf: "${parent.path}/$name" is below one '
          'subcollection level, which the rules never reach.');
    }
    return ScopedCollection(
      collection: parent.parent.path,
      appId: appId,
      firestore: firestore,
      currentUid: currentUid,
    ).sub(parent.id, name);
  }

  // ---------------------------------------------------------------------------
  // Natural-key ids
  // ---------------------------------------------------------------------------

  /// The tenant-tagged id for natural [key] in [groupId]:
  /// `{groupId}__{key}`. Idempotent: a key already carrying the prefix is
  /// returned unchanged. Pure, so it can be tested (and mirrored by the
  /// M4 rekey script) without Firebase.
  static String keyedDocId(String groupId, String key) {
    final prefix = '${groupId}__';
    return key.startsWith(prefix) ? key : '$prefix$key';
  }

  /// The natural key a doc id in [groupId] stands for: [keyedDocId]
  /// reversed (an id without the group's tag is returned as is). Pure.
  static String naturalKeyOf(String groupId, String docId) {
    final prefix = '${groupId}__';
    return groupId.isNotEmpty && docId.startsWith(prefix)
        ? docId.substring(prefix.length)
        : docId;
  }

  /// The natural key of doc [docId] in the active group (see
  /// [naturalKeyOf]), e.g. to tell which leaderboard row is the current
  /// user's: `keyOf(doc.id) == uid`.
  String keyOf(String docId) => naturalKeyOf(_groupId, docId);

  /// The [DocumentReference] for natural [key] (a uid, a slug, …) in the
  /// active group: `{groupId}__{key}`, so the same key in two groups is two
  /// docs and no group can squat another's (§3.3, §4.6).
  ///
  /// Throws a [StateError] when no group is active.
  ///
  /// Read with [getForKey]/[watchForKey] and write with
  /// [setForKey]/[updateForKey]/[deleteForKey]. Only the tagged id is ever
  /// read or written: every natural-key doc was rekeyed to it (M4, and the
  /// Commercial Property directory migration; plans/firestore-rules T12).
  DocumentReference<Map<String, dynamic>> docForKey(String key) {
    final gid = _groupId;
    if (gid.isEmpty) {
      throw StateError('ScopedCollection.docForKey($key) needs an active group');
    }
    return _ref.doc(keyedDocId(gid, key));
  }

  /// Reads natural [key]'s (tagged) document. A probe the rules deny (a
  /// missing doc, under the enforced rules) reads as missing, with
  /// [KeyedDocSnapshot.readRefused] set.
  Future<KeyedDocSnapshot> getForKey(String key) async {
    final canonical = docForKey(key);
    _record('get', canonical.path, const []);
    final probe = await _probeExisting(canonical);
    return KeyedDocSnapshot(canonical, probe.data, readRefused: probe.refused);
  }

  /// [getForKey] as a live stream. While the doc doesn't exist it emits a
  /// missing snapshot, and it switches to the doc once
  /// [setForKey]/[updateForKey] create it, including when the rules deny
  /// listening to a doc that doesn't exist yet.
  Stream<KeyedDocSnapshot> watchForKey(String key) {
    final canonical = docForKey(key);
    late final StreamController<KeyedDocSnapshot> controller;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? docSub;
    StreamSubscription<String>? writes;
    var generation = 0;
    var dead = false;

    void emitMissing(int gen) {
      if (gen == generation && !controller.isClosed) {
        controller.add(KeyedDocSnapshot(canonical, null));
      }
    }

    void listen() {
      final gen = ++generation;
      dead = false;
      docSub?.cancel();
      docSub = canonical.snapshots().listen(
        (snap) {
          if (snap.exists) {
            controller.add(KeyedDocSnapshot(canonical, snap.data() ?? {}));
          } else {
            emitMissing(gen);
          }
        },
        onError: (Object e, StackTrace st) {
          if (e is FirebaseException && e.code == 'permission-denied') {
            // Under the enforced rules a doc that doesn't exist yet can't be
            // read: treat it as missing, and listen again once it's written.
            dead = true;
            emitMissing(gen);
          } else {
            controller.addError(e, st);
          }
        },
      );
    }

    controller = StreamController<KeyedDocSnapshot>(
      onListen: () {
        listen();
        writes = _keyedWrites.stream
            .where((path) => path == canonical.path)
            .listen((_) {
          if (dead) listen();
        });
      },
      onCancel: () async {
        generation++;
        await docSub?.cancel();
        await writes?.cancel();
      },
    );
    return controller.stream;
  }

  /// [set] on natural [key]'s tagged doc.
  Future<void> setForKey(String key, Map<String, dynamic> data,
      [SetOptions? options]) async {
    final canonical = docForKey(key);
    final existing = await _existingData(canonical);
    await _setWith(canonical, data, options, existing);
    _keyedWrites.add(canonical.path);
  }

  /// `update()` of natural [key]'s tagged doc. Fails like `update()` if it
  /// doesn't exist.
  Future<void> updateForKey(String key, Map<String, dynamic> data) async {
    final canonical = docForKey(key);
    final payload = {..._withoutIdentity(data, keepOwners: true), ...auditStamp()};
    _record('update', canonical.path, payload.keys);
    await canonical.update(payload);
    _keyedWrites.add(canonical.path);
  }

  /// Deletes natural [key]'s tagged doc. A key with no doc is a no-op (the
  /// enforced rules refuse deleting a doc that doesn't exist).
  Future<void> deleteForKey(String key) async {
    final canonical = docForKey(key);
    if (await _existingData(canonical) != null) {
      _record('delete', canonical.path, const []);
      await canonical.delete();
    }
    _keyedWrites.add(canonical.path);
  }

  /// Paths of tagged docs [setForKey]/[updateForKey] just wrote, so a
  /// [watchForKey] whose listen the rules refused can listen again.
  static final StreamController<String> _keyedWrites =
      StreamController<String>.broadcast(sync: true);

  // ---------------------------------------------------------------------------
  // Write helpers
  // ---------------------------------------------------------------------------

  /// Adds a new document to the collection and returns its [DocumentReference].
  ///
  /// The permission fields in the class doc's table are stamped (and can't be
  /// overridden by the caller, to prevent privilege escalation); any other
  /// fields in [data] are written as-is.
  Future<DocumentReference<Map<String, dynamic>>> add(
      Map<String, dynamic> data) async {
    final stamped = {...await _stamped(data), ...auditStamp()};
    _record('create', '$collection/{id}', stamped.keys);
    return _ref.add(stamped);
  }

  /// Creates the document at [docRef], stamping the permission fields like
  /// [add]. For a document the caller knows is new (a fresh `doc()` id):
  /// unlike [set] it doesn't read first. Writing over an existing document
  /// this way replaces its `creatorId`, which the enforced rules refuse.
  Future<void> create(
      DocumentReference<Map<String, dynamic>> docRef, Map<String, dynamic> data) async {
    final stamped = {...await _stamped(data), ...auditStamp()};
    _record('create', docRef.path, stamped.keys);
    return _db.metering.documentWrite(() => docRef.set(stamped), writes: 1);
  }

  /// Updates the existing document at [docRef] with [data] (a
  /// `DocumentReference.update`), adding [auditStamp]'s fields for an
  /// audited collection. The identity fields aren't sent: the rules never
  /// let an update change them.
  Future<void> update(
      DocumentReference<Map<String, dynamic>> docRef, Map<String, dynamic> data) {
    final payload = {..._withoutIdentity(data, keepOwners: true), ...auditStamp()};
    _record('update', docRef.path, payload.keys);
    return _db.metering.documentWrite(() => docRef.update(payload), writes: 1);
  }

  /// [update] inside a [Transaction].
  void transactionUpdate(
    Transaction transaction,
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data,
  ) {
    final payload = {..._withoutIdentity(data, keepOwners: true), ...auditStamp()};
    _record('update', docRef.path, payload.keys);
    transaction.update(docRef, payload);
  }

  /// A new [WriteBatch] on this collection's metered Firestore, for the
  /// `batch*` helpers. An injected test instance gives a batch on it too.
  WriteBatch batch() => _db.batch();

  /// A delete of [docRef] staged on a [WriteBatch]. Records the delete in the
  /// rules contract like a delete through [doc].
  void batchDelete(WriteBatch batch, DocumentReference<Map<String, dynamic>> docRef) {
    _record('delete', docRef.path, const []);
    batch.delete(docRef);
  }

  /// [update] staged on a [WriteBatch].
  void batchUpdate(
    WriteBatch batch,
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data,
  ) {
    final payload = {..._withoutIdentity(data, keepOwners: true), ...auditStamp()};
    _record('update', docRef.path, payload.keys);
    batch.update(docRef, payload);
  }

  /// The field a soft delete sets. A collection whose table entry sets
  /// `blockDelete` keeps its docs: the app marks one deleted instead, and its
  /// reads leave out the docs [isSoftDeleted] matches. Lock the field
  /// (`creatorOnly`, say) in the table to say who may delete and restore.
  static const softDeleteField = 'deletedAt';

  /// Whether a document's [data] has been soft-deleted. A document that is
  /// gone (null data) counts as deleted too.
  static bool isSoftDeleted(Map<String, dynamic>? data) =>
      data == null || data[softDeleteField] != null;

  /// Marks the document at [docRef] deleted (an [update], so an audited
  /// collection's audit trail records who did it and when).
  Future<void> softDelete(DocumentReference<Map<String, dynamic>> docRef) =>
      update(docRef, {softDeleteField: FieldValue.serverTimestamp()});

  /// [softDelete] staged on a [WriteBatch].
  void batchSoftDelete(
          WriteBatch batch, DocumentReference<Map<String, dynamic>> docRef) =>
      batchUpdate(batch, docRef, {softDeleteField: FieldValue.serverTimestamp()});

  /// [data] with the permission fields [permissionFields] describes, for the
  /// current user and the tenant: the active group, or for a [sub]
  /// collection the parent document's group and app.
  Future<Map<String, dynamic>> _stamped(Map<String, dynamic> data) async {
    final (groupId, docAppId) = await _tenant();
    _checkOwningApp(docAppId);
    return permissionFields(data, creatorId: _uid, groupId: groupId, appId: docAppId);
  }

  /// [_stamped] for synchronous callers ([batchSet]): a [sub] collection
  /// uses its parent's tenant if it has been read already.
  Map<String, dynamic> _stampedSync(Map<String, dynamic> data) {
    final (groupId, docAppId) = _parentTenant ?? (_groupId, appId);
    _checkOwningApp(docAppId);
    return permissionFields(data, creatorId: _uid, groupId: groupId, appId: docAppId);
  }

  (String, String)? _parentTenant;

  /// Reads (and caches) the `(groupId, appId)` this collection's creates
  /// carry: for a [sub] collection, its parent document's tenant. A
  /// [batchSet] can't read, so it uses the parent's tenant only once it has
  /// been read: await this before staging [batchSet]s on a [sub] collection
  /// whose parent may belong to another app (e.g. a staff tool writing a
  /// multi-app parent's `edit_history`). A no-op read for a top-level one.
  Future<(String, String)> resolveTenant() => _tenant();

  /// `(groupId, appId)` new documents carry.
  Future<(String, String)> _tenant() async {
    final parentPath = _parentPath;
    if (parentPath == null) return (_groupId, appId);
    final cached = _parentTenant;
    if (cached != null) return cached;
    final parent = await _existingData(_db.doc(parentPath));
    final groupId = parent?['groupId'];
    final parentAppId = parent?['appId'];
    final tenant = (
      groupId is String && groupId.isNotEmpty ? groupId : _groupId,
      parentAppId is String && parentAppId.isNotEmpty ? parentAppId : appId,
    );
    // Only cache a tenant read from the parent; the fallback may change.
    if (groupId is String && groupId.isNotEmpty) _parentTenant = tenant;
    return tenant;
  }

  static final Set<String> _warnedApps = {};

  /// Debug-only: a create tagged with an app the table doesn't list as an
  /// owner of the collection is refused by the enforced rules (provenance).
  void _checkOwningApp(String docAppId) {
    assert(() {
      final apps = policy.apps;
      if (apps.isNotEmpty &&
          !apps.contains(docAppId) &&
          _warnedApps.add('$rootCollection:$docAppId')) {
        debugPrint(
          'ScopedCollection: creating a "$rootCollection" doc with appId "$docAppId", '
          'which security/collections.json does not list as an owner ($apps).',
        );
      }
      return true;
    }());
  }

  /// [data] with the permission fields every create carries: `groupId`,
  /// `appId` and `creatorId` always overwrite whatever the caller passed (so
  /// they can't be spoofed), and `ownerIds` defaults to `[creatorId]` unless
  /// the caller provided one. Pure, so the contract can be tested without
  /// Firebase (like [ScopedStorage.permissionMetadata]).
  static Map<String, dynamic> permissionFields(
    Map<String, dynamic> data, {
    required String creatorId,
    required String groupId,
    required String appId,
  }) =>
      {
        ...data,
        // Always overwrite permission fields to prevent spoofing.
        'groupId': groupId,
        'appId': appId,
        'creatorId': creatorId,
        'ownerIds':
            (data['ownerIds'] as List?)?.cast<String>() ?? [creatorId],
      };

  /// What a [set] of [data] sends, given the document's [existing] data
  /// (null: it doesn't exist, so this is a create). Pure.
  ///
  /// - Create: [permissionFields].
  /// - Update: `groupId`, `appId` and `creatorId` are never sent from
  ///   [data] (the enforced rules refuse any change to them); `ownerIds` is
  ///   sent only if the caller gave it (sharing). A full (non-merge) set
  ///   carries the existing values over, so replacing a document's content
  ///   doesn't strip its tenant. A doc missing `groupId`/`appId` gets the
  ///   current ones.
  static Map<String, dynamic> fieldsForWrite(
    Map<String, dynamic> data, {
    required Map<String, dynamic>? existing,
    required bool merge,
    required String creatorId,
    required String groupId,
    required String appId,
  }) {
    if (existing == null) {
      return permissionFields(data,
          creatorId: creatorId, groupId: groupId, appId: appId);
    }
    final out = _withoutIdentity(data, keepOwners: true);
    if (!merge) {
      for (final field in identityFields) {
        if (!out.containsKey(field) && existing.containsKey(field)) {
          out[field] = existing[field];
        }
      }
    }
    // A legacy doc with no tenant (M1 backfills these) gets one, as the
    // old stamping did. That adds, never changes, so it is no rewrite; the
    // enforced rules can't read such a doc anyway. creatorId/ownerIds are
    // never filled in: that would hand the editor ownership.
    if (_isBlank(existing['groupId']) && groupId.isNotEmpty) out['groupId'] = groupId;
    if (_isBlank(existing['appId'])) out['appId'] = appId;
    return out;
  }

  static bool _isBlank(Object? value) => value is! String || value.isEmpty;

  static Map<String, dynamic> _withoutIdentity(Map<String, dynamic> data,
          {required bool keepOwners}) =>
      {
        for (final e in data.entries)
          if (!identityFields.contains(e.key) ||
              (keepOwners && e.key == 'ownerIds'))
            e.key: e.value,
      };

  /// Stages a create of [docRef] inside an existing [WriteBatch], with the
  /// same stamped permission fields as [add].
  ///
  /// Exists so a scoped create can be made atomic with another write — e.g.
  /// appending a message and bumping its parent thread's summary in one
  /// commit — without callers hand-rolling the `groupId`/`appId`/`creatorId`/
  /// `ownerIds` map themselves. A hand-rolled copy is how those fields drift
  /// out of sync with this wrapper, which is the whole failure mode
  /// [ScopedCollection] exists to prevent.
  ///
  /// A batch can't read, so this always stamps: use it for documents the
  /// caller knows are new, and `batch.update` for existing ones. (Stamping
  /// an existing document's `creatorId` is refused by the enforced rules.)
  void batchSet(
    WriteBatch batch,
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) {
    final stamped = {..._stampedSync(data), ...auditStamp()};
    _record('create', docRef.path, stamped.keys);
    batch.set(docRef, stamped, _withIdentityMergeFields(options));
  }

  /// [batchSet] inside a [Transaction]: stages a create of [docRef] with
  /// the stamped permission fields, for a get-then-create the transaction
  /// makes atomic (it read [docRef] as missing). Like [batchSet] it always
  /// stamps; use `transaction.update` for an existing document.
  void transactionSet(
    Transaction transaction,
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) {
    final stamped = {..._stampedSync(data), ...auditStamp()};
    _record('create', docRef.path, stamped.keys);
    transaction.set(docRef, stamped, _withIdentityMergeFields(options));
  }

  /// Creates or updates the document at [docRef].
  ///
  /// Reads the document first: if it doesn't exist (or the rules won't say,
  /// which the enforced rules do for a missing doc), the permission fields
  /// are stamped as for [add]; if it does, they are left as they are (see
  /// [fieldsForWrite]). Pass [options] (e.g. `SetOptions(merge: true)`) to
  /// control merge behaviour. Use [create] to skip the read for a document
  /// known to be new.
  Future<void> set(
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data, [
    SetOptions? options,
  ]) async {
    final existing = await _existingData(docRef);
    await _setWith(docRef, data, options, existing);
  }

  Future<void> _setWith(
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data,
    SetOptions? options,
    Map<String, dynamic>? existing,
  ) async {
    final merge = options != null && (options.merge == true || options.mergeFields != null);
    final Map<String, dynamic> payload;
    if (existing == null) {
      payload = await _stamped(data);
    } else {
      payload = fieldsForWrite(data,
          existing: existing, merge: merge, creatorId: _uid, groupId: _groupId, appId: appId);
    }
    final opts = existing == null ? _withIdentityMergeFields(options) : options;
    final stamped = {...payload, ...auditStamp()};
    _record(existing == null ? 'create' : 'update', docRef.path, stamped.keys);
    // Billed to this collection's app whatever the reference came from: by
    // the platform layer if it meters the write, else by the gateway here.
    return _db.metering.documentWrite(() => docRef.set(stamped, _withAuditMergeFields(opts)), writes: 1);
  }

  /// [options] with [auditStamp]'s fields added to its `mergeFields`, so a
  /// `mergeFields` write still stamps them.
  SetOptions? _withAuditMergeFields(SetOptions? options) {
    final fields = options?.mergeFields;
    if (fields == null || !isAudited) return options;
    return SetOptions(mergeFields: [
      ...fields,
      for (final f in auditStamp().keys)
        if (!fields.contains(FieldPath([f]))) f,
    ]);
  }

  /// [options] with the identity fields added to its `mergeFields`, so a
  /// create through `mergeFields` still writes them.
  static SetOptions? _withIdentityMergeFields(SetOptions? options) {
    final fields = options?.mergeFields;
    if (fields == null) return options;
    return SetOptions(mergeFields: [
      ...fields,
      for (final f in identityFields)
        if (!fields.contains(FieldPath([f]))) f,
    ]);
  }

  /// The document's data, or null if it doesn't exist — or if the read is
  /// refused (the enforced rules refuse reading a missing doc) or can't
  /// reach the server with nothing cached.
  Future<Map<String, dynamic>?> _existingData(
          DocumentReference<Map<String, dynamic>> ref) async =>
      (await _probeExisting(ref)).data;

  /// [ref]'s data (null when missing, refused or unavailable), and whether
  /// the rules refused the read.
  Future<({Map<String, dynamic>? data, bool refused})> _probeExisting(
      DocumentReference<Map<String, dynamic>> ref) async {
    try {
      final snap = await FirestoreAttribution.runAs(_db.metering, () => ref.get());
      return (data: snap.exists ? (snap.data() ?? <String, dynamic>{}) : null, refused: false);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return (data: null, refused: true);
      if (e.code == 'unavailable') return (data: null, refused: false);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Contracts (plans/firestore-rules §6.3)
  // ---------------------------------------------------------------------------

  void _recordList(List<List<Object?>> filters) =>
      _record('list', collection, const [], filters: filters);

  void _record(String op, String path, Iterable<String> writeKeys,
      {List<List<Object?>> filters = const []}) {
    if (!RulesContractRecorder.isRecording) return;
    RulesContractRecorder.record(
      app: appId,
      op: op,
      path: _contractPath(path),
      filters: filters,
      writeKeys: writeKeys,
    );
  }

  /// [path] with document ids replaced by `{id}`.
  static String _contractPath(String path) {
    final parts = path.split('/');
    return [
      for (var i = 0; i < parts.length; i++) i.isOdd ? '{id}' : parts[i],
    ].join('/');
  }
}

/// A natural-key document read through [ScopedCollection.getForKey] /
/// [ScopedCollection.watchForKey].
class KeyedDocSnapshot {
  const KeyedDocSnapshot(this.reference, this.data, {this.readRefused = false});

  /// The tenant-tagged document.
  final DocumentReference<Map<String, dynamic>> reference;

  /// The document's data; null when it doesn't exist.
  final Map<String, dynamic>? data;

  /// Whether the rules refused the read, so [exists] is false without the
  /// caller knowing whether the document is there.
  final bool readRefused;

  bool get exists => data != null;
}
