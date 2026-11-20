import 'package:shared_ui/comment_thread_widget.dart';
import 'package:shared_ui/user_search_screen.dart';

final sampleMembers = [
  for (final (uid, name) in [
    ('u1', 'Avery Chen'),
    ('u2', 'Bianca Ortiz'),
    ('u3', 'Dev Patel'),
    ('u4', 'Elena Rossi'),
    ('u5', 'Femi Adeyemi'),
    ('u6', 'Grace Kim'),
  ])
    GroupMember(groupId: 'bluejay', uid: uid, displayName: name),
];

final _now = DateTime.now();

final sampleComments = [
  CommentEntry(
    id: 'c1',
    authorId: 'u2',
    authorName: 'bianca',
    text: 'This happens for me too when I export a list with more than 50 rows.',
    timestamp: _now.subtract(const Duration(hours: 5)),
    likeCount: 3,
    likedByMe: true,
  ),
  CommentEntry(
    id: 'c2',
    authorId: 'u1',
    authorName: 'avery',
    text: 'Thanks, that narrows it down. I can reproduce it now.',
    timestamp: _now.subtract(const Duration(hours: 2)),
    parentCommentId: 'c1',
    isMine: true,
  ),
  CommentEntry(
    id: 'c3',
    authorId: 'u3',
    authorName: 'dev',
    text: '',
    parentCommentId: null,
    deletedLabel: 'Comment removed by a moderator',
  ),
  CommentEntry(
    id: 'c4',
    authorId: 'u4',
    authorName: 'elena',
    text: 'Could the export also include the due dates?',
    timestamp: _now.subtract(const Duration(minutes: 12)),
    parentCommentId: 'c3',
    likeCount: 1,
  ),
  CommentEntry(
    id: 'c5',
    authorId: 'u1',
    authorName: 'avery',
    text: 'Fix is in review. It should ship this week.',
    timestamp: _now.subtract(const Duration(minutes: 3)),
    isMine: true,
  ),
];
