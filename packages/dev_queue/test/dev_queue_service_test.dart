import 'package:dev_queue/dev_queue.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('callables', () {
    test('answer sends the item, the trimmed answer and the key', () async {
      final q = FakeQueue();
      await q.service.answer('bug__b1', '  All columns  ', idempotencyKey: 'k1');
      expect(q.calls.single.name, 'devQueueAnswer');
      expect(q.calls.single.data, {'itemKey': 'bug__b1', 'answer': 'All columns', 'idempotencyKey': 'k1'});
    });

    test('approvePreview sends the sha', () async {
      final q = FakeQueue();
      await q.service.approvePreview('feature__f1', 'abc123');
      expect(q.calls.single.name, 'devQueueApprovePreview');
      expect(q.calls.single.data, {'itemKey': 'feature__f1', 'sha': 'abc123'});
    });

    test('requestTweak sends sha, text and a key', () async {
      final q = FakeQueue();
      await q.service.requestTweak('feature__f1', 'abc123', 'Bigger button ');
      expect(q.calls.single.name, 'devQueueRequestTweak');
      expect(q.calls.single.data, {
        'itemKey': 'feature__f1',
        'sha': 'abc123',
        'text': 'Bigger button',
        'idempotencyKey': 'key-0',
      });
    });

    test('reorder sends the whole order', () async {
      final q = FakeQueue()..respond = (call) => {'success': true, 'orderedKeys': call.data['orderedKeys']};
      final keys = await q.service.reorder(['a', 'b', 'c']);
      expect(q.calls.single.name, 'devQueueReorder');
      expect(q.calls.single.data, {
        'orderedKeys': ['a', 'b', 'c'],
      });
      expect(keys, ['a', 'b', 'c']);
    });

    test('listManaged and sendToPipeline', () async {
      final q = FakeQueue()
        ..respond = (call) => call.name == 'devQueueListManaged'
            ? {
                'groups': [
                  {'groupId': 'acme', 'name': 'Acme', 'items': <Object?>[]},
                ],
              }
            : {'success': true};
      final groups = await q.service.listManaged();
      expect(groups.single.groupId, 'acme');
      await q.service.sendToPipeline('bug', 'b1');
      expect(q.calls.map((c) => c.name), ['devQueueListManaged', 'devQueueSendToPipeline']);
      expect(q.calls.last.data, {'itemType': 'bug', 'itemId': 'b1'});
    });
  });

  group('Phase 2.5 callables', () {
    test('editRequest sends only the fields given, trimmed', () async {
      final q = FakeQueue();
      await q.service.editRequest('feature__f1', title: '  New title ');
      await q.service.editRequest('bug__b1', description: ' Crashes on save ');
      expect(q.calls[0].name, 'devQueueEditRequest');
      expect(q.calls[0].data, {'itemKey': 'feature__f1', 'title': 'New title'});
      expect(q.calls[1].data, {'itemKey': 'bug__b1', 'description': 'Crashes on save'});
    });

    test('withdraw sends confirmStarted only when confirmed', () async {
      final q = FakeQueue();
      await q.service.withdraw('bug__b1');
      await q.service.withdraw('bug__b2', confirmStarted: true);
      expect(q.calls.map((c) => c.name).toSet(), {'devQueueWithdraw'});
      expect(q.calls[0].data, {'itemKey': 'bug__b1'});
      expect(q.calls[1].data, {'itemKey': 'bug__b2', 'confirmStarted': true});
    });

    test('reportRegression returns the new item key', () async {
      final q = FakeQueue()..respond = (_) => {'success': true, 'itemKey': 'bug__reg_abc', 'alreadyApplied': true};
      final key = await q.service.reportRegression('feature__f1', ' Export is empty ', idempotencyKey: 'k1');
      expect(key, 'bug__reg_abc');
      expect(q.calls.single.name, 'devQueueReportRegression');
      expect(q.calls.single.data, {'itemKey': 'feature__f1', 'description': 'Export is empty', 'idempotencyKey': 'k1'});
    });

    test('setSize sends a target date with Large only', () async {
      final q = FakeQueue();
      await q.service.setSize('bug__b1', 'L', targetDate: DateTime(2026, 11, 4));
      await q.service.setSize('bug__b1', 'S', targetDate: DateTime(2026, 11, 4));
      expect(q.calls[0].data, {'itemKey': 'bug__b1', 'size': 'L', 'targetDate': '2026-11-04'});
      expect(q.calls[1].data, {'itemKey': 'bug__b1', 'size': 'S'});
    });

    test('metrics clamps the window and parses the result', () async {
      final q = FakeQueue()
        ..respond = (_) => {
              'weeks': [
                {'weekStart': '2026-11-02', 'shipped': 2},
              ],
            };
      final m = await q.service.metrics(weeks: 40);
      expect(q.calls.single.data, {'weeks': 26});
      expect(m.totalShipped, 2);
    });

    test('readTicketText reads the ticket doc by type', () async {
      final q = FakeQueue();
      await q.firestore.collection('bug_reports').doc('b1').set({'description': ' It crashes '});
      await q.firestore.collection('feature_requests').doc('f1').set({'title': 'Export', 'description': 'As CSV'});
      await q.firestore.collection('app_requests').doc('a1').set({'title': 'Tracker', 'summary': 'Tracks habits'});
      final bug = await q.service.readTicketText('bug', 'b1');
      expect((bug.title, bug.description), ('', 'It crashes'));
      final idea = await q.service.readTicketText('feature', 'f1');
      expect((idea.title, idea.description), ('Export', 'As CSV'));
      final app = await q.service.readTicketText('app', 'a1');
      expect((app.title, app.description), ('Tracker', 'Tracks habits'));
    });
  });

  group('DevQueueException', () {
    test('Phase 2.5 refusals use the design copy, whatever the server says', () {
      const copy = {
        'started': "We've already started on this, so it can't be edited now. You can ask for a tweak when it's "
            'ready to try, or withdraw it.',
        'going-live': "This is already going live, so it can't be withdrawn.",
        'already-reported': "You've already reported a problem with this. It's in your queue.",
        'too-late': 'This went live more than 30 days ago. Report a problem from the app instead.',
      };
      for (final entry in copy.entries) {
        expect(DevQueueException(entry.key, 'Server words').message, entry.value);
      }
    });
    test('details carry the named item', () {
      expect(const DevQueueException('already-reported', '', {'reason': 'already-reported', 'itemKey': 'bug__r'}).itemKey,
          'bug__r');
      expect(const DevQueueException('too-late').itemKey, isNull);
    });

    test('known reasons read plainly', () {
      expect(const DevQueueException('queue-changed').message,
          'Your queue changed while you were moving things. Try again.');
      expect(const DevQueueException('preview-changed').message, contains('newer version'));
    });
    test('the server copy wins, except for the fixed reorder message', () {
      expect(const DevQueueException('not-waiting', 'This question was already answered.').message,
          'This question was already answered.');
      expect(const DevQueueException('queue-changed', 'Server words').message,
          'Your queue changed while you were moving things. Try again.');
    });
    test('an unknown reason shows the server message', () {
      expect(const DevQueueException('internal', 'Boom').message, 'Boom');
      expect(const DevQueueException('internal').message, 'Something went wrong. Try again.');
    });
  });

  group('reads', () {
    test('watchActive returns the owner active items in rank order', () async {
      final q = FakeQueue();
      await q.addItem('b', itemFields(state: 'queued', code: 'up_next', label: 'Up next', rank: 2));
      await q.addItem('a', itemFields(state: 'building', code: 'building', label: 'Building', rank: 1));
      await q.addItem('done', itemFields(state: 'live', code: 'live', label: 'Live', active: false));
      await q.firestore.collection('dev_queue_items').doc('other').set({
        ...itemFields(state: 'queued', code: 'up_next', label: 'Up next'),
        'ownerId': 'u2',
      });
      final items = await q.service.watchActive('u1').first;
      expect(items.map((i) => i.key), ['a', 'b']);
    });

    test('watchFinished returns finished items, newest first', () async {
      final q = FakeQueue();
      await q.addItem('old', itemFields(state: 'live', code: 'live', label: 'Live', active: false, stateChangedAt: DateTime(2026, 10, 1)));
      await q.addItem('new', itemFields(state: 'live', code: 'live', label: 'Live', active: false, stateChangedAt: DateTime(2026, 11, 1)));
      final items = await q.service.watchFinished('u1').first;
      expect(items.map((i) => i.key), ['new', 'old']);
    });
  });
}
