import 'package:cloud_firestore/cloud_firestore.dart';

import 'bluejay_firestore.dart';

/// Read access to the root `groups` collection: the group docs themselves
/// (name, logo, branding, `memberIds`, `adminIds`, `installedApps`, …).
///
/// `groups` is a tenant collection in security/collections.json, but not
/// one an app's `ScopedCollection` owns: it is the tenant registry itself.
/// Group docs are server-written (`serverWritten` in
/// security/collections.json): every change goes through a callable —
/// the group_membership.js ones (createGroup, setGroup*, updateGroupDetails,
/// setGroupDefaultHomeScreenApps, …), setGroupInstalledApps and
/// adminDeleteGroup — so this class only reads. Each query here has the shape a
/// firestore.rules grant can prove:
///
/// - [ref] / [get] / [snapshots] by id (a group's doc id is its `groupId`):
///   any member, guests included, through `memberIds`; platform admins and
///   developers for any group.
/// - [ofMember]: the groups a user belongs to (`memberIds` array-contains,
///   the collection's `readerListField`).
/// - [withGroupIdField]: `groupId ==` — the member-directory read
///   (`memberRead`, non-guest members).
/// - [withInstalledApp] and [all]: cross-group listings, which only
///   platform admins (EX-ADMIN-1) and developers (`developerRead`) can run.
///
/// [appId] is the app the read is attributed to for Usage Meter (a
/// package's `APP_ID`, or [launcherAppId] for the host shell). [firestore]
/// overrides the underlying instance (tests).
class GroupDocs {
  GroupDocs._();

  /// [appId]'s metered Firestore. Its `scopedCollection` skips the debug
  /// raw-collection check (MeteredFirestore.rawCollectionCheck): this class
  /// is the sanctioned gateway to `groups`/`memberships`, like
  /// `ScopedCollection` for app data (check_gateways `gateway-collection`).
  static MeteredFirestore _db(String appId, FirebaseFirestore? firestore) =>
      BluejayFirestore.forApp(appId, firestore: firestore) as MeteredFirestore;

  static CollectionReference<Map<String, dynamic>> _groups(String appId, FirebaseFirestore? firestore) =>
      _db(appId, firestore).scopedCollection('groups');

  /// The group doc for [groupId].
  static DocumentReference<Map<String, dynamic>> ref(
    String groupId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _groups(appId, firestore).doc(groupId);

  /// One read of the group doc for [groupId].
  static Future<DocumentSnapshot<Map<String, dynamic>>> get(
    String groupId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      ref(groupId, appId: appId, firestore: firestore).get();

  /// The group doc for [groupId] as it changes.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots(
    String groupId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      ref(groupId, appId: appId, firestore: firestore).snapshots();

  /// The groups [uid] is a member of (`memberIds` array-contains [uid]).
  /// Chain `.snapshots()` / `.get()`.
  static Query<Map<String, dynamic>> ofMember(
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _groups(appId, firestore).where('memberIds', arrayContains: uid);

  /// Group docs whose `groupId` field is [groupId] (in practice the one
  /// group with that id). Chain `.limit(1)` and any further filters.
  static Query<Map<String, dynamic>> withGroupIdField(
    String groupId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _groups(appId, firestore).where('groupId', isEqualTo: groupId);

  /// Every group with [installedAppId] in `installedApps` (platform admins
  /// and developers only). Chain `.count()` for an install count.
  static Query<Map<String, dynamic>> withInstalledApp(
    String installedAppId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _groups(appId, firestore).where('installedApps', arrayContains: installedAppId);

  /// Every group (platform admins and developers only): admin consoles and
  /// pickers. Chain `.orderBy()`, `.where()`, `.count()` as needed.
  static Query<Map<String, dynamic>> all({
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _groups(appId, firestore);
}

/// Read access to the root `memberships` collection: one doc per
/// `{groupId}_{uid}` recording a member's existence and `role`.
///
/// Server-written (`serverWritten` in security/collections.json: only the
/// group_membership.js callables, adminDeleteGroup and guest_users.js write
/// it), so this class only reads. Members read their group's memberships
/// (`memberRead`, [ofGroup]), each user their own ([ref] with their uid,
/// the `readerField`), platform admins all of them ([all]).
///
/// [appId] and [firestore] are as for [GroupDocs].
class MembershipDocs {
  MembershipDocs._();

  /// The membership doc id of [uid] in [groupId].
  static String docId(String groupId, String uid) => '${groupId}_$uid';

  static CollectionReference<Map<String, dynamic>> _memberships(String appId, FirebaseFirestore? firestore) =>
      GroupDocs._db(appId, firestore).scopedCollection('memberships');

  /// [uid]'s membership doc in [groupId].
  static DocumentReference<Map<String, dynamic>> ref(
    String groupId,
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _memberships(appId, firestore).doc(docId(groupId, uid));

  /// One read of [uid]'s membership doc in [groupId].
  static Future<DocumentSnapshot<Map<String, dynamic>>> get(
    String groupId,
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      ref(groupId, uid, appId: appId, firestore: firestore).get();

  /// [uid]'s membership doc in [groupId] as it changes.
  static Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots(
    String groupId,
    String uid, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      ref(groupId, uid, appId: appId, firestore: firestore).snapshots();

  /// Every membership in [groupId].
  static Query<Map<String, dynamic>> ofGroup(
    String groupId, {
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _memberships(appId, firestore).where('groupId', isEqualTo: groupId);

  /// Every membership in every group (platform admins only).
  static Query<Map<String, dynamic>> all({
    required String appId,
    FirebaseFirestore? firestore,
  }) =>
      _memberships(appId, firestore);
}

/// The name a group goes by outside itself: its optional `legalName` when
/// there is one, else its group `name`, else [fallback] (often the groupId).
/// Generated documents, emails sent on the group's behalf and pages a client,
/// guest or the public opens use this; members' own navigation (the group
/// switcher, pickers, admin consoles) keeps the group name. Mirrors
/// groupDocumentName in functions/_group_identity.js.
String groupDocumentName(Map<String, dynamic>? group, {String fallback = ''}) {
  String text(Object? value) => value is String ? value.trim() : '';
  final g = group ?? const <String, dynamic>{};
  final legal = text(g['legalName']);
  if (legal.isNotEmpty) return legal;
  final name = text(g['name']);
  return name.isNotEmpty ? name : fallback;
}
