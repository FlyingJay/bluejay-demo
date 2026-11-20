import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/comment_thread_widget.dart';
import 'package:shared_ui/initials_avatar.dart';
import 'package:shared_ui/shared_message_composer.dart';
import 'package:shared_ui/user_search_screen.dart';

import 'support/fixtures.dart';

Widget _host(Widget child) => MaterialApp(
      theme: BluejayTheme.build(),
      home: Scaffold(body: child),
    );

void main() {
  group('comment thread', () {
    Future<List<String>> pumpThread(
      WidgetTester tester, {
      List<CommentEntry>? comments,
      bool canModerate = false,
      bool signedIn = true,
    }) async {
      final calls = <String>[];
      await tester.pumpWidget(_host(CommentThreadList(
        comments: comments ?? sampleComments,
        signedIn: signedIn,
        canModerate: canModerate,
        onLike: (c) => calls.add('like ${c.id}'),
        onReply: (c) => calls.add('reply ${c.id}'),
        onDelete: (c) => calls.add('delete ${c.id}'),
        onModerate: (c) => calls.add('moderate ${c.id}'),
      )));
      return calls;
    }

    testWidgets('shows replies under their parent and deleted placeholders',
        (tester) async {
      await pumpThread(tester);
      expect(find.text('Comment removed by a moderator'), findsOneWidget);
      expect(find.textContaining('narrows it down'), findsOneWidget);
      // Replies have no Reply action: only the three top-level live
      // comments... minus the deleted one = 2.
      expect(find.text('Reply'), findsNWidgets(2));
    });

    testWidgets('like and reply report the comment', (tester) async {
      final calls = await pumpThread(tester);
      await tester.tap(find.text('3')); // c1's like count
      await tester.tap(find.text('Reply').first);
      expect(calls, ['like c1', 'reply c1']);
    });

    testWidgets('own comments offer delete in the overflow menu, last and red',
        (tester) async {
      final calls = await pumpThread(tester, comments: [sampleComments.last]);
      await tester.tap(find.byType(BjOverflowMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete comment'));
      await tester.pumpAndSettle();
      expect(calls, ['delete c5']);
    });

    testWidgets('moderators can remove someone else\'s comment',
        (tester) async {
      final calls = await pumpThread(tester,
          comments: [sampleComments.first], canModerate: true);
      await tester.tap(find.byType(BjOverflowMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove as moderator'));
      await tester.pumpAndSettle();
      expect(calls, ['moderate c1']);
    });

    testWidgets('no menu on others\' comments without moderation',
        (tester) async {
      await pumpThread(tester, comments: [sampleComments.first]);
      expect(find.byType(BjOverflowMenu), findsNothing);
    });

    testWidgets('empty thread invites the first comment', (tester) async {
      await pumpThread(tester, comments: const []);
      expect(find.text('No comments yet'), findsOneWidget);
    });

    testWidgets('signed-out readers cannot like or reply', (tester) async {
      final calls = await pumpThread(tester, signedIn: false);
      await tester.tap(find.text('Reply').first, warnIfMissed: false);
      expect(calls, isEmpty);
    });

    testWidgets('composer shows the reply banner and sends', (tester) async {
      var sent = 0, cancelled = 0;
      final controller = TextEditingController(text: 'hello');
      await tester.pumpWidget(_host(Column(children: [
        const Spacer(),
        CommentComposer(
          controller: controller,
          enabled: true,
          isSubmitting: false,
          replyToAuthor: 'bianca',
          onCancelReply: () => cancelled++,
          onSubmit: () => sent++,
        ),
      ])));
      expect(find.text('Replying to bianca'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.tap(find.byTooltip('Cancel reply'));
      expect((sent, cancelled), (1, 1));
    });

    testWidgets('signed-out composer is disabled', (tester) async {
      await tester.pumpWidget(_host(Column(children: [
        const Spacer(),
        CommentComposer(
          controller: TextEditingController(),
          enabled: false,
          isSubmitting: false,
          onSubmit: () {},
        ),
      ])));
      expect(find.text('Sign in to comment'), findsOneWidget);
    });

    test('CommentEntry prefers a stored author name over the email', () {
      final entry = CommentEntry.fromData('c1', {
        'authorId': 'u1',
        'authorEmail': 'avery@bluejay.gg',
        'authorName': 'Avery Brooks',
      });
      expect(entry.authorName, 'Avery Brooks');
    });

    testWidgets('a comment shows its author\'s directory display name',
        (tester) async {
      final previous = GroupMemberDirectory.instance;
      addTearDown(() => GroupMemberDirectory.instance = previous);
      GroupMemberDirectory.instance = GroupMemberDirectory()
        ..primeCache('g', const [
          GroupMember(
              groupId: 'g',
              uid: 'u1',
              email: 'avery@bluejay.gg',
              displayName: 'Avery Brooks'),
        ]);
      await tester.pumpWidget(_host(CommentThreadList(
        comments: [
          CommentEntry.fromData('c1', {
            'authorId': 'u1',
            'authorEmail': 'avery@bluejay.gg',
            'groupId': 'g',
            'text': 'Hi',
          }),
        ],
        signedIn: true,
        canModerate: false,
        onLike: (_) {},
        onReply: (_) {},
        onDelete: (_) {},
        onModerate: (_) {},
      )));
      expect(find.text('Avery Brooks'), findsOneWidget);
      expect(find.text('avery'), findsNothing);
    });

    test('CommentEntry reads a comment doc', () {
      final entry = CommentEntry.fromData(
        'c9',
        {
          'authorId': 'u1',
          'authorEmail': 'avery@bluejay.gg',
          'text': 'Hi',
          'parentCommentId': 'c1',
        },
        likers: {'u1', 'u2'},
        currentUid: 'u1',
      );
      expect(entry.authorName, 'avery');
      expect(entry.authorEmail, 'avery@bluejay.gg');
      expect(entry.likeCount, 2);
      expect(entry.likedByMe, isTrue);
      expect(entry.isMine, isTrue);
      expect(entry.isDeleted, isFalse);
      expect(entry.parentCommentId, 'c1');
    });
  });

  group('user search', () {
    Future<List<String>> pumpSearch(
      WidgetTester tester, {
      List<GroupMember>? members,
      bool loading = false,
      String? error,
      bool multiSelect = false,
      Set<String> selected = const {},
      String query = '',
    }) async {
      final calls = <String>[];
      await tester.pumpWidget(_host(UserSearchBody(
        searchController: TextEditingController(text: query),
        members: members ?? sampleMembers,
        allMembers: sampleMembers,
        isLoading: loading,
        loadError: error,
        multiSelect: multiSelect,
        selectedUserIds: selected,
        onTap: (m) => calls.add('tap ${m.uid}'),
        onDeselect: (uid) => calls.add('deselect $uid'),
        onRetry: () => calls.add('retry'),
      )));
      await tester.pump(const Duration(milliseconds: 400));
      return calls;
    }

    testWidgets('lists members and reports taps', (tester) async {
      final calls = await pumpSearch(tester);
      expect(find.text('Avery Chen'), findsOneWidget);
      await tester.tap(find.text('Bianca Ortiz'));
      expect(calls, ['tap u2']);
    });

    testWidgets('multi-select shows chips for the picked people',
        (tester) async {
      final calls = await pumpSearch(tester,
          multiSelect: true, selected: {'u1', 'u3'});
      expect(find.byType(InputChip), findsNWidgets(2));
      await tester.tap(find.byTooltip('Remove').first);
      expect(calls, ['deselect u1']);
    });

    testWidgets('no match says what was searched', (tester) async {
      await pumpSearch(tester, members: const [], query: 'zed');
      expect(find.text('No one matches "zed"'), findsOneWidget);
    });

    testWidgets('load errors offer a retry', (tester) async {
      final calls = await pumpSearch(tester, members: const [], error: 'boom');
      expect(find.text('Couldn\'t load people'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(calls, ['retry']);
    });

    testWidgets('loading shows a skeleton', (tester) async {
      await pumpSearch(tester, loading: true);
      expect(find.byType(BjSkeletonList), findsOneWidget);
    });

    test('initials', () {
      expect(memberInitials('jane.doe'), 'JD');
      expect(memberInitials('Sam'), 'S');
      expect(memberInitials(''), '?');
    });
  });

  testWidgets('message composer sends and attaches', (tester) async {
    var sent = 0, picked = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(_host(Column(children: [
      const Spacer(),
      SharedMessageComposer(
        controller: controller,
        onSend: () => sent++,
        onPickImage: () => picked++,
      ),
    ])));
    await tester.enterText(find.byType(TextField), 'Hello there');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Send message'));
    await tester.tap(find.byTooltip('Attach an image'));
    expect((sent, picked), (1, 1));
  });
}
