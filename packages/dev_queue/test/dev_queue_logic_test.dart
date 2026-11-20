import 'package:dev_queue/dev_queue.dart';
import 'package:flutter_test/flutter_test.dart';

DevQueueItem item(
  String key,
  String state, {
  String code = 'up_next',
  String label = 'Up next',
  double rank = 1,
  String title = 'A request',
  bool managed = false,
  String? size,
}) =>
    DevQueueItem.fromMap(key, {
      'state': state,
      'status': {'code': code, 'label': label},
      'rank': rank,
      'title': title,
      'managed': managed,
      'size': size,
    });

void main() {
  group('visibleQueue', () {
    test('drops managed and finished items, sorts by rank', () {
      final q = visibleQueue([
        item('c', 'queued', rank: 3),
        item('a', 'building', rank: 1),
        item('m', 'queued', rank: 0, managed: true),
        item('l', 'live', rank: 0),
        item('b', 'failed', rank: 2),
      ]);
      expect(q.map((i) => i.key), ['a', 'b', 'c']);
    });
  });

  group('chipPrimaryItem', () {
    test('waiting on you comes first, by rank', () {
      final q = visibleQueue([
        item('build', 'building', rank: 1),
        item('wait2', 'awaiting_user', rank: 5),
        item('wait1', 'awaiting_user', rank: 4),
      ]);
      expect(chipPrimaryItem(q)!.key, 'wait1');
    });
    test('then the most advanced in-flight item', () {
      final q = visibleQueue([
        item('build', 'building', rank: 1),
        item('check', 'checking', rank: 2),
        item('review', 'in_review', rank: 3),
        item('queued', 'queued', rank: 0),
      ]);
      expect(chipPrimaryItem(q)!.key, 'review');
      expect(chipPrimaryItem(visibleQueue([item('m', 'merged', rank: 9), item('r', 'in_review')]))!.key, 'm');
    });
    test('then the first in Up next', () {
      expect(chipPrimaryItem(visibleQueue([item('b', 'queued', rank: 2), item('a', 'failed', rank: 1)]))!.key, 'a');
    });
    test('null for an empty queue', () => expect(chipPrimaryItem(const []), isNull));
  });

  group('chipCopy', () {
    final queue = visibleQueue([
      item('b', 'building', code: 'building', label: 'Building', title: 'Export the monthly report to CSV', rank: 1),
      item('q1', 'queued', rank: 2),
      item('q2', 'queued', rank: 3),
      item('q3', 'failed', rank: 4),
    ]);

    test('wide: label, title cut at 28, and how many wait', () {
      final copy = chipCopy(queue, wide: true);
      expect(copy.text, 'Building: Export the monthly report t… · +3 waiting');
      expect(copy.semanticsLabel, 'Your queue. Building: Export the monthly report to CSV. 3 more waiting.');
      expect(copy.needsYou, isFalse);
    });
    test('narrow: label and count', () {
      expect(chipCopy(queue, wide: false).text, 'Building · +3');
    });
    test('no count when nothing else waits', () {
      final one = visibleQueue([item('b', 'building', code: 'building', label: 'Building', title: 'Short')]);
      expect(chipCopy(one, wide: true).text, 'Building: Short');
      expect(chipCopy(one, wide: false).text, 'Building');
      expect(chipCopy(one, wide: true).semanticsLabel, 'Your queue. Building: Short.');
    });
    test('the primary queued item is not counted as waiting', () {
      final q = visibleQueue([item('a', 'queued', rank: 1, title: 'A'), item('b', 'queued', rank: 2)]);
      expect(chipCopy(q, wide: true).text, 'Up next: A · +1 waiting');
    });
    test('Waiting on you and Ready to try use the accent', () {
      for (final code in ['waiting_on_you', 'ready_to_try']) {
        final q = visibleQueue([item('w', 'awaiting_user', code: code, label: 'x')]);
        expect(chipCopy(q, wide: true).needsYou, isTrue, reason: code);
      }
    });
    for (final stage in [
      ['checking', 'checking', 'Checking'],
      ['in_review', 'final_review', 'Final review'],
      ['merged', 'final_review', 'Final review'],
      ['awaiting_user', 'ready_to_try', 'Ready to try'],
      ['awaiting_user', 'waiting_on_you', 'Waiting on you'],
      ['queued', 'waiting_for_slot', 'Waiting for your developer agent'],
    ]) {
      test('shows the ${stage[2]} label', () {
        final q = visibleQueue([item('x', stage[0], code: stage[1], label: stage[2], title: 'T')]);
        expect(chipCopy(q, wide: true).text, '${stage[2]}: T');
        expect(chipCopy(q, wide: false).text, stage[2]);
      });
    }
    test('empty', () {
      expect(chipCopy(const [], wide: true).text, 'Your queue is empty');
      expect(chipCopy(const [], wide: false).text, 'Queue');
      expect(chipCopy(const [], wide: true).empty, isTrue);
    });
  });

  group('shouldShowDevQueueChip', () {
    test('shows for a signed-in member', () {
      expect(shouldShowDevQueueChip(signedIn: true, isGuest: false, groupDevQueueMode: null), isTrue);
      expect(shouldShowDevQueueChip(signedIn: true, isGuest: false, groupDevQueueMode: 'pool'), isTrue);
    });
    test('hidden for guests, signed out, and in managed groups', () {
      expect(shouldShowDevQueueChip(signedIn: true, isGuest: true, groupDevQueueMode: null), isFalse);
      expect(shouldShowDevQueueChip(signedIn: false, isGuest: false, groupDevQueueMode: null), isFalse);
      expect(shouldShowDevQueueChip(signedIn: true, isGuest: false, groupDevQueueMode: 'managed'), isFalse);
    });
  });

  group('positions and reordering', () {
    final queue = visibleQueue([
      item('b1', 'building', rank: 1),
      item('q1', 'queued', rank: 2),
      item('w1', 'awaiting_user', rank: 3),
      item('q2', 'queued', rank: 4),
      item('q3', 'failed', rank: 5),
    ]);

    test('positions count in-flight items too', () {
      expect(queuePositions(queue), {'b1': 1, 'q1': 2, 'w1': 3, 'q2': 4, 'q3': 5});
    });
    test('a local order fills the Up next slots', () {
      final local = applyLocalOrder(upNextItems(queue), ['q3', 'q1', 'q2']);
      expect(local.map((i) => i.key), ['q3', 'q1', 'q2']);
      expect(queuePositionsWithOrder(queue, local), {'b1': 1, 'q3': 2, 'w1': 3, 'q1': 4, 'q2': 5});
    });
    test('applyLocalOrder drops gone keys and keeps new ones', () {
      final local = applyLocalOrder(upNextItems(queue), ['gone', 'q2', 'q1']);
      expect(local.map((i) => i.key), ['q2', 'q1', 'q3']);
      expect(applyLocalOrder(upNextItems(queue), null).map((i) => i.key), ['q1', 'q2', 'q3']);
    });
    test('moveKeyTo moves to top, up and down', () {
      const keys = ['a', 'b', 'c', 'd'];
      expect(moveKeyTo(keys, 2, 0), ['c', 'a', 'b', 'd']);
      expect(moveKeyTo(keys, 2, 1), ['a', 'c', 'b', 'd']);
      expect(moveKeyTo(keys, 1, 2), ['a', 'c', 'b', 'd']);
      expect(moveKeyTo(keys, 3, 9), keys);
      expect(moveKeyTo(keys, 7, 0), keys);
    });
  });

  group('formatQueueDay', () {
    final now = DateTime(2026, 11, 8, 9); // a Sunday
    test('today', () => expect(formatQueueDay(DateTime(2026, 11, 8, 17), now: now), 'today'));
    test('weekday names within 6 days', () {
      expect(formatQueueDay(DateTime(2026, 11, 10), now: now), 'Tuesday');
      expect(formatQueueDay(DateTime(2026, 11, 14), now: now), 'Saturday');
      expect(formatQueueDay(DateTime(2026, 11, 5), now: now), 'Thursday');
    });
    test('month and day after that', () {
      expect(formatQueueDay(DateTime(2026, 11, 15), now: now), 'Nov 15');
      expect(formatQueueDay(DateTime(2026, 10, 1), now: now), 'Oct 1');
    });
  });

  group('copy', () {
    test('the confirmation carries the estimate line', () {
      expect(
        addedToQueueMessage(
            3,
            const DevEstimate(
                size: 'S', short: 'Small', line: 'Often ready within a few days once it starts')),
        'Added to your queue: #3. Often ready within a few days once it starts.',
      );
      expect(
        addedToQueueMessage(2, const DevEstimate(size: 'L', short: 'Large', line: "We're aiming for Nov 14")),
        "Added to your queue: #2. We're aiming for Nov 14.",
      );
      // A line that already ends a sentence gets no second full stop.
      expect(addedToQueueMessage(1, const DevEstimate(short: 'Medium', line: 'Soon.')), 'Added to your queue: #1. Soon.');
      expect(addedToQueueMessage(1, null), 'Added to your queue: #1.');
      expect(addedToQueueMessage(4, const DevEstimate(short: 'Small')), 'Added to your queue: #4.');
    });
    test('the estimate line shows on Now cards while Building or Checking', () {
      DevQueueItem item(String state, {bool sized = true}) => DevQueueItem.fromMap('bug__x', {
            'state': state,
            if (sized) 'estimate': {'size': 'M', 'short': 'Medium', 'line': 'Takes a little longer than a small change'},
          });
      expect(showsEstimateLine(item('building')), isTrue);
      expect(showsEstimateLine(item('checking')), isTrue);
      expect(showsEstimateLine(item('in_review')), isFalse);
      expect(showsEstimateLine(item('awaiting_user')), isFalse);
      expect(showsEstimateLine(item('building', sized: false)), isFalse);
    });
    test('the held-slot line', () {
      final now = DateTime(2026, 11, 8, 9);
      expect(
        waitingSlotLine(DevWaiting(reason: DevWaitingReason.clarification, deadline: DateTime(2026, 11, 10)), now: now),
        "We're holding your spot until Tuesday.",
      );
      expect(
        waitingSlotLine(const DevWaiting(reason: DevWaitingReason.clarification, slotReleased: true), now: now),
        'Your spot went to your next request. Answer and this goes back to the front of your queue.',
      );
    });
    test('shipped lines', () {
      final now = DateTime(2026, 11, 8, 9);
      final live = DevQueueItem.fromMap('l', {'state': 'live', 'stateChangedAt': DateTime(2026, 11, 6)});
      expect(shippedLine(live, now: now), 'Live since Friday');
      final declined = DevQueueItem.fromMap('d', {
        'state': 'declined',
        'closure': {'reasonLabel': 'Not planned'},
      });
      expect(shippedLine(declined), 'Declined: Not planned');
      expect(shippedLine(DevQueueItem.fromMap('c', {'state': 'closed'})), 'Closed');
    });
    test('shippedItems keeps live ones and the last 30 days of the rest', () {
      final now = DateTime(2026, 11, 8);
      final items = [
        DevQueueItem.fromMap('old-live', {'state': 'live', 'stateChangedAt': DateTime(2026, 1, 1)}),
        DevQueueItem.fromMap('new-live', {'state': 'live', 'stateChangedAt': DateTime(2026, 11, 7)}),
        DevQueueItem.fromMap('old-declined', {'state': 'declined', 'stateChangedAt': DateTime(2026, 9, 1)}),
        DevQueueItem.fromMap('new-closed', {'state': 'closed', 'stateChangedAt': DateTime(2026, 11, 1)}),
        DevQueueItem.fromMap('managed', {'state': 'live', 'managed': true, 'stateChangedAt': DateTime(2026, 11, 7)}),
      ];
      expect(shippedItems(items, now: now).map((i) => i.key), ['new-live', 'new-closed', 'old-live']);
    });
    test('shippedItems with a group keeps that group\'s items for its apps', () {
      final now = DateTime(2026, 11, 8);
      DevQueueItem live(String key, Map<String, Object?> fields) =>
          DevQueueItem.fromMap(key, {'state': 'live', 'stateChangedAt': DateTime(2026, 11, 7), ...fields});
      final items = [
        live('here', {'groupId': 'g1', 'relatedAppId': 'notes'}),
        live('launcher', {'groupId': 'g1', 'relatedAppId': ''}),
        live('other-group', {'groupId': 'g2', 'relatedAppId': 'notes'}),
        live('not-installed', {'groupId': 'g1', 'relatedAppId': 'chess'}),
        live('shipped-elsewhere', {'groupId': 'g1', 'relatedAppId': 'notes', 'shippedAppId': 'chess'}),
        live('new-app', {'groupId': 'g1', 'itemType': 'app', 'relatedAppId': 'chess', 'shippedAppId': 'polls'}),
      ];
      final kept = shippedItems(items, now: now, groupId: 'g1', isInstalled: (id) => id == 'notes' || id == 'polls');
      expect(kept.map((i) => i.key), ['here', 'launcher', 'new-app']);
    });
    test('team and bonus lines', () {
      final now = DateTime(2026, 11, 8, 9);
      expect(
        teamShippedLine(TeamShippedItem(itemKey: 'k', title: 'T', requesterName: 'Sam', liveAt: DateTime(2026, 11, 6)), now: now),
        'Asked for by Sam · Live since Friday',
      );
      expect(teamShippedLine(const TeamShippedItem(itemKey: 'k', title: 'T')), 'Live');
      expect(
        bonusChangeLine(BonusChange(id: 'r', title: 'x', apps: const [(appId: 'notes', name: 'Notes')], liveAt: DateTime(2026, 11, 8)), now: now),
        'Notes · today',
      );
    });
  });

  group('stage tracker', () {
    test('Ready to try only with a preview or an approval wait', () {
      expect(stagesFor(item('b', 'building')), isNot(contains(DevStage.readyToTry)));
      final withPreview = DevQueueItem.fromMap('p', {
        'state': 'in_review',
        'preview': {'url': 'https://x'},
      });
      expect(stagesFor(withPreview), contains(DevStage.readyToTry));
      expect(currentStage(withPreview), DevStage.finalReview);
      final waiting = DevQueueItem.fromMap('w', {
        'state': 'awaiting_user',
        'waiting': {'reason': 'preview_approval'},
      });
      expect(currentStage(waiting), DevStage.readyToTry);
    });
    test('current step per state', () {
      expect(currentStage(item('a', 'building')), DevStage.building);
      expect(currentStage(item('a', 'checking')), DevStage.checking);
      expect(currentStage(item('a', 'merged')), DevStage.finalReview);
      expect(currentStage(item('a', 'live')), DevStage.live);
    });
  });
}
