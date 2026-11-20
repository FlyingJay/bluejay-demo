import 'dart:async';

import 'package:dev_queue/dev_queue.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;

import '../fakes.dart';

/// The clock fixtures are built against.
final fixtureNow = DateTime(2026, 11, 9, 10);

/// A signed-in member.
class FakeUser implements fire_auth.User {
  @override
  String get uid => 'u1';
  @override
  bool get isAnonymous => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _smallEstimate = {
  'size': 'S',
  'short': 'Small',
  'line': 'Often ready within a few days once it starts',
};

/// A full queue: one item ready to try, one building, three in Up next
/// (one a regression fix) and two in Shipped.
Future<FakeQueue> seededQueue() async {
  final q = FakeQueue();
  await q.addItem('feature__ready', {
    ...itemFields(
      state: 'awaiting_user',
      code: 'ready_to_try',
      label: 'Ready to try',
      detail: 'Try it and tell us if it works for you',
      title: 'Export reports to CSV',
      rank: 1,
      waiting: {'reason': 'preview_approval', 'sha': 'sha1', 'previewUrl': 'https://preview.example'},
    ),
    'itemType': 'feature',
    'itemId': 'ready',
    'startedAt': DateTime(2026, 11, 6),
  });
  await q.addItem('feature__build', {
    ...itemFields(
      state: 'building',
      code: 'building',
      label: 'Building',
      detail: 'Writing the change',
      title: 'Dark mode for Notes',
      rank: 2,
    ),
    'itemType': 'feature',
    'itemId': 'build',
    'estimate': _smallEstimate,
    'startedAt': DateTime(2026, 11, 8),
  });
  await q.addItem('bug__fix', {
    ...itemFields(state: 'queued', code: 'up_next', label: 'Up next', title: 'Summary email is blank', rank: 3),
    'itemType': 'bug',
    'itemId': 'fix',
    'expedite': true,
    'estimate': _smallEstimate,
  });
  await q.addItem('feature__q2', {
    ...itemFields(state: 'queued', code: 'up_next', label: 'Up next', title: 'Weekly digest of new tasks', rank: 4),
    'itemType': 'feature',
    'itemId': 'q2',
    'estimate': {'size': 'M', 'short': 'Medium', 'line': 'Usually a few business days'},
  });
  await q.addItem('feature__q3', {
    ...itemFields(
      state: 'queued',
      code: 'waiting_for_slot',
      label: 'Waiting for your developer agent',
      title: 'Bulk-assign tasks from the board',
      rank: 5,
    ),
    'itemType': 'feature',
    'itemId': 'q3',
  });
  await q.addItem('feature__live', {
    ...itemFields(
      state: 'live',
      code: 'live',
      label: 'Live',
      title: 'Pin notes to the top',
      active: false,
      stateChangedAt: DateTime(2026, 11, 3),
      shippedAppId: 'notes',
    ),
    'itemType': 'feature',
    'itemId': 'live',
  });
  await q.addItem('feature__declined', {
    ...itemFields(
      state: 'declined',
      code: 'declined',
      label: 'Declined',
      title: 'Sync with a paper notebook',
      active: false,
      stateChangedAt: DateTime(2026, 11, 1),
      closure: {'reasonLabel': 'Not something we can build'},
    ),
    'itemType': 'feature',
    'itemId': 'declined',
  });
  return q;
}

/// A queue with nothing in it.
FakeQueue emptyQueue() => FakeQueue();

/// A service whose queue streams never answer, for the first-load state.
class PendingQueueService extends DevQueueService {
  PendingQueueService(FakeQueue base)
      : super(firestore: base.firestore, call: (n, d) async => {'groups': <Object?>[]});

  @override
  Stream<List<DevQueueItem>> watchActive(String uid) => StreamController<List<DevQueueItem>>().stream;

  @override
  Stream<List<DevQueueItem>> watchFinished(String uid) => StreamController<List<DevQueueItem>>().stream;
}

/// A service whose queue stream fails.
class FailingQueueService extends DevQueueService {
  FailingQueueService(FakeQueue base)
      : super(firestore: base.firestore, call: (n, d) async => {'groups': <Object?>[]});

  @override
  Stream<List<DevQueueItem>> watchActive(String uid) => Stream.error(StateError('unavailable'));
}

/// A live item, for the "What broke?" sheet.
DevQueueItem liveItem() => DevQueueItem.fromMap('feature__live', {
      ...itemFields(
        state: 'live',
        code: 'live',
        label: 'Live',
        title: 'Pin notes to the top',
        active: false,
        stateChangedAt: DateTime(2026, 11, 3),
      ),
      'itemType': 'feature',
      'itemId': 'live',
    });

/// A status for every code, with the server's label and a sample detail.
List<DevStatus> sampleStatuses() => [
      for (final code in DevStatusCode.values)
        if (code != DevStatusCode.unknown)
          DevStatus(
            code: code,
            label: code.defaultLabel,
            detail: code == DevStatusCode.waitingOnYou ? 'We have a question for you' : '',
          ),
    ];

/// Chip copy for each look: needs you, in progress, empty.
const sampleChipCopies = [
  DevQueueChipCopy(
    text: 'Ready to try: Export reports to CSV · +3 waiting',
    semanticsLabel: 'needs you',
    needsYou: true,
  ),
  DevQueueChipCopy(text: 'Building: Dark mode for Notes · +2 waiting', semanticsLabel: 'building'),
  DevQueueChipCopy(text: 'Your queue is empty', semanticsLabel: 'empty', empty: true),
];
