import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/vote_toggle.dart';

/// VoteToggle: the caller's vote from the server-kept tallies, the toggle,
/// the optimistic count, and the self-keyed vote doc it writes.
void main() {
  group('currentValue', () {
    test('reads the caller out of the tally arrays', () {
      final data = {
        'upvotedBy': ['a'],
        'downvotedBy': ['b'],
      };
      expect(VoteToggle.currentValue(data, 'a'), 1);
      expect(VoteToggle.currentValue(data, 'b'), -1);
      expect(VoteToggle.currentValue(data, 'c'), 0);
      expect(VoteToggle.currentValue(null, 'a'), 0);
      expect(VoteToggle.currentValue(data, ''), 0);
    });
  });

  group('nextValue', () {
    test('tapping a new direction casts it, tapping the same one withdraws it', () {
      expect(VoteToggle.nextValue(current: 0, isUpvote: true), 1);
      expect(VoteToggle.nextValue(current: 1, isUpvote: true), 0);
      expect(VoteToggle.nextValue(current: 1, isUpvote: false), -1);
      expect(VoteToggle.nextValue(current: -1, isUpvote: false), 0);
      expect(VoteToggle.nextValue(current: -1, isUpvote: true), 1);
    });
  });

  group('displayCount', () {
    test('shows a pending vote against the stored count', () {
      final data = {
        'voteCount': 3,
        'upvotedBy': ['a', 'x', 'y'],
        'downvotedBy': <String>[],
      };
      expect(VoteToggle.displayCount(data, 'a', null), 3);
      expect(VoteToggle.displayCount(data, 'a', 0), 2);
      expect(VoteToggle.displayCount(data, 'a', -1), 1);
      expect(VoteToggle.displayCount(data, 'b', 1), 4);
      expect(VoteToggle.displayCount(null, 'b', 1), 1);
    });
  });

  group('cast', () {
    late FakeFirebaseFirestore fake;
    setUp(() {
      fake = FakeFirebaseFirestore();
      ActiveGroupService.instance.activeGroupId = 'g1';
    });
    tearDown(() => ActiveGroupService.instance.activeGroupId = null);

    test("writes the voter's own votes/{uid} doc with the parent's tenant", () async {
      await fake.doc('feature_requests/f1').set({'groupId': 'g2', 'appId': 'improve-apps'});
      final tickets = ScopedCollection(
        collection: 'feature_requests',
        appId: 'improve-apps',
        firestore: fake,
        currentUid: () => 'u1',
      );
      await VoteToggle.cast(tickets, 'f1', uid: 'u1', value: 1);
      var vote = (await fake.doc('feature_requests/f1/votes/u1').get()).data()!;
      expect(vote['value'], 1);
      expect(vote['userId'], 'u1');
      expect(vote['groupId'], 'g2');
      expect(vote['appId'], 'improve-apps');
      expect(vote['creatorId'], 'u1');
      // Votes are on the audit trail: the write carries the voter's stamp.
      expect(vote['lastModifiedBy'], 'u1');
      expect(vote.containsKey('lastModifiedAt'), isTrue);

      await VoteToggle.cast(tickets, 'f1', uid: 'u1', value: 0);
      vote = (await fake.doc('feature_requests/f1/votes/u1').get()).data()!;
      expect(vote['value'], 0, reason: 'a withdrawn vote is kept as 0, never deleted');
      expect(vote['lastModifiedBy'], 'u1', reason: 'a changed vote is stamped too');
      // The parent's tallies are the server's: the client never writes them.
      expect((await fake.doc('feature_requests/f1').get()).data()!.containsKey('voteCount'), isFalse);
    });
  });
}
