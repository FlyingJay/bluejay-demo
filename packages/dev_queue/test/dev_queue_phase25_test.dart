import 'package:bluejay_design/bluejay_design.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// PHASE_2_5_DESIGN.md 8.1: edit, withdraw, sizes, "This broke something".

class _User implements fire_auth.User {
  @override
  String get uid => 'u1';
  @override
  bool get isAnonymous => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, FakeQueue q, {DateTime? now}) async {
  await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service, now: now)));
  await _settle(tester);
}

const _smallEstimate = {
  'size': 'S',
  'short': 'Small',
  'line': 'Often ready within a few days once it starts',
};

Map<String, Object?> _queued(String title, {double rank = 2, String itemType = 'feature', String itemId = 'f1', Object? startedAt}) => {
      ...itemFields(state: 'queued', code: 'up_next', label: 'Up next', title: title, rank: rank),
      'itemType': itemType,
      'itemId': itemId,
      'estimate': _smallEstimate,
      'startedAt': startedAt,
    };

Object? Function(RecordedCall) _respond(Object? Function(RecordedCall call) handler) => (call) {
      if (call.name == 'devQueueListManaged') return {'groups': <Object?>[]};
      return handler(call);
    };

void main() {
  group('Up next', () {
    testWidgets('shows the size chip and a Fix chip for a regression fix', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await q.addItem('bug__reg_1', {
        ..._queued('Export is empty', rank: 1, itemType: 'bug', itemId: 'reg_1'),
        'expedite': true,
        'estimate': null,
      });
      await _pump(tester, q);
      expect(find.widgetWithText(DevQueueTextChip, 'Small'), findsOneWidget);
      expect(find.widgetWithText(DevQueueTextChip, 'Fix'), findsOneWidget);
    });

    testWidgets('Edit prefills from the ticket and sends only what changed', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await q.firestore.collection('feature_requests').doc('f1').set({'title': 'Export to CSV', 'description': 'From reports'});
      q.respond = _respond((call) => {'success': true, 'itemKey': 'feature__f1', 'state': 'queued'});
      await _pump(tester, q);

      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Edit your request'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Details'), findsOneWidget);
      expect(find.text('From reports'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Details'), 'From the reports screen, as CSV');
      await tester.pump();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();

      final edit = q.calls.singleWhere((c) => c.name == 'devQueueEditRequest');
      expect(edit.data, {'itemKey': 'feature__f1', 'description': 'From the reports screen, as CSV'});
      expect(find.text('Edit your request'), findsNothing);
      expect(find.text("Saved. We'll build the updated version."), findsOneWidget);
    });

    testWidgets('a bug edit has one labelled field, and Save is off while it is empty', (tester) async {
      final q = FakeQueue();
      await q.addItem('bug__b1', _queued('Crash on save', itemType: 'bug', itemId: 'b1'));
      await q.firestore.collection('bug_reports').doc('b1').set({'description': 'Crash on save'});
      await _pump(tester, q);
      await tester.longPress(find.text('Crash on save'));
      await _settle(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, "What's going wrong?"), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Title'), findsNothing);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save changes')).onPressed, isNull);
    });

    testWidgets('an app edit shows App name and What it should do', (tester) async {
      final q = FakeQueue();
      await q.addItem('app__a1', _queued('Habit tracker', itemType: 'app', itemId: 'a1'));
      await q.firestore.collection('app_requests').doc('a1').set({'title': 'Habit tracker', 'summary': 'Tracks habits'});
      await _pump(tester, q);
      await tester.longPress(find.text('Habit tracker'));
      await _settle(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'App name'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'What it should do'), findsOneWidget);
      expect(find.text('Tracks habits'), findsOneWidget);
    });

    testWidgets('started: the refusal copy shows and the text stays', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await q.firestore.collection('feature_requests').doc('f1').set({'title': 'Export to CSV', 'description': ''});
      q.respond = _respond((call) => throw const DevQueueException('started', 'server words'));
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Details'), 'More detail');
      await tester.pump();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(
        find.text("We've already started on this, so it can't be edited now. You can ask for a tweak when it's "
            'ready to try, or withdraw it.'),
        findsOneWidget,
      );
      expect(find.text('More detail'), findsOneWidget);
      expect(find.text('Edit your request'), findsOneWidget);
    });

    testWidgets('nothing-changed closes the sheet silently', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await q.firestore.collection('feature_requests').doc('f1').set({'title': 'Export to CSV', 'description': 'a'});
      q.respond = _respond((call) => throw const DevQueueException('nothing-changed'));
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Details'), 'b');
      await tester.pump();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(find.text('Edit your request'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a started item offers Withdraw but not Edit', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV', startedAt: DateTime(2026, 11, 6)));
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Withdraw'), findsOneWidget);
    });

    testWidgets('withdraw, not started: plain confirmation and no confirmStarted', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Withdraw'));
      await tester.pumpAndSettle();
      expect(find.text('Withdraw this request?'), findsOneWidget);
      expect(find.text('It leaves your queue and nothing gets built. You can ask again any time.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(q.calls.singleWhere((c) => c.name == 'devQueueWithdraw').data, {'itemKey': 'feature__f1'});
      expect(find.text('Request withdrawn.'), findsOneWidget);
    });

    testWidgets('withdraw, Keep it sends nothing', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Withdraw'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(q.calls.where((c) => c.name == 'devQueueWithdraw'), isEmpty);
    });

    testWidgets('already-started asks again with the started wording, then confirms', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f1', _queued('Export to CSV'));
      q.respond = _respond((call) {
        if (call.name == 'devQueueWithdraw' && call.data['confirmStarted'] != true) {
          throw const DevQueueException('already-started');
        }
        return {'success': true};
      });
      await _pump(tester, q);
      await tester.longPress(find.text('Export to CSV'));
      await _settle(tester);
      await tester.tap(find.text('Withdraw'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(find.text('Stop work on this?'), findsOneWidget);
      await tester.tap(find.text('Stop and withdraw'));
      await tester.pumpAndSettle();
      final calls = q.calls.where((c) => c.name == 'devQueueWithdraw').toList();
      expect(calls.map((c) => c.data['confirmStarted']), [null, true]);
      expect(find.text('Request withdrawn.'), findsOneWidget);
    });
  });

  group('Now', () {
    Map<String, Object?> building({Map<String, Object?>? estimate = _smallEstimate, String state = 'building'}) => {
          ...itemFields(state: state, code: state, label: state == 'building' ? 'Building' : 'Final review', title: 'Dark mode', rank: 1),
          'itemType': 'feature',
          'itemId': 'f2',
          'estimate': estimate,
          'startedAt': DateTime(2026, 11, 6),
        };

    testWidgets('shows the estimate line while Building', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f2', building());
      await _pump(tester, q);
      expect(find.text('Often ready within a few days once it starts.'), findsOneWidget);
    });

    testWidgets('no estimate line in Final review', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f2', building(state: 'in_review'));
      await _pump(tester, q);
      expect(find.textContaining('Often ready'), findsNothing);
    });

    testWidgets('Withdraw request on a started item confirms, then sends confirmStarted', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f2', building());
      await _pump(tester, q);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Withdraw request'));
      await tester.pumpAndSettle();
      expect(find.text('Stop work on this?'), findsOneWidget);
      expect(find.text("We've already started. Withdrawing stops the work, and it won't go live."), findsOneWidget);
      await tester.tap(find.text('Stop and withdraw'));
      await tester.pumpAndSettle();
      expect(q.calls.singleWhere((c) => c.name == 'devQueueWithdraw').data, {'itemKey': 'feature__f2', 'confirmStarted': true});
    });

    testWidgets('going-live shows its copy', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f2', building(state: 'in_review'));
      q.respond = _respond((call) => throw const DevQueueException('going-live'));
      await _pump(tester, q);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Withdraw request'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop and withdraw'));
      await tester.pumpAndSettle();
      expect(find.text("This is already going live, so it can't be withdrawn."), findsOneWidget);
    });

    testWidgets('merged items have no withdraw menu', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__f2', building(state: 'merged'));
      await _pump(tester, q);
      expect(find.byTooltip('More'), findsNothing);
    });
  });

  group('This broke something', () {
    final now = DateTime(2026, 12, 1, 12);

    Future<FakeQueue> shipped({required DateTime liveAt, List<String> regressions = const []}) async {
      final q = FakeQueue();
      await q.addItem('feature__live', {
        ...itemFields(state: 'live', code: 'live', label: 'Live', title: 'Weekly summary', active: false, stateChangedAt: liveAt),
        'itemType': 'feature',
        'itemId': 'live',
        'regressions': regressions,
      });
      return q;
    }

    testWidgets('shows within 30 days of Live', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 29)));
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('Weekly summary'), 200);
      expect(find.text('This broke something'), findsOneWidget);
    });

    testWidgets('hidden after 30 days', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 31)));
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('Weekly summary'), 200);
      expect(find.text('This broke something'), findsNothing);
    });

    testWidgets('hidden while a report from it is still open', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 2)), regressions: ['bug__reg_1']);
      await q.addItem('bug__reg_1', _queued('Summary is blank', itemType: 'bug', itemId: 'reg_1'));
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('Weekly summary'), 200);
      expect(find.text('This broke something'), findsNothing);
    });

    testWidgets('the sheet sends the description with one idempotency key, then says first in line', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 2)));
      q.respond = _respond((call) => {'success': true, 'itemKey': 'bug__reg_9'});
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('This broke something'), 200);
      await tester.tap(find.text('This broke something'));
      await tester.pumpAndSettle();

      expect(find.text('What broke?'), findsOneWidget);
      expect(find.text("This goes to the front of your queue and doesn't use your spot."), findsOneWidget);
      final report = find.widgetWithText(FilledButton, 'Report it');
      expect(tester.widget<FilledButton>(report).onPressed, isNull);

      await tester.enterText(find.widgetWithText(TextField, "What's going wrong since this went live?"), 'The summary is blank');
      await tester.pump();
      await tester.tap(report);
      await tester.pumpAndSettle();

      final call = q.calls.singleWhere((c) => c.name == 'devQueueReportRegression');
      expect(call.data['itemKey'], 'feature__live');
      expect(call.data['description'], 'The summary is blank');
      expect(call.data['idempotencyKey'], isNotEmpty);
      expect(find.text("Thanks. It's first in line."), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget);
    });

    testWidgets('already-reported closes with its copy and View', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 2)));
      q.respond = _respond((call) => throw const DevQueueException(
            'already-reported',
            '',
            {'reason': 'already-reported', 'itemKey': 'bug__reg_1'},
          ));
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('This broke something'), 200);
      await tester.tap(find.text('This broke something'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Blank again');
      await tester.pump();
      await tester.tap(find.text('Report it'));
      await tester.pumpAndSettle();
      expect(find.text('What broke?'), findsNothing);
      expect(find.text("You've already reported a problem with this. It's in your queue."), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'View'), findsOneWidget);
    });

    testWidgets('too-late keeps the sheet and its text', (tester) async {
      final q = await shipped(liveAt: now.subtract(const Duration(days: 2)));
      q.respond = _respond((call) => throw const DevQueueException('too-late'));
      await _pump(tester, q, now: now);
      await tester.scrollUntilVisible(find.text('This broke something'), 200);
      await tester.tap(find.text('This broke something'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Blank');
      await tester.pump();
      await tester.tap(find.text('Report it'));
      await tester.pumpAndSettle();
      expect(find.text('This went live more than 30 days ago. Report a problem from the app instead.'), findsOneWidget);
      expect(find.text('Blank'), findsOneWidget);
    });
  });
}
