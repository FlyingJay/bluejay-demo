import 'package:cloud_firestore/cloud_firestore.dart';

import 'access_index_cache.dart';
import 'bluejay_firestore.dart';

export 'access_index_builder.dart';
export 'access_index_cache.dart' show AccessIndexSnapshot;

/// The one place client code reads a user's access index,
/// `users/{uid}/metadata/access_index`: the platform roles, `status`,
/// per-`{groupId}:{appId}` entitlements and `denied_scopes` every
/// firestore.rules check reads. Only the server writes it
/// (rebuildUserAccessIndex in functions/_shared.js; `metadata` is
/// `serverWritten` in security/collections.json), and only its owner reads
/// it, so pass the signed-in user's uid.
///
/// These are the raw document reads, for code that inspects the snapshot
/// itself (`exists`, a per-app `fromData` parser, a StreamBuilder's
/// connection state). For a typed, fail-closed view use
/// [UserAppEntitlements.load] / [UserAppEntitlements.watch]
/// (user_app_entitlements.dart), which read through here.
///
/// [get], [snapshots], [loadData] and [watchData] for the signed-in user
/// are served by one shared, app-wide listener ([AccessIndexCache]): [get]
/// is immediate once it has a server-confirmed value, and [snapshots] /
/// [watchData] return the same stream instance on every call, which hands
/// each new subscriber the latest value first. Safe to call from `build()`.
/// [current] is the latest value, synchronously.
///
/// [appId] is the app a read is attributed to for Usage Meter (a package's
/// `APP_ID`, [launcherAppId] for the host shell, [platformAppId] for shared
/// services) when it bypasses the shared listener: a [firestore] override
/// (tests), or a uid other than the signed-in user's. The shared listener's
/// reads are attributed to [platformAppId] (see [AccessIndexCache]). Errors
/// are not swallowed: a failed read throws / the stream errors, exactly as
/// the plain Firestore call would.
class AccessIndex {
  AccessIndex._();

  /// The index's document id within `users/{uid}/metadata`.
  static const String docId = 'access_index';

  /// The reference to [uid]'s access index. [uid] must be non-empty.
  static DocumentReference<Map<String, dynamic>> ref(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      BluejayFirestore.forApp(appId, firestore: firestore)
          .collection('users')
          .doc(uid)
          // gateway-exempt: raw-collection AccessIndex is the shared read gateway for the caller's own access index
          .collection('metadata')
          .doc(docId);

  static AccessIndexListener? _shared(String uid, FirebaseFirestore? firestore) =>
      firestore == null ? AccessIndexCache.forUid(uid) : null;

  /// [uid]'s access index, server-confirmed (see the class doc).
  static Future<DocumentSnapshot<Map<String, dynamic>>> get(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _shared(uid, firestore)?.get() ?? ref(uid, appId: appId, firestore: firestore).get();

  /// [uid]'s access index as it changes (a role grant or an installed app
  /// propagating).
  static Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _shared(uid, firestore)?.snapshots ?? ref(uid, appId: appId, firestore: firestore).snapshots();

  /// The signed-in user's latest access index snapshot: the value
  /// [snapshots] hands a new subscriber first. Null before the shared
  /// listener has one, while it is in an error state, for any other uid, and
  /// with a [firestore] override (which bypasses the shared listener).
  /// [AccessIndexBuilder] uses it as `initialData` to skip the waiting frame;
  /// a StreamBuilder over a stored [snapshots] stream can do the same through
  /// [PrimedStreamBuilder].
  static DocumentSnapshot<Map<String, dynamic>>? current(String uid, {FirebaseFirestore? firestore}) =>
      _shared(uid, firestore)?.current;

  /// [current] parsed by [parse]: the value [watch] with the same [parse]
  /// hands a new subscriber first, or null when [current] is null.
  static T? currentAs<T>(
    String uid, {
    required T Function(Map<String, dynamic>? data) parse,
    FirebaseFirestore? firestore,
  }) {
    final snap = current(uid, firestore: firestore);
    return snap == null ? null : parse(snap.data());
  }

  /// [uid]'s access index data (null when the doc doesn't exist).
  static Future<Map<String, dynamic>?> loadData(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) async =>
      (await get(uid, appId: appId, firestore: firestore)).data();

  /// [snapshots] mapped to the doc's data (null while it doesn't exist).
  static Stream<Map<String, dynamic>?> watchData(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _shared(uid, firestore)?.data ??
      snapshots(uid, appId: appId, firestore: firestore).map((snap) => snap.data());

  static final Expando<Expando<Stream<Object?>>> _parsed = Expando('AccessIndex.watch');

  /// [watchData] parsed by [parse], e.g. a screen's own `fromData` access
  /// view. For the signed-in user every call with the same [parse] returns
  /// the same stream instance, so it is safe to call from `build()`; pass a
  /// static function or constructor tear-off (`MyAccess.fromData`), since a
  /// closure is a new function, and so a new stream, on every call.
  static Stream<T> watch<T>(
    String uid, {
    required String appId,
    required T Function(Map<String, dynamic>? data) parse,
    FirebaseFirestore? firestore,
  }) {
    final shared = _shared(uid, firestore);
    if (shared == null) {
      return snapshots(uid, appId: appId, firestore: firestore).map((snap) => parse(snap.data()));
    }
    final byParser = _parsed[shared] ??= Expando<Stream<Object?>>();
    return (byParser[parse] ??= shared.data.map<T>(parse)) as Stream<T>;
  }
}
