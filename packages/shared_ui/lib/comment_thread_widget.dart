import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_services/live_window.dart';
import 'package:shared_services/member_identity.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:shared_services/cloud_functions.dart';

import 'change_request_ui.dart';
import 'initials_avatar.dart';
import 'load_more.dart';
import 'member_identity_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Comment count badge — shows on cards to indicate comments exist
// ─────────────────────────────────────────────────────────────────────────────

/// The `comments` subcollection of document [parentId] in [parent]: new
/// comments carry the parent document's `groupId`/`appId` (see
/// [ScopedCollection.sub]).
///
/// A collection that shows this thread declares `commentThread` in
/// security/collections.json: each comment is its author's, is on the audit
/// trail, and is never hard-deleted (deleting one sets `deletedAt`).
ScopedCollection commentsOf(ScopedCollection parent, String parentId) =>
    parent.sub(parentId, 'comments');

/// The thread's likes: one doc per reader, keyed by their uid, whose
/// `commentIds` lists the comments they like. Any reader of the parent likes
/// a comment this way without editing the comment itself.
ScopedCollection commentLikesOf(ScopedCollection parent, String parentId) =>
    parent.sub(parentId, 'comment_likes');

/// Whether a comment has been deleted (it is kept, with `deletedAt` set).
bool isCommentDeleted(Map<String, dynamic>? data) =>
    ScopedCollection.isSoftDeleted(data);

/// Whether a deleted comment was removed by a moderator (the
/// `commentsModerate` callable sets `moderationReason`) rather than its author.
bool isCommentModerated(Map<String, dynamic>? data) =>
    isCommentDeleted(data) &&
    data?['moderationReason'] is String &&
    (data!['moderationReason'] as String).isNotEmpty;

/// What a deleted comment kept in view for its replies reads as.
String deletedCommentLabel(Map<String, dynamic>? data) =>
    isCommentModerated(data) ? 'Comment removed by a moderator' : 'Comment deleted';

/// Whether an access index could make its holder a moderator of some thread
/// (a platform admin, an app's `:admin` tier, a steward): only then does the
/// thread ask `commentsModerate` (`check: true`), which decides.
bool mightModerateComments(UserAppEntitlements e) =>
    e.isActivePlatformAdmin ||
    e.entitlements.any((x) => x.endsWith(':admin') || x.endsWith(':steward'));

/// Who likes each comment, from the thread's likes docs (doc id = uid).
Map<String, Set<String>> commentLikers(
    Iterable<MapEntry<String, Map<String, dynamic>?>> likesDocs) {
  final out = <String, Set<String>>{};
  for (final doc in likesDocs) {
    final ids = doc.value?['commentIds'];
    if (ids is! List) continue;
    for (final id in ids.whereType<String>()) {
      out.putIfAbsent(id, () => <String>{}).add(doc.key);
    }
  }
  return out;
}

/// Which comments a thread shows: every live comment, and a deleted
/// top-level comment only while it has live replies (as "Comment deleted").
/// [comments] maps id to data.
Set<String> visibleCommentIds(Map<String, Map<String, dynamic>> comments) {
  final liveReplyParents = <String>{
    for (final c in comments.values)
      if (!isCommentDeleted(c) && c['parentCommentId'] is String)
        c['parentCommentId'] as String,
  };
  return {
    for (final e in comments.entries)
      if (!isCommentDeleted(e.value) ||
          (e.value['parentCommentId'] == null &&
              liveReplyParents.contains(e.key)))
        e.key,
  };
}

/// A small chip that streams the comment count for document [parentId] of
/// [parent] and opens the comment thread bottom sheet on tap. It reads at
/// most [kBadgeCountCap] comments; a thread with more shows "99+".
class CommentCountChip extends StatelessWidget {
  final ScopedCollection parent;
  final String parentId;
  final fire_auth.User? currentUser;

  const CommentCountChip({
    super.key,
    required this.parent,
    required this.parentId,
    this.currentUser,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: commentsOf(parent, parentId)
          .query
          .limit(kBadgeCountCap)
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? const [];
        // A full read means the thread may hold more: count it as the cap.
        final count = docs.length >= kBadgeCountCap
            ? kBadgeCountCap
            : docs
                .where((d) =>
                    !isCommentDeleted(d.data() as Map<String, dynamic>?))
                .length;

        return CommentCountButton(
          count: count,
          onTap: () => showCommentThread(
            context: context,
            parent: parent,
            parentId: parentId,
            currentUser: currentUser,
          ),
        );
      },
    );
  }
}

/// The look of [CommentCountChip]: accent once a thread has comments,
/// neutral before the first one.
class CommentCountButton extends StatelessWidget {
  const CommentCountButton({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ChangeRequestActionChip(
        icon: count > 0
            ? Icons.chat_bubble_rounded
            : Icons.chat_bubble_outline_rounded,
        label: count > 0 ? cappedCountLabel(count) : 'Comment',
        tone: count > 0 ? BjTone.accent : BjTone.neutral,
        onTap: onTap,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Show comment thread bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the comment thread of document [parentId] in [parent].
void showCommentThread({
  required BuildContext context,
  required ScopedCollection parent,
  required String parentId,
  fire_auth.User? currentUser,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _CommentThreadSheet(
        parent: parent,
        parentId: parentId,
        currentUser: currentUser,
        scrollController: scrollController,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Comment thread bottom sheet content
// ─────────────────────────────────────────────────────────────────────────────

class _CommentThreadSheet extends StatefulWidget {
  final ScopedCollection parent;
  final String parentId;
  final fire_auth.User? currentUser;
  final ScrollController scrollController;

  const _CommentThreadSheet({
    required this.parent,
    required this.parentId,
    required this.currentUser,
    required this.scrollController,
  });

  @override
  _CommentThreadSheetState createState() => _CommentThreadSheetState();
}

class _CommentThreadSheetState extends State<_CommentThreadSheet> {
  final _commentController = TextEditingController();
  final _commentFocusNode = FocusNode();
  bool _isSubmitting = false;
  // Whether the caller moderates this thread (commentsModerate decides).
  bool _canModerate = false;

  @override
  void initState() {
    super.initState();
    _resolveModerator();
  }

  Future<void> _resolveModerator() async {
    final user = widget.currentUser;
    if (user == null) return;
    try {
      final e = await UserAppEntitlements.load(user.uid);
      if (!mightModerateComments(e)) return;
      final result = await BluejayFunctions.instance
          .httpsCallable('commentsModerate')
          .call({'collection': widget.parent.collection, 'parentId': widget.parentId, 'check': true});
      final allowed = (result.data as Map?)?['allowed'] == true;
      if (mounted && allowed) setState(() => _canModerate = true);
    } catch (_) {
      // No moderation action if the check can't run.
    }
  }

  /// Removes someone else's comment as a moderator, with a reason.
  Future<void> _moderateComment(DocumentReference commentRef) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _ModerateCommentDialog(controller: controller),
    );
    controller.dispose();
    if (reason == null || reason.isEmpty) return;
    try {
      await BluejayFunctions.instance.httpsCallable('commentsModerate').call({
        'collection': widget.parent.collection,
        'parentId': widget.parentId,
        'commentId': commentRef.id,
        'reason': reason,
      });
    } catch (e) {
      if (mounted) {
        BjSnack.error(context, 'Couldn\'t remove comment. Please try again.');
      }
    }
  }
  String? _replyToCommentId;
  String? _replyToAuthor;

  late final ScopedCollection _comments =
      commentsOf(widget.parent, widget.parentId);
  late final ScopedCollection _likes =
      commentLikesOf(widget.parent, widget.parentId);
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _likesStream =
      _likes.query.snapshots();

  /// The newest comments, a page at a time, newest first (shown oldest
  /// first). Held here so typing in the composer doesn't resubscribe.
  late final LiveWindow<QueryDocumentSnapshot<Map<String, dynamic>>>
      _commentsWindow = LiveWindow.query(
          _comments.query.orderBy('timestamp', descending: true));

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    final user = widget.currentUser;
    if (user == null) return;

    setState(() => _isSubmitting = true);

    try {
      final docRef = await _comments.add({
        'text': text,
        'authorId': user.uid,
        'authorEmail': user.email,
        'timestamp': Timestamp.now(),
        'parentCommentId': _replyToCommentId,
      });

      // Trigger notification (best-effort)
      try {
        // Determine item type from parent path
        final parentCollection = widget.parent.collection;
        String itemType = 'bug'; // default
        String itemId = widget.parentId;

        if (parentCollection.contains('feature_requests')) {
          itemType = 'feature';
        } else if (parentCollection.contains('app_requests')) {
          itemType = 'app';
        }

        final callable = BluejayFunctions.instance
            .httpsCallable('improveBluejayNotifyComment');
        await callable.call({
          'itemType': itemType,
          'itemId': itemId,
          'commentId': docRef.id,
        });
      } catch (_) {
        // Notification delivery is best-effort
      }

      _commentController.clear();
      _cancelReply();
    } catch (e) {
      if (mounted) {
        BjSnack.error(context, 'Couldn\'t post comment. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _startReply(String commentId, String authorName) {
    setState(() {
      _replyToCommentId = commentId;
      _replyToAuthor = authorName;
    });
    // Focus the text field
    _commentFocusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyToCommentId = null;
      _replyToAuthor = null;
    });
  }

  /// Likes or unlikes a comment through the caller's own likes doc
  /// (`comment_likes/{uid}`); the comment itself isn't written.
  Future<void> _toggleLike(DocumentReference commentRef, bool liked) async {
    final user = widget.currentUser;
    if (user == null) return;
    try {
      await _likes.set(
        _likes.doc(user.uid),
        {
          'userId': user.uid,
          'commentIds': liked
              ? FieldValue.arrayRemove([commentRef.id])
              : FieldValue.arrayUnion([commentRef.id]),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (e) {
      if (mounted) {
        BjSnack.error(context, 'Couldn\'t update the like. Please try again.');
      }
    }
  }

  Future<void> _deleteComment(DocumentReference commentRef) async {
    final confirmed = await showBjConfirm(
      context,
      title: 'Delete comment?',
      message: 'This can\'t be undone.',
      consequences: const [
        'The comment shows as "Comment deleted" to everyone',
        'Replies to it stay in the thread',
      ],
      confirmLabel: 'Delete comment',
      destructive: true,
    );

    final user = widget.currentUser;
    if (confirmed == true && user != null) {
      try {
        // A soft delete: the comment is kept for the record (the audit trail
        // holds what it said) and shows as deleted. Replies stay.
        await _comments.update(
          commentRef as DocumentReference<Map<String, dynamic>>,
          {
            'text': '',
            ScopedCollection.softDeleteField: FieldValue.serverTimestamp(),
            'deletedBy': user.uid,
          },
        );
      } catch (e) {
        if (mounted) {
          BjSnack.error(context, 'Couldn\'t delete comment. Please try again.');
        }
      }
    }
  }

  @override
  void dispose() {
    _commentsWindow.dispose();
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = widget.currentUser != null;

    return CommentThreadFrame(
      onClose: () => Navigator.of(context).pop(),
      composer: CommentComposer(
        controller: _commentController,
        focusNode: _commentFocusNode,
        enabled: isLoggedIn,
        isSubmitting: _isSubmitting,
        replyToAuthor: _replyToAuthor,
        onCancelReply: _cancelReply,
        onSubmit: _submitComment,
      ),
      body: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
        stream: _commentsWindow.stream,
        builder: (context, snapshot) {
          return BjSnapshotView<
              List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
            snapshot: snapshot,
            errorTitle: 'Couldn\'t load comments',
            loading: const BjSkeletonList(count: 3),
            onRetry: _commentsWindow.retry,
            builder: (newestFirst) {
              final docs = newestFirst.reversed.toList();
              final visible = visibleCommentIds({
                for (final d in docs) d.id: d.data(),
              });
              final allComments =
                  docs.where((d) => visible.contains(d.id)).toList();

              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _likesStream,
                builder: (context, likesSnapshot) {
                  final likers = commentLikers([
                    for (final d in likesSnapshot.data?.docs ?? const [])
                      MapEntry(d.id, d.data()),
                  ]);
                  final uid = widget.currentUser?.uid;
                  final refs = {for (final d in allComments) d.id: d.reference};
                  final entries = [
                    for (final d in allComments)
                      CommentEntry.fromData(
                        d.id,
                        d.data(),
                        likers: likers[d.id] ?? const <String>{},
                        currentUid: uid,
                      ),
                  ];
                  return CommentThreadList(
                    comments: entries,
                    scrollController: widget.scrollController,
                    signedIn: uid != null,
                    canModerate: _canModerate,
                    onLike: (c) => _toggleLike(refs[c.id]!, c.likedByMe),
                    onReply: (c) => _startReply(
                        c.parentCommentId ?? c.id,
                        GroupMemberDirectory.instance
                            .peekIdentity(
                                uid: c.authorId,
                                email: c.authorEmail,
                                name: c.authorName,
                                groupId: c.groupId)
                            .label),
                    onDelete: (c) => _deleteComment(refs[c.id]!),
                    onModerate: (c) => _moderateComment(refs[c.id]!),
                    leading: LoadMoreButton(
                      hasMore: _commentsWindow.hasMore,
                      loading: _commentsWindow.isLoadingMore,
                      onLoadMore: _commentsWindow.loadMore,
                      label: 'Show earlier comments',
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// Asks a moderator for the reason they're removing someone's comment.
class _ModerateCommentDialog extends StatelessWidget {
  const _ModerateCommentDialog({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final danger = context.bj.tone(BjTone.danger);
    return AlertDialog(
      icon: const Center(
        child: BjIconWell(
          icon: Icons.remove_circle_outline_rounded,
          tone: BjTone.danger,
          size: 52,
        ),
      ),
      title: const Text('Remove comment?', textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'It will show as removed by a moderator. The original stays on record for admins.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BjSpace.lg),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Shown to admins reviewing the thread',
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: danger.foreground),
          onPressed: () {
            final text = controller.text.trim();
            if (text.isNotEmpty) Navigator.of(context).pop(text);
          },
          child: const Text('Remove comment'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Presentational pieces (no Firestore): tested and rendered with sample data
// ─────────────────────────────────────────────────────────────────────────────

/// One comment as the thread shows it.
class CommentEntry {
  const CommentEntry({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    this.authorEmail,
    this.groupId,
    this.timestamp,
    this.parentCommentId,
    this.deletedLabel,
    this.likeCount = 0,
    this.likedByMe = false,
    this.isMine = false,
  });

  /// Reads a comment doc's [data]; [likers] are the uids that like it.
  factory CommentEntry.fromData(
    String id,
    Map<String, dynamic> data, {
    Set<String> likers = const {},
    String? currentUid,
  }) {
    final authorId = data['authorId'] as String? ?? '';
    final email = data['authorEmail'] as String?;
    return CommentEntry(
      id: id,
      authorId: authorId,
      authorName: MemberIdentity.fallbackLabel(name: data['authorName'] as String?, email: email),
      authorEmail: email,
      groupId: data['groupId'] as String?,
      text: data['text'] as String? ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate(),
      parentCommentId: data['parentCommentId'] as String?,
      deletedLabel: isCommentDeleted(data) ? deletedCommentLabel(data) : null,
      likeCount: likers.length,
      likedByMe: currentUid != null && likers.contains(currentUid),
      isMine: currentUid != null && currentUid == authorId,
    );
  }

  final String id;
  final String authorId;

  /// The name the comment doc gives (a stored name, else the email's local
  /// part). The thread shows the author's directory display name instead
  /// once it loads.
  final String authorName;

  /// The author's email as stored on the comment, used to find them in the
  /// group member directory when [authorId] doesn't.
  final String? authorEmail;

  /// The comment's group, where its author is looked up (default: the
  /// active group).
  final String? groupId;
  final String text;
  final DateTime? timestamp;
  final String? parentCommentId;

  /// Set when the comment was deleted and is kept in view for its replies.
  final String? deletedLabel;
  final int likeCount;
  final bool likedByMe;
  final bool isMine;

  bool get isDeleted => deletedLabel != null;
}

/// The sheet's chrome: drag handle, header, the thread, and the composer
/// pinned at the bottom.
class CommentThreadFrame extends StatelessWidget {
  const CommentThreadFrame({
    super.key,
    required this.body,
    required this.composer,
    this.onClose,
  });

  final Widget body;
  final Widget composer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              BjSpace.xl, BjSpace.sm, BjSpace.lg, BjSpace.md),
          child: Row(
            children: [
              const BjIconWell(icon: Icons.forum_rounded, size: 40),
              const SizedBox(width: BjSpace.md),
              Expanded(child: Text('Comments', style: text.titleLarge)),
              if (onClose != null)
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClose,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: body),
        composer,
      ],
    );
  }
}

/// The comments and their replies, each reply indented under its parent.
class CommentThreadList extends StatelessWidget {
  const CommentThreadList({
    super.key,
    required this.comments,
    required this.onLike,
    required this.onReply,
    required this.onDelete,
    required this.onModerate,
    this.signedIn = true,
    this.canModerate = false,
    this.scrollController,
    this.leading,
  });

  /// Every visible comment, oldest first; replies carry [CommentEntry.parentCommentId].
  final List<CommentEntry> comments;

  /// Shown above the oldest comment (loading earlier ones).
  final Widget? leading;
  final ValueChanged<CommentEntry> onLike;
  final ValueChanged<CommentEntry> onReply;
  final ValueChanged<CommentEntry> onDelete;
  final ValueChanged<CommentEntry> onModerate;
  final bool signedIn;
  final bool canModerate;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final topLevel = comments.where((c) => c.parentCommentId == null).toList();
    if (topLevel.isEmpty) {
      return ListView(
        controller: scrollController,
        children: [
          if (leading != null) leading!,
          const BjStateView.empty(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'No comments yet',
            message: 'Start the conversation: ask a question or add detail.',
          ),
        ],
      );
    }
    final replies = <String, List<CommentEntry>>{};
    for (final c in comments) {
      final parent = c.parentCommentId;
      if (parent != null) replies.putIfAbsent(parent, () => []).add(c);
    }
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
          BjSpace.lg, BjSpace.lg, BjSpace.lg, BjSpace.lg),
      itemCount: topLevel.length + (leading == null ? 0 : 1),
      separatorBuilder: (_, __) => const SizedBox(height: BjSpace.md),
      itemBuilder: (context, i) {
        final lead = leading;
        if (lead != null && i == 0) return lead;
        final index = lead == null ? i : i - 1;
        final comment = topLevel[index];
        final children = replies[comment.id] ?? const <CommentEntry>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CommentBubble(
              comment: comment,
              isReply: false,
              signedIn: signedIn,
              canModerate: canModerate,
              onLike: () => onLike(comment),
              onReply: () => onReply(comment),
              onDelete: () => onDelete(comment),
              onModerate: () => onModerate(comment),
            ),
            if (children.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: BjSpace.lg, top: BjSpace.sm),
                padding: const EdgeInsets.only(left: BjSpace.md),
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: BjNeutral.border, width: 2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final reply in children)
                      Padding(
                        padding: const EdgeInsets.only(bottom: BjSpace.sm),
                        child: _CommentBubble(
                          comment: reply,
                          isReply: true,
                          signedIn: signedIn,
                          canModerate: canModerate,
                          onLike: () => onLike(reply),
                          onReply: () => onReply(comment),
                          onDelete: () => onDelete(reply),
                          onModerate: () => onModerate(reply),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CommentBubble extends StatelessWidget {
  const _CommentBubble({
    required this.comment,
    required this.isReply,
    required this.signedIn,
    required this.canModerate,
    required this.onLike,
    required this.onReply,
    required this.onDelete,
    required this.onModerate,
  });

  final CommentEntry comment;
  final bool isReply;
  final bool signedIn;
  final bool canModerate;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback onDelete;
  final VoidCallback onModerate;

  /// Builds with the author's directory display name ([CommentEntry.authorName]
  /// until it loads, or when the directory doesn't know them).
  Widget _author(Widget Function(BuildContext context, String name) builder) =>
      MemberIdentityBuilder(
        uid: comment.authorId,
        email: comment.authorEmail,
        name: comment.authorName,
        groupId: comment.groupId,
        builder: (context, id) => builder(context, id.label),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (comment.isDeleted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: BjSpace.xs),
        child: BjInlineNote(comment.deletedLabel!, icon: Icons.block_rounded),
      );
    }
    final danger = context.bj.tone(BjTone.danger);
    final menu = <BjMenuAction>[
      if (comment.isMine)
        BjMenuAction(
          label: 'Delete comment',
          icon: Icons.delete_outline_rounded,
          destructive: true,
          onSelected: onDelete,
        ),
      if (!comment.isMine && canModerate)
        BjMenuAction(
          label: 'Remove as moderator',
          icon: Icons.remove_circle_outline_rounded,
          destructive: true,
          onSelected: onModerate,
        ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _author((context, name) => InitialsAvatar(
              name: name,
              seed: comment.authorId.isEmpty ? null : comment.authorId,
              size: isReply ? 28 : 34,
            )),
        const SizedBox(width: BjSpace.sm + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(
                    BjSpace.md, BjSpace.sm, BjSpace.md, BjSpace.sm + 2),
                decoration: BoxDecoration(
                  color: comment.isMine
                      ? context.bj.accentWash
                      : BjNeutral.surfaceMuted,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(BjRadius.xs),
                    topRight: Radius.circular(BjRadius.lg),
                    bottomLeft: Radius.circular(BjRadius.lg),
                    bottomRight: Radius.circular(BjRadius.lg),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _author((context, name) => Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: name,
                              style: text.labelLarge?.copyWith(color: BjNeutral.ink),
                            ),
                            if (comment.timestamp != null)
                              TextSpan(
                                text: '  ·  ${formatTimeAgo(comment.timestamp!)}',
                                style: text.bodySmall
                                    ?.copyWith(color: BjNeutral.inkSubtle),
                              ),
                          ]),
                        )),
                    const SizedBox(height: BjSpace.xxs),
                    Text(
                      comment.text,
                      style: text.bodyMedium
                          ?.copyWith(color: BjNeutral.ink, height: 1.4),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  _CommentAction(
                    icon: comment.likedByMe
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    label: comment.likeCount > 0 ? '${comment.likeCount}' : 'Like',
                    tooltip: comment.likedByMe ? 'Unlike' : 'Like',
                    activeColor: comment.likedByMe ? danger.foreground : null,
                    onTap: signedIn ? onLike : null,
                  ),
                  if (!isReply)
                    _CommentAction(
                      icon: Icons.reply_rounded,
                      label: 'Reply',
                      tooltip: 'Reply',
                      onTap: signedIn ? onReply : null,
                    ),
                  const Spacer(),
                  if (menu.isNotEmpty)
                    BjOverflowMenu(actions: menu, tooltip: 'More'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommentAction extends StatelessWidget {
  const _CommentAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.activeColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final Color? activeColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = activeColor ??
        (onTap == null ? BjNeutral.borderStrong : BjNeutral.inkSubtle);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BjRadius.all(BjRadius.pill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: BjSpace.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: BjMotion.fast,
                  child: Icon(icon, key: ValueKey(icon), size: 16, color: color),
                ),
                const SizedBox(width: BjSpace.xs),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: color,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The text field pinned to the bottom of the thread, with the "Replying
/// to" banner above it.
class CommentComposer extends StatelessWidget {
  const CommentComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.isSubmitting,
    required this.onSubmit,
    this.focusNode,
    this.replyToAuthor,
    this.onCancelReply,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool isSubmitting;
  final String? replyToAuthor;
  final VoidCallback? onCancelReply;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final bj = context.bj;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: const BoxDecoration(
        color: BjNeutral.surface,
        border: Border(top: BorderSide(color: BjNeutral.border)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: BjMotion.medium,
              curve: BjMotion.curve,
              child: replyToAuthor == null
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      width: double.infinity,
                      color: bj.accentWash,
                      padding: const EdgeInsets.fromLTRB(
                          BjSpace.lg, BjSpace.xs, BjSpace.xs, BjSpace.xs),
                      child: Row(
                        children: [
                          Icon(Icons.reply_rounded, size: 16, color: bj.accent),
                          const SizedBox(width: BjSpace.sm),
                          Expanded(
                            child: Text(
                              'Replying to $replyToAuthor',
                              style: text.labelMedium?.copyWith(color: bj.accent),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel reply',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: onCancelReply,
                          ),
                        ],
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  BjSpace.lg, BjSpace.sm + 2, BjSpace.sm, BjSpace.sm + 2),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSubmit(),
                      decoration: InputDecoration(
                        hintText: enabled
                            ? (replyToAuthor != null
                                ? 'Write a reply…'
                                : 'Write a comment…')
                            : 'Sign in to comment',
                        fillColor: BjNeutral.surfaceMuted,
                        border: OutlineInputBorder(
                          borderRadius: BjRadius.all(BjRadius.xl),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BjRadius.all(BjRadius.xl),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: BjSpace.lg,
                          vertical: BjSpace.sm + 2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: BjSpace.xs),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: enabled && !isSubmitting ? onSubmit : null,
                    icon: AnimatedSwitcher(
                      duration: BjMotion.fast,
                      child: isSubmitting
                          ? const SizedBox(
                              key: ValueKey('busy'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send_rounded,
                              key: ValueKey('send'), size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
