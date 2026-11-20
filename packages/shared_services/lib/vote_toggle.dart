import 'package:cloud_firestore/cloud_firestore.dart';

import 'scoped_collection.dart';

/// Up/down voting on a shared document, one vote per member.
///
/// Each vote is the voter's own doc at `<parent>/votes/{uid}` (a `selfKeyed`
/// subcollection in security/collections.json): `value` is 1 (up), -1
/// (down) or 0 (withdrawn). Voting therefore needs no edit rights on the
/// parent. A server trigger (functions/_vote_tally.js) recounts the parent's
/// tallies from the vote docs: `voteCount` (up minus down, what lists sort
/// by), `upvoteCount`/`downvoteCount`, and `upvotedBy`/`downvotedBy`, which
/// clients read to show the caller's own vote. Those fields are the
/// parent's serverFields, so no client writes them.
class VoteToggle {
  const VoteToggle._();

  /// The vote subcollection's name.
  static const subcollection = 'votes';

  /// [uid]'s vote as the parent's [data] records it: 1, -1 or 0.
  static int currentValue(Map<String, dynamic>? data, String uid) {
    if (data == null || uid.isEmpty) return 0;
    if (_uids(data['upvotedBy']).contains(uid)) return 1;
    if (_uids(data['downvotedBy']).contains(uid)) return -1;
    return 0;
  }

  /// The vote after tapping up ([isUpvote]) or down from [current]: tapping
  /// the vote you already cast withdraws it.
  static int nextValue({required int current, required bool isUpvote}) {
    final tapped = isUpvote ? 1 : -1;
    return current == tapped ? 0 : tapped;
  }

  /// The parent's `voteCount` with [uid]'s vote shown as [pendingValue]
  /// before the server's recount lands (an optimistic display value).
  static int displayCount(
      Map<String, dynamic>? data, String uid, int? pendingValue) {
    final stored = (data?['voteCount'] as num?)?.toInt() ?? 0;
    if (pendingValue == null) return stored;
    return stored + pendingValue - currentValue(data, uid);
  }

  /// Records [uid]'s vote [value] on document [parentId] of [parent]. Goes
  /// through [ScopedCollection.sub], so a vote subcollection on the audit
  /// trail gets the voter's audit stamp the rules require.
  static Future<void> cast(
    ScopedCollection parent,
    String parentId, {
    required String uid,
    required int value,
  }) {
    assert(value == 1 || value == -1 || value == 0);
    final votes = parent.sub(parentId, subcollection);
    return votes.set(votes.doc(uid), {
      'userId': uid,
      'value': value,
      'votedAt': FieldValue.serverTimestamp(),
    });
  }

  static List<String> _uids(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];
}
