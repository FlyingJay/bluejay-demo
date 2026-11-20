import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'active_group_service.dart';
import 'bluejay_firestore.dart';
import 'usage_meter.dart';

/// One entry of the group member directory, `group_members/{groupId}__{uid}`
/// (functions/_group_members.js; rules plan T9).
///
/// This is what one member may see about another: who they are (email,
/// display name, picture), their role in the group and whether the account
/// is active. It replaces reading another user's `users/{uid}` doc, which
/// holds private fields and (stage 2 of the rules rollout) only its owner may
/// read.
class GroupMember {
  const GroupMember({
    required this.groupId,
    required this.uid,
    this.role = 'member',
    this.email = '',
    this.displayName = '',
    this.photoURL = '',
    this.status = 'ACTIVE',
    this.isGuest = false,
    this.guestName = '',
    this.guestEmail = '',
    this.joinedAt,
    this.lastActiveAt,
  });

  factory GroupMember.fromMap(Map<String, dynamic> data) {
    String s(Object? v) => v is String ? v.trim() : '';
    return GroupMember(
      groupId: s(data['groupId']),
      uid: s(data['uid']),
      role: s(data['role']).isEmpty ? 'member' : s(data['role']),
      email: s(data['email']).toLowerCase(),
      displayName: s(data['displayName']),
      photoURL: s(data['photoURL']),
      status: s(data['status']).isEmpty ? 'ACTIVE' : s(data['status']).toUpperCase(),
      // A guest membership (a claimed visitor or a portal client, whose
      // users.isGuest is false) is a guest too.
      isGuest: data['isGuest'] == true || s(data['role']) == 'guest',
      guestName: s(data['guestName']),
      guestEmail: s(data['guestEmail']),
      joinedAt: data['joinedAt'] is Timestamp ? data['joinedAt'] as Timestamp : null,
      lastActiveAt:
          data['lastActiveAt'] is Timestamp ? data['lastActiveAt'] as Timestamp : null,
    );
  }

  final String groupId;
  final String uid;

  /// The membership role: `member`, `editor`, `owner` or `guest`.
  final String role;

  /// Lower-cased sign-in email ('' when unknown).
  final String email;
  final String displayName;

  /// Profile picture URL ('' when none).
  final String photoURL;

  /// `ACTIVE`, or the deactivated status.
  final String status;
  final bool isGuest;
  final String guestName;
  final String guestEmail;

  /// When the membership was created (null on legacy memberships).
  final Timestamp? joinedAt;

  /// The user's last activity, to the hour.
  final Timestamp? lastActiveAt;

  /// The email's local part, the username shown across the launcher.
  String get username => email.contains('@') ? email.split('@').first : email;

  /// The best name to show: display name, then guest name, then username.
  String get label {
    if (displayName.isNotEmpty) return displayName;
    if (isGuest && guestName.isNotEmpty) return guestName;
    if (username.isNotEmpty) return username;
    if (isGuest && guestEmail.isNotEmpty) return guestEmail;
    return 'User';
  }

  /// Whether a people search for [term] finds this member: by display name
  /// (or guest name), or by email. A term with '@' matches anywhere in the
  /// email; any other term matches the local part only, so "jay" doesn't
  /// find everyone on @bluejay.gg.
  bool matchesSearch(String term) {
    final t = term.trim().toLowerCase();
    if (t.isEmpty) return true;
    if (label.toLowerCase().contains(t)) return true;
    if (displayName.toLowerCase().contains(t)) return true;
    return t.contains('@') ? email.contains(t) : username.contains(t);
  }

  bool get isInactive => status != 'ACTIVE';

  /// The fields the old `users/{uid}` reads used, under their old names
  /// (`profilePictureUrl`, `createdAt`, `lastActive`), for code that still
  /// passes a user map around.
  Map<String, dynamic> toUserData() => {
        'uid': uid,
        'email': email,
        'displayName': displayName,
        'profilePictureUrl': photoURL.isEmpty ? null : photoURL,
        'status': status,
        'isGuest': isGuest,
        if (guestName.isNotEmpty) 'guestName': guestName,
        if (guestEmail.isNotEmpty) 'guestEmail': guestEmail,
        'createdAt': joinedAt,
        'lastActive': lastActiveAt,
        'role': role,
      };

  @override
  bool operator ==(Object other) =>
      other is GroupMember && other.groupId == groupId && other.uid == uid;

  @override
  int get hashCode => Object.hash(groupId, uid);

  @override
  String toString() => 'GroupMember($groupId/$uid $label)';
}

/// Reads the group member directory: the only way client code looks up
/// another user's name, email or picture.
///
/// Every lookup is scoped to one group (the active group unless a
/// `groupId` is given, e.g. a game doc's own group), so it only ever finds
/// people who share that group with the caller — which is exactly what
/// firestore.rules allows (members read their group's directory). Reading
/// `users/{uid}` for anyone but the signed-in user is not allowed.
///
/// Results are cached per group for [cacheTtl]; [watchGroup] streams live
/// updates and refreshes the cache as it goes.
class GroupMemberDirectory {
  GroupMemberDirectory({FirebaseFirestore? firestore, this.cacheTtl = const Duration(minutes: 5)})
      : _firestore = firestore;

  /// Shared instance; reads are attributed to the app currently on top
  /// (UsageMeter), or the launcher.
  static GroupMemberDirectory instance = GroupMemberDirectory();

  static const String collection = 'group_members';

  /// `{groupId}__{uid}`, as functions/_group_members.js writes it.
  static String docId(String groupId, String uid) => '${groupId}__$uid';

  final FirebaseFirestore? _firestore;
  final Duration cacheTtl;
  final Map<String, _GroupCache> _groups = {};

  FirebaseFirestore get _db =>
      _firestore ??
      BluejayFirestore.forApp(UsageMeter.instance.currentAppId ?? launcherAppId);

  CollectionReference<Map<String, dynamic>> get _col => _db.collection(collection);

  /// [groupId], or the active group when null/empty. Null when neither.
  static String? resolveGroupId(String? groupId) {
    final g = (groupId ?? '').trim();
    if (g.isNotEmpty) return g;
    final active = (ActiveGroupService.instance.activeGroupId ?? '').trim();
    return active.isEmpty ? null : active;
  }

  _GroupCache _cache(String groupId) => _groups.putIfAbsent(groupId, () => _GroupCache());

  bool _fresh(_GroupCache c) =>
      c.loadedAt != null && DateTime.now().difference(c.loadedAt!) < cacheTtl;

  /// Every member of [groupId] (default: the active group), sorted by label.
  Future<List<GroupMember>> group([String? groupId]) async {
    final g = resolveGroupId(groupId);
    if (g == null) return const [];
    final c = _cache(g);
    if (c.complete && _fresh(c)) return c.sorted();
    final pending = c.loading;
    if (pending != null) return pending;
    final future = _col.where('groupId', isEqualTo: g).get().then((snap) {
      c.replaceAll(snap.docs.map((d) => GroupMember.fromMap(d.data())));
      return c.sorted();
    }).whenComplete(() => c.loading = null);
    c.loading = future;
    return future;
  }

  /// Live list of [groupId]'s members (default: the active group), sorted by
  /// label. Keeps the cache current while listened to.
  Stream<List<GroupMember>> watchGroup([String? groupId]) {
    final g = resolveGroupId(groupId);
    if (g == null) return Stream.value(const []);
    final c = _cache(g);
    return _col.where('groupId', isEqualTo: g).snapshots().map((snap) {
      c.replaceAll(snap.docs.map((d) => GroupMember.fromMap(d.data())));
      return c.sorted();
    });
  }

  /// Live map uid → member for just [uids] in [groupId].
  Stream<Map<String, GroupMember>> watchMembers(Iterable<String> uids, {String? groupId}) {
    final wanted = uids.toSet();
    return watchGroup(groupId).map((all) => {
          for (final m in all)
            if (wanted.contains(m.uid)) m.uid: m,
        });
  }

  /// One member of [groupId] (default: the active group), or null when they
  /// aren't in it (or there's no group).
  Future<GroupMember?> member(String uid, {String? groupId}) async {
    final found = await members([uid], groupId: groupId);
    return found[uid];
  }

  /// uid → member for each of [uids] that belongs to [groupId] (default: the
  /// active group). Missing uids are simply absent.
  ///
  /// A cold cache loads the whole group once through [group], which shares
  /// one in-flight query between concurrent callers. A list of rows that
  /// each look up their author therefore costs one query per group, and a
  /// uid that isn't in the group is known to be missing until the cache
  /// expires, so remounting its row doesn't query again.
  Future<Map<String, GroupMember>> members(Iterable<String> uids, {String? groupId}) async {
    final g = resolveGroupId(groupId);
    final wanted = uids.map((u) => u.trim()).where((u) => u.isNotEmpty).toSet();
    if (g == null || wanted.isEmpty) return {};
    final c = _cache(g);
    if (!(c.complete && _fresh(c))) await group(g);
    return {
      for (final uid in wanted)
        if (c.byUid[uid] != null) uid: c.byUid[uid]!,
    };
  }

  /// The member of [groupId] (default: the active group) with this sign-in
  /// email, or null.
  Future<GroupMember?> findByEmail(String email, {String? groupId}) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty) return null;
    for (final m in await group(groupId)) {
      if (m.email == e) return m;
    }
    return null;
  }

  /// The display label for [uid] in [groupId], or [fallback] when unknown.
  Future<String> labelFor(String uid, {String? groupId, String fallback = 'Unknown'}) async {
    final m = await member(uid, groupId: groupId);
    return m?.label ?? fallback;
  }

  /// The cached member of [groupId] (default: the active group) with this
  /// [uid] or, failing that, this sign-in [email]; null when it isn't cached.
  /// Never queries, so a widget can render it on its first frame.
  GroupMember? cachedMember({String? uid, String? email, String? groupId}) {
    final g = resolveGroupId(groupId);
    if (g == null) return null;
    final c = _groups[g];
    if (c == null) return null;
    final u = (uid ?? '').trim();
    if (u.isNotEmpty && c.byUid[u] != null) return c.byUid[u];
    final e = (email ?? '').trim().toLowerCase();
    if (e.isEmpty) return null;
    for (final m in c.byUid.values) {
      if (m.email == e) return m;
    }
    return null;
  }

  /// The member of [groupId] (default: the active group) with this [uid],
  /// or with this sign-in [email] when the uid is unknown or not in the
  /// group. Apps that stored only an email (older chat, album and recipe
  /// docs) resolve through the email.
  Future<GroupMember?> resolve({String? uid, String? email, String? groupId}) async {
    final u = (uid ?? '').trim();
    if (u.isNotEmpty) {
      final m = await member(u, groupId: groupId);
      if (m != null) return m;
    }
    final e = (email ?? '').trim();
    if (e.isEmpty) return null;
    return findByEmail(e, groupId: groupId);
  }

  /// Puts [members] in [groupId]'s cache as a complete, fresh listing.
  @visibleForTesting
  void primeCache(String groupId, Iterable<GroupMember> members) =>
      _cache(groupId).replaceAll(members);

  /// Drops cached entries (all groups, or just [groupId]).
  void clearCache([String? groupId]) {
    if (groupId == null) {
      _groups.clear();
    } else {
      _groups.remove(groupId);
    }
  }
}

class _GroupCache {
  final Map<String, GroupMember> byUid = {};
  DateTime? loadedAt;
  bool complete = false;
  Future<List<GroupMember>>? loading;

  void replaceAll(Iterable<GroupMember> members) {
    byUid
      ..clear()
      ..addEntries(members.map((m) => MapEntry(m.uid, m)));
    complete = true;
    loadedAt = DateTime.now();
  }

  List<GroupMember> sorted() => byUid.values.toList()
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
}
