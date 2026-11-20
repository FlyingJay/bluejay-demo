import 'package:firebase_auth/firebase_auth.dart' as fire_auth;

import 'group_member_directory.dart';

/// What an app shows for a person: a name, a picture and initials.
///
/// Every app that names a group member goes through this (and the
/// `MemberName` / `MemberAvatar` widgets in shared_ui) so a member reads as
/// "Priya Nair" everywhere, the same way, instead of each app turning an
/// email into "demo-priya" or "Demo Priya" on its own.
///
/// The name comes from the group member directory (`group_members`, which
/// every member of the group may read). When the person isn't in the
/// directory (they left the group, or the doc predates it), it falls back to
/// a name the document stored, then the email's local part, then [unknown].
class MemberIdentity {
  const MemberIdentity({required this.label, this.photoUrl = '', this.member});

  /// From a directory entry.
  factory MemberIdentity.fromMember(GroupMember member) =>
      MemberIdentity(label: member.label, photoUrl: member.photoURL, member: member);

  /// For someone the directory doesn't know: a stored [name], then the
  /// [email]'s local part, then [unknown].
  factory MemberIdentity.fallback({String? name, String? email, String unknown = 'Unknown'}) =>
      MemberIdentity(label: fallbackLabel(name: name, email: email, unknown: unknown));

  /// The display name to show.
  final String label;

  /// Profile picture URL, '' when none.
  final String photoUrl;

  /// The directory entry this came from, or null for a fallback.
  final GroupMember? member;

  /// Whether the directory knew this person.
  bool get isResolved => member != null;

  bool get hasPhoto => photoUrl.isNotEmpty;

  /// Up to two letters: the first letters of the first and last words
  /// ("Priya Nair" -> "PN"), or the first letter of a single word.
  String get initials => initialsOf(label);

  /// A stored [name] when it's a real name (not blank, not an email), then
  /// [email]'s local part, then [unknown].
  static String fallbackLabel({String? name, String? email, String unknown = 'Unknown'}) {
    final n = (name ?? '').trim();
    if (n.isNotEmpty && !n.contains('@')) return n;
    final e = (email ?? '').trim();
    final local = usernameOf(e.isNotEmpty ? e : (n.contains('@') ? n : ''));
    if (local.isNotEmpty) return local;
    return unknown;
  }

  /// The local part of [email] ('' for none).
  static String usernameOf(String? email) {
    final e = (email ?? '').trim();
    if (e.isEmpty) return '';
    final at = e.indexOf('@');
    return at < 0 ? e : e.substring(0, at);
  }

  static String initialsOf(String label) {
    final words = label.trim().split(RegExp(r'[\s._-]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    final first = _firstChar(words.first);
    if (words.length == 1) return first;
    return first + _firstChar(words.last);
  }

  static String _firstChar(String word) => String.fromCharCode(word.runes.first).toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is MemberIdentity &&
      other.label == label &&
      other.photoUrl == photoUrl &&
      other.member?.uid == member?.uid;

  @override
  int get hashCode => Object.hash(label, photoUrl, member?.uid);

  @override
  String toString() => 'MemberIdentity($label)';
}

/// Identity lookups on the group member directory.
extension MemberIdentityLookup on GroupMemberDirectory {
  /// The identity for [uid] (or, when the directory has no such uid, the
  /// member with [email]) in [groupId] (default: the active group). Falls
  /// back to [name], then the email's local part, then [unknown].
  Future<MemberIdentity> identify({
    String? uid,
    String? email,
    String? name,
    String? groupId,
    String unknown = 'Unknown',
  }) async {
    GroupMember? m;
    try {
      m = await resolve(uid: uid, email: email, groupId: groupId);
    } catch (_) {
      // A failed read (offline, or a group the caller isn't in) shows the
      // fallback instead of nothing.
      m = null;
    }
    return m == null
        ? MemberIdentity.fallback(name: name, email: email, unknown: unknown)
        : MemberIdentity.fromMember(m);
  }

  /// [identify] from the cache only: the directory's entry when it's
  /// already loaded, the fallback otherwise. Never queries.
  MemberIdentity peekIdentity({
    String? uid,
    String? email,
    String? name,
    String? groupId,
    String unknown = 'Unknown',
  }) {
    final m = cachedMember(uid: uid, email: email, groupId: groupId);
    return m == null
        ? MemberIdentity.fallback(name: name, email: email, unknown: unknown)
        : MemberIdentity.fromMember(m);
  }

  /// The name to write into a document (a notification title, a stored
  /// creator name) for the signed-in user: their directory display name,
  /// then [authDisplayName] (FirebaseAuth's), then the email's local part,
  /// then [unknown].
  Future<String> selfLabel({
    required String uid,
    String? email,
    String? authDisplayName,
    String? groupId,
    String unknown = 'Someone',
  }) async {
    final id = await identify(uid: uid, email: email, groupId: groupId, unknown: '');
    final m = id.member;
    if (m != null && (m.displayName.isNotEmpty || (m.isGuest && m.guestName.isNotEmpty))) {
      return m.label;
    }
    final auth = (authDisplayName ?? '').trim();
    if (auth.isNotEmpty) return auth;
    if (id.label.isNotEmpty) return id.label;
    return unknown;
  }

  /// [selfLabel] for a FirebaseAuth [user]: the name to write into a
  /// notification or a stored creator name.
  Future<String> labelForUser(
    fire_auth.User user, {
    String? groupId,
    String unknown = 'Someone',
  }) =>
      selfLabel(
        uid: user.uid,
        email: user.email,
        authDisplayName: user.displayName,
        groupId: groupId,
        unknown: unknown,
      );
}
