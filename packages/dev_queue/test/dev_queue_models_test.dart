import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DevItemState.parse', () {
    const wire = {
      'queued': DevItemState.queued,
      'building': DevItemState.building,
      'checking': DevItemState.checking,
      'in_review': DevItemState.inReview,
      'merged': DevItemState.merged,
      'awaiting_user': DevItemState.awaitingUser,
      'failed': DevItemState.failed,
      'live': DevItemState.live,
      'declined': DevItemState.declined,
      'closed': DevItemState.closed,
    };
    for (final entry in wire.entries) {
      test('parses ${entry.key}', () => expect(DevItemState.parse(entry.key), entry.value));
    }
    test('an unknown or missing state is unknown', () {
      expect(DevItemState.parse('teleporting'), DevItemState.unknown);
      expect(DevItemState.parse(null), DevItemState.unknown);
    });
    test('sections', () {
      expect(DevItemState.values.where((s) => s.isInFlight).toSet(), {
        DevItemState.building,
        DevItemState.checking,
        DevItemState.inReview,
        DevItemState.merged,
        DevItemState.awaitingUser,
      });
      expect(DevItemState.values.where((s) => s.isWaitingForWork).toSet(), {DevItemState.queued, DevItemState.failed});
      expect(DevItemState.values.where((s) => s.isTerminal).toSet(),
          {DevItemState.live, DevItemState.declined, DevItemState.closed});
    });
  });

  group('DevStatusCode.parse', () {
    const wire = {
      'up_next': DevStatusCode.upNext,
      'waiting_for_slot': DevStatusCode.waitingForSlot,
      'received': DevStatusCode.received,
      'building': DevStatusCode.building,
      'checking': DevStatusCode.checking,
      'waiting_on_you': DevStatusCode.waitingOnYou,
      'ready_to_try': DevStatusCode.readyToTry,
      'final_review': DevStatusCode.finalReview,
      'live': DevStatusCode.live,
      'declined': DevStatusCode.declined,
      'closed': DevStatusCode.closed,
    };
    for (final entry in wire.entries) {
      test('parses ${entry.key} and writes it back', () {
        expect(DevStatusCode.parse(entry.key), entry.value);
        expect(entry.value.wire, entry.key);
        expect(entry.value.defaultLabel, isNotEmpty);
      });
    }
    test('only Waiting on you and Ready to try need the person', () {
      expect(DevStatusCode.values.where((c) => c.needsYou).toSet(),
          {DevStatusCode.waitingOnYou, DevStatusCode.readyToTry});
    });
  });

  group('DevStatus.fromMap', () {
    test('reads the mirror', () {
      final s = DevStatus.fromMap({
        'code': 'building',
        'label': 'Building',
        'detail': 'Making your tweak',
        'since': Timestamp.fromDate(DateTime(2026, 11, 7)),
        'previewUrl': 'https://p.example',
      })!;
      expect(s.code, DevStatusCode.building);
      expect(s.label, 'Building');
      expect(s.detail, 'Making your tweak');
      expect(s.since, DateTime(2026, 11, 7));
      expect(s.previewUrl, 'https://p.example');
    });
    test('an unknown code renders the server label', () {
      final s = DevStatus.fromMap({'code': 'on_the_moon', 'label': 'On the moon'})!;
      expect(s.code, DevStatusCode.unknown);
      expect(s.label, 'On the moon');
      expect(s.rawCode, 'on_the_moon');
    });
    test('a known code with no label gets the default label', () {
      expect(DevStatus.fromMap({'code': 'ready_to_try'})!.label, 'Ready to try');
    });
    test('null without a code', () {
      expect(DevStatus.fromMap(null), isNull);
      expect(DevStatus.fromMap({'label': 'x'}), isNull);
      expect(DevStatus.fromMap('building'), isNull);
    });
  });

  group('DevQueueItem.fromMap', () {
    test('reads every contract field', () {
      final item = DevQueueItem.fromMap('bug__b1', {
        'itemType': 'bug',
        'itemId': 'b1',
        'title': 'Export to CSV',
        'relatedAppId': 'habit-tracker',
        'payload': {
          'ticket': {'relatedAppName': 'Habit Tracker'},
        },
        'groupId': 'bluejay',
        'state': 'awaiting_user',
        'status': {'code': 'ready_to_try', 'label': 'Ready to try', 'detail': ''},
        'rank': 1700000000000,
        'managed': false,
        'hold': {'reason': 'triage'},
        'waiting': {
          'reason': 'preview_approval',
          'askedBy': 'agent',
          'sha': 'abc123',
          'previewUrl': 'https://preview',
          'since': Timestamp.fromDate(DateTime(2026, 11, 6)),
          'deadline': Timestamp.fromDate(DateTime(2026, 11, 10)),
          'slotReleasedAt': null,
        },
        'preview': {'url': 'https://preview', 'current': true, 'sha': 'abc123'},
        'conversation': [
          {'kind': 'question', 'text': 'Which columns?', 'by': 'agent'},
          {'kind': 'answer', 'text': 'All of them', 'by': 'u1'},
        ],
        'approval': {'sha': 'abc123', 'by': 'u1'},
        'closure': {'reasonCode': 'duplicate', 'reasonLabel': 'Duplicate ticket'},
        'shippedAppId': 'habit-tracker',
        'size': 's',
        'createdAt': Timestamp.fromDate(DateTime(2026, 11, 1)),
        'stateChangedAt': Timestamp.fromDate(DateTime(2026, 11, 6)),
      });
      expect(item.key, 'bug__b1');
      expect(item.itemType, 'bug');
      expect(item.appName, 'Habit Tracker');
      expect(item.state, DevItemState.awaitingUser);
      expect(item.status.code, DevStatusCode.readyToTry);
      expect(item.rank, 1700000000000);
      expect(item.holdReason, 'triage');
      expect(item.waiting!.reason, DevWaitingReason.previewApproval);
      expect(item.waiting!.sha, 'abc123');
      expect(item.waiting!.deadline, DateTime(2026, 11, 10));
      expect(item.waiting!.slotReleased, isFalse);
      expect(item.previewUrl, 'https://preview');
      expect(item.previewCurrent, isTrue);
      expect(item.conversation.map((c) => c.kind), ['question', 'answer']);
      expect(item.approvedSha, 'abc123');
      expect(item.closureLabel, 'Duplicate ticket');
      expect(item.shippedAppId, 'habit-tracker');
      expect(item.size, 'S');
      expect(item.isAwaitingApproval, isTrue);
      expect(item.isAwaitingAnswer, isFalse);
      expect(item.tryUrl, 'https://preview');
    });

    test('a released clarification', () {
      final item = DevQueueItem.fromMap('feature__f1', {
        'state': 'awaiting_user',
        'waiting': {
          'reason': 'clarification',
          'askedBy': 'staff',
          'question': 'Which report?',
          'slotReleasedAt': Timestamp.now(),
        },
      });
      expect(item.isAwaitingAnswer, isTrue);
      expect(item.waiting!.askedByStaff, isTrue);
      expect(item.waiting!.slotReleased, isTrue);
      // No status on the doc: a label from the state.
      expect(item.status.label, 'Waiting on you');
    });

    test('missing and odd values fall back safely', () {
      final item = DevQueueItem.fromMap('x', {'state': 'warp', 'size': 'XL', 'waiting': 'nope'});
      expect(item.state, DevItemState.unknown);
      expect(item.size, isNull);
      expect(item.waiting, isNull);
      expect(item.displayTitle, 'Untitled request');
      expect(item.appName, '');
    });

    test('an app name from the id when the ticket has none', () {
      expect(DevQueueItem.fromMap('k', {'state': 'queued', 'relatedAppId': 'habit-tracker'}).appName, 'Habit Tracker');
    });

    test('item keys match the server', () {
      expect(devQueueItemKey('bug', 'abc'), 'bug__abc');
    });
  });

  group('Phase 2.5 fields', () {
    test('parses the estimate, sizing, start, expedite and regressions', () {
      final item = DevQueueItem.fromMap('bug__reg_1', {
        'state': 'queued',
        'itemType': 'bug',
        'size': 'l',
        'sizing': {'source': 'admin', 'reason': 'Touches payments', 'by': 'u9'},
        'targetDate': Timestamp.fromDate(DateTime(2026, 11, 20)),
        'estimate': {'size': 'L', 'short': 'Large', 'line': "We're aiming for Nov 20"},
        'startedAt': Timestamp.fromDate(DateTime(2026, 11, 6, 9)),
        'expedite': true,
        'regressionOf': {'itemKey': 'feature__f1', 'title': 'CSV export', 'prNumber': 12, 'prUrl': 'https://x'},
        'regressions': ['bug__r1', '', 4],
        'grants': 2,
      });
      expect(item.size, 'L');
      expect(item.sizeSource, 'admin');
      expect(item.targetDate, DateTime(2026, 11, 20));
      expect(item.estimate!.short, 'Large');
      expect(item.estimate!.line, "We're aiming for Nov 20");
      expect(item.startedAt, DateTime(2026, 11, 6, 9));
      expect(item.expedite, isTrue);
      expect(item.regressionOf!.itemKey, 'feature__f1');
      expect(item.regressionOf!.title, 'CSV export');
      expect(item.regressions, ['bug__r1']);
      expect(item.grants, 2);
    });

    test('missing fields parse to their defaults', () {
      final item = DevQueueItem.fromMap('bug__a', {'state': 'queued', 'estimate': null, 'regressionOf': 'x'});
      expect(item.estimate, isNull);
      expect(item.sizeSource, '');
      expect(item.startedAt, isNull);
      expect(item.expedite, isFalse);
      expect(item.regressionOf, isNull);
      expect(item.regressions, isEmpty);
      expect(item.grants, 0);
    });

    DevQueueItem make(String state, {DateTime? startedAt, bool managed = false, String itemType = 'feature'}) =>
        DevQueueItem.fromMap('${itemType}__a', {
          'state': state,
          'itemType': itemType,
          'managed': managed,
          if (startedAt != null) 'startedAt': Timestamp.fromDate(startedAt),
        });

    test('canEdit: queued, never started, not managed', () {
      expect(make('queued').canEdit, isTrue);
      expect(make('queued', startedAt: DateTime(2026, 11, 1)).canEdit, isFalse);
      expect(make('queued', managed: true).canEdit, isFalse);
      for (final state in ['building', 'checking', 'awaiting_user', 'failed', 'merged', 'live']) {
        expect(make(state).canEdit, isFalse, reason: state);
      }
    });

    test('canWithdraw: active and not merged or managed', () {
      for (final state in ['queued', 'failed', 'building', 'checking', 'in_review', 'awaiting_user']) {
        expect(make(state).canWithdraw, isTrue, reason: state);
      }
      for (final state in ['merged', 'live', 'declined', 'closed', 'teleporting']) {
        expect(make(state).canWithdraw, isFalse, reason: state);
      }
      expect(make('queued', managed: true).canWithdraw, isFalse);
    });

    test('isStarted: once granted, or past Up next', () {
      expect(make('queued').isStarted, isFalse);
      expect(make('queued', startedAt: DateTime(2026, 11, 1)).isStarted, isTrue);
      expect(make('building').isStarted, isTrue);
      expect(make('failed').isStarted, isTrue);
    });

    group('canReportRegression', () {
      final now = DateTime(2026, 12, 1, 12);
      DevQueueItem live({DateTime? at, List<String> regressions = const [], String itemType = 'feature', bool managed = false}) =>
          DevQueueItem.fromMap('${itemType}__a', {
            'state': 'live',
            'itemType': itemType,
            'managed': managed,
            'stateChangedAt': Timestamp.fromDate(at ?? DateTime(2026, 11, 20)),
            'regressions': regressions,
          });

      test('within 30 days of going live', () {
        expect(live(at: now.subtract(const Duration(days: 29, hours: 23))).canReportRegression(now: now), isTrue);
        expect(live(at: now.subtract(const Duration(days: 30))).canReportRegression(now: now), isTrue);
        expect(live(at: now.subtract(const Duration(days: 30, minutes: 1))).canReportRegression(now: now), isFalse);
      });
      test('one open report per item', () {
        final item = live(regressions: ['bug__reg_1']);
        expect(item.canReportRegression(now: now, activeKeys: {'bug__reg_1'}), isFalse);
        expect(item.openRegressionKey({'bug__reg_1'}), 'bug__reg_1');
        // The earlier report finished: another can be filed.
        expect(item.canReportRegression(now: now, activeKeys: {'bug__other'}), isTrue);
      });
      test('never for tasks, managed items or items that are not live', () {
        expect(live(itemType: 'task').canReportRegression(now: now), isFalse);
        expect(live(managed: true).canReportRegression(now: now), isFalse);
        expect(make('queued').canReportRegression(now: now), isFalse);
        expect(DevQueueItem.fromMap('bug__x', {'state': 'live'}).canReportRegression(now: now), isFalse);
      });
    });
  });

  group('DevQueueMetrics.fromResult', () {
    test('parses the callable result', () {
      final m = DevQueueMetrics.fromResult({
        'weeks': [
          {'weekStart': '2026-10-26', 'shipped': 3},
          {'weekStart': '2026-11-02', 'shipped': 5},
        ],
        'bySize': [
          {'size': 'S', 'targetDays': 1, 'medianBusinessDays': 0.5, 'count': 4},
          {'size': 'L', 'targetDays': null, 'medianBusinessDays': 9, 'count': 1},
        ],
        'stalledNow': {
          'count': 1,
          'items': [
            {'itemKey': 'bug__b1', 'title': 'Totals', 'state': 'building', 'since': '2026-11-01T10:00:00Z', 'thresholdDays': 2},
          ],
        },
        'stallRate': {'shipped': 8, 'stalled': 1, 'rate': 0.125},
        'platform': {
          'shipped': 4,
          'weeks': [
            {'weekStart': '2026-10-26', 'shipped': 1},
            {'weekStart': '2026-11-02', 'shipped': 3},
          ],
          'bySource': [
            {'source': 'advisor-round', 'label': 'Advisor rounds', 'shipped': 3},
            {'source': 'other', 'shipped': 1},
            {'label': 'No id'},
          ],
        },
      });
      expect(m.platformShipped, 4);
      expect(m.platformBySource.map((s) => (s.source, s.label, s.shipped)), [
        ('advisor-round', 'Advisor rounds', 3),
        ('other', 'other', 1),
      ]);
      expect(m.weeks.map((w) => w.shipped), [3, 5]);
      expect(m.weeks.first.start, DateTime(2026, 10, 26));
      expect(m.totalShipped, 8);
      expect(m.bySize.first.medianBusinessDays, 0.5);
      expect(m.bySize.last.targetDays, isNull);
      expect(m.stalledCount, 1);
      expect(m.stalled.single.ticket, ('bug', 'b1'));
      expect(m.stalled.single.since!.toUtc(), DateTime.utc(2026, 11, 1, 10));
      expect(m.stallRatePercent, 13);
      expect(m.isEmpty, isFalse);
    });
    test('empty or malformed data is empty, with a 0% rate', () {
      for (final raw in [null, <String, Object?>{}, {'weeks': 'x', 'stallRate': {'shipped': 0, 'stalled': 0}}]) {
        final m = DevQueueMetrics.fromResult(raw);
        expect(m.isEmpty, isTrue);
        expect(m.stallRatePercent, 0);
        expect(m.weeks, isEmpty);
      }
      final zeros = DevQueueMetrics.fromResult({
        'weeks': [
          {'weekStart': '2026-11-02', 'shipped': 0},
        ],
      });
      expect(zeros.isEmpty, isTrue);
      final platformOnly = DevQueueMetrics.fromResult({
        'platform': {
          'weeks': [
            {'weekStart': '2026-11-02', 'shipped': 2},
          ],
        },
      });
      expect(platformOnly.totalShipped, 0);
      expect(platformOnly.isEmpty, isFalse);
    });
  });

  group('ManagedQueueGroup.listFromResult', () {
    test('parses the callable result', () {
      final groups = ManagedQueueGroup.listFromResult({
        'groups': [
          {
            'groupId': 'acme',
            'name': 'Acme',
            'items': [
              {
                'itemKey': 'bug__b1',
                'itemType': 'bug',
                'itemId': 'b1',
                'title': 'Totals are wrong',
                'submitterName': 'Ada',
                'excerpt': 'The totals row',
                'createdAt': '2026-11-05T12:00:00.000Z',
                'held': true,
                'status': {'code': 'received', 'label': 'Received', 'detail': ''},
              },
            ],
          },
        ],
      });
      expect(groups, hasLength(1));
      expect(groups.single.name, 'Acme');
      final item = groups.single.items.single;
      expect(item.held, isTrue);
      expect(item.createdAt!.toUtc(), DateTime.utc(2026, 11, 5, 12));
      expect(item.status!.code, DevStatusCode.received);
    });
    test('empty for anything else', () {
      expect(ManagedQueueGroup.listFromResult(null), isEmpty);
      expect(ManagedQueueGroup.listFromResult({'groups': 'x'}), isEmpty);
    });
  });
}
