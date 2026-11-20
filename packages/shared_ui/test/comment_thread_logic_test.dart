import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:shared_ui/comment_thread_widget.dart';

void main() {
  test('commentLikers counts each reader once per comment, from their likes doc', () {
    final likers = commentLikers([
      const MapEntry('u1', {'commentIds': ['c1', 'c2']}),
      const MapEntry('u2', {'commentIds': ['c1']}),
      const MapEntry('u3', {'commentIds': <String>[]}),
      const MapEntry('u4', null),
    ]);
    expect(likers['c1'], {'u1', 'u2'});
    expect(likers['c2'], {'u1'});
    expect(likers.containsKey('c3'), isFalse);
  });

  test('a deleted comment is hidden unless live replies hang off it', () {
    final visible = visibleCommentIds({
      'live': {'text': 'hi', 'parentCommentId': null},
      'gone': {'text': '', 'deletedAt': 1, 'parentCommentId': null},
      'goneWithReply': {'text': '', 'deletedAt': 1, 'parentCommentId': null},
      'reply': {'text': 're', 'parentCommentId': 'goneWithReply'},
      'goneReply': {'text': '', 'deletedAt': 1, 'parentCommentId': 'live'},
    });
    expect(visible, {'live', 'goneWithReply', 'reply'});
  });

  test('isCommentDeleted reads deletedAt', () {
    expect(isCommentDeleted({'deletedAt': 1}), isTrue);
    expect(isCommentDeleted({'text': 'x'}), isFalse);
  });

  test('a moderator\'s removal reads differently from the author\'s delete', () {
    expect(deletedCommentLabel({'deletedAt': 1, 'deletedBy': 'a'}), 'Comment deleted');
    expect(deletedCommentLabel({'deletedAt': 1, 'deletedBy': 'mod', 'moderationReason': 'spam'}),
        'Comment removed by a moderator');
    expect(isCommentModerated({'moderationReason': 'spam'}), isFalse, reason: 'not deleted');
  });

  test('only a possible moderator asks the server whether they moderate the thread', () {
    expect(mightModerateComments(const UserAppEntitlements(roles: {'admin'})), isTrue);
    expect(mightModerateComments(const UserAppEntitlements(entitlements: {'g1:improve-apps:admin'})), isTrue);
    expect(mightModerateComments(const UserAppEntitlements(entitlements: {'app:notes:steward'})), isTrue);
    expect(mightModerateComments(const UserAppEntitlements(entitlements: {'g1:improve-apps', 'g1:improve-apps:edit'})), isFalse);
    expect(mightModerateComments(const UserAppEntitlements(roles: {'admin'}, status: 'SUSPENDED')), isFalse);
  });
}
