import 'package:bluejay_design/bluejay_design.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/group_seats.dart';

import 'fakes.dart';

class _User implements fire_auth.User {
  @override
  String get uid => 'u1';
  @override
  final bool isAnonymous;

  _User({this.isAnonymous = false});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child, {double width = 1000}) => MaterialApp(
      theme: BluejayTheme.build(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(body: child),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('DevQueueChip', () {
    testWidgets('shows the primary item and the waiting count, wide', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__a', itemFields(state: 'building', code: 'building', label: 'Building', title: 'Export to CSV', rank: 1));
      await q.addItem('bug__b', itemFields(state: 'queued', code: 'up_next', label: 'Up next', rank: 2));
      await tester.pumpWidget(_app(DevQueueChip(currentUser: _User(), groupDevQueueMode: null, service: q.service)));
      await _settle(tester);
      expect(find.text('Building: Export to CSV · +1 waiting'), findsOneWidget);
      expect(find.bySemanticsLabel('Your queue. Building: Export to CSV. 1 more waiting.'), findsOneWidget);
    });

    testWidgets('narrow form', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__a',
          itemFields(state: 'awaiting_user', code: 'ready_to_try', label: 'Ready to try', rank: 1));
      await tester.pumpWidget(
          _app(DevQueueChip(currentUser: _User(), groupDevQueueMode: 'pool', service: q.service), width: 400));
      await _settle(tester);
      expect(find.text('Ready to try'), findsOneWidget);
      expect(find.byType(DevQueueAttentionDot), findsOneWidget);
    });

    testWidgets('empty queue', (tester) async {
      final q = FakeQueue();
      await tester.pumpWidget(_app(DevQueueChip(currentUser: _User(), groupDevQueueMode: null, service: q.service)));
      await _settle(tester);
      expect(find.text('Your queue is empty'), findsOneWidget);
    });

    testWidgets('managed items do not count', (tester) async {
      final q = FakeQueue();
      await q.addItem('bug__m', itemFields(state: 'building', code: 'building', label: 'Building', managed: true));
      await tester.pumpWidget(_app(DevQueueChip(currentUser: _User(), groupDevQueueMode: null, service: q.service)));
      await _settle(tester);
      expect(find.text('Your queue is empty'), findsOneWidget);
    });

    for (final hidden in <String, Object>{
      'guest': 'guest',
      'managed group': 'managed',
      'signed out': 'signedOut',
    }.entries) {
      testWidgets('hidden: ${hidden.key}', (tester) async {
        final q = FakeQueue();
        await q.addItem('feature__a', itemFields(state: 'building', code: 'building', label: 'Building'));
        await tester.pumpWidget(_app(DevQueueChip(
          currentUser: hidden.value == 'signedOut' ? null : _User(isAnonymous: hidden.value == 'guest'),
          groupDevQueueMode: hidden.value == 'managed' ? 'managed' : null,
          service: q.service,
        )));
        await _settle(tester);
        expect(find.byType(DevQueueChipView), findsNothing);
      });
    }

    testWidgets('tap opens the queue', (tester) async {
      final q = FakeQueue();
      var opened = 0;
      await tester.pumpWidget(_app(DevQueueChip(
        currentUser: _User(),
        groupDevQueueMode: null,
        service: q.service,
        onOpen: () => opened++,
      )));
      await _settle(tester);
      await tester.tap(find.byType(DevQueueChipView));
      expect(opened, 1);
    });
  });

  group('DevQueueScreen', () {
    Future<FakeQueue> seeded() async {
      final q = FakeQueue();
      await q.addItem('feature__now', itemFields(state: 'building', code: 'building', label: 'Building', title: 'Dark mode', rank: 1));
      await q.addItem('bug__q1', itemFields(state: 'queued', code: 'up_next', label: 'Up next', title: 'First', rank: 2));
      await q.addItem('bug__q2',
          itemFields(state: 'queued', code: 'waiting_for_slot', label: 'Waiting for your developer agent', title: 'Second', rank: 3));
      await q.addItem('bug__q3',
          itemFields(state: 'failed', code: 'up_next', label: 'Up next', detail: 'Our team is looking into this', title: 'Third', rank: 4));
      return q;
    }

    Future<SeatStatus> seats({required bool admin, String? mode = 'pool'}) async => SeatStatus.fromData({
          'groupId': 'g1',
          'canManage': admin,
          'devQueues': {'mode': mode},
          if (admin) 'addOns': {'seatPriceMonthly': 24.68, 'devQueuePriceMonthly': 296.37},
        });

    testWidgets('a waiting request offers group admins another developer agent', (tester) async {
      final q = await seeded();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(
            currentUser: _User(), service: q.service, groupId: 'g1', loadSeats: (_) => seats(admin: true)),
      ));
      await _settle(tester);
      expect(find.text('Add a developer agent'), findsOneWidget);
      expect(find.textContaining('Add a developer agent to build more requests'), findsOneWidget);
    });

    testWidgets('members see who can add a developer agent, with no button', (tester) async {
      final q = await seeded();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(
            currentUser: _User(), service: q.service, groupId: 'g1', loadSeats: (_) => seats(admin: false)),
      ));
      await _settle(tester);
      expect(find.text('Add a developer agent'), findsNothing);
      expect(find.textContaining("Your group's admins can add a developer agent"), findsOneWidget);
    });

    testWidgets('no agent note without a shared pool', (tester) async {
      final q = await seeded();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(
            currentUser: _User(), service: q.service, groupId: 'g1', loadSeats: (_) => seats(admin: true, mode: null)),
      ));
      await _settle(tester);
      expect(find.textContaining('Your developer agents are busy'), findsNothing);
    });

    testWidgets('sections, positions and empty Shipped', (tester) async {
      final q = await seeded();
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      expect(find.text('Your queue'), findsOneWidget);
      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Dark mode'), findsOneWidget);
      expect(find.text('Up next'), findsWidgets);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
      expect(find.text('#4'), findsOneWidget);
      expect(find.text('Waiting for your developer agent'), findsOneWidget);
      expect(find.text('Up next · Our team is looking into this'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('Nothing shipped yet'), 200);
      expect(find.text('Nothing shipped yet. Your first request shows up here when it goes live.'), findsOneWidget);
      // No managed groups: no tabs.
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('empty Now and Up next', (tester) async {
      final q = FakeQueue();
      var asked = 0;
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: _User(), service: q.service, onNewRequest: (_) async => asked++),
      ));
      await _settle(tester);
      expect(find.text('Nothing waiting. What would save you time next?'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Request a change'));
      await tester.tap(find.widgetWithText(TextButton, 'Request a change'));
      expect(asked, 2);
    });

    testWidgets('Move to top sends the full new order', (tester) async {
      final q = await seeded();
      q.respond = (call) => call.name == 'devQueueListManaged' ? {'groups': <Object?>[]} : {'success': true};
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      await tester.longPress(find.text('Third'));
      await _settle(tester);
      await tester.tap(find.text('Move to top'));
      await _settle(tester);
      final reorder = q.calls.firstWhere((c) => c.name == 'devQueueReorder');
      expect(reorder.data['orderedKeys'], ['bug__q3', 'bug__q1', 'bug__q2']);
      // Optimistic: Third now shows at #2.
      final third = tester.getTopLeft(find.text('Third')).dy;
      final first = tester.getTopLeft(find.text('First')).dy;
      expect(third, lessThan(first));
    });

    testWidgets('Move down through the semantics action', (tester) async {
      final q = await seeded();
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      final row = tester.widget<Semantics>(find
          .ancestor(
            of: find.text('First'),
            matching: find.byWidgetPredicate(
                (w) => w is Semantics && (w.properties.customSemanticsActions?.isNotEmpty ?? false)),
          )
          .first);
      final actions = {
        for (final e in row.properties.customSemanticsActions!.entries) e.key.label: e.value,
      };
      // First in Up next: no Move to top or Move up.
      expect(actions.keys, ['Move down', 'Edit', 'Withdraw']);
      actions['Move down']!();
      await _settle(tester);
      expect(q.calls.firstWhere((c) => c.name == 'devQueueReorder').data['orderedKeys'], ['bug__q2', 'bug__q1', 'bug__q3']);
    });

    testWidgets('queue-changed restores the server order and says so', (tester) async {
      final q = await seeded();
      q.respond = (call) {
        if (call.name == 'devQueueReorder') throw const DevQueueException('queue-changed');
        return {'groups': <Object?>[]};
      };
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      await tester.longPress(find.text('Third'));
      await _settle(tester);
      await tester.tap(find.text('Move to top'));
      await _settle(tester);
      expect(find.text('Your queue changed while you were moving things. Try again.'), findsOneWidget);
      final third = tester.getTopLeft(find.text('Third')).dy;
      final first = tester.getTopLeft(find.text('First')).dy;
      expect(third, greaterThan(first));
    });

    testWidgets('Shipped rows', (tester) async {
      final q = FakeQueue();
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await q.addItem('feature__live', itemFields(
        state: 'live', code: 'live', label: 'Live', title: 'Weekly summary', active: false,
        stateChangedAt: yesterday, shippedAppId: 'notes',
      ));
      await q.addItem('bug__declined', itemFields(
        state: 'declined', code: 'declined', label: 'Declined', title: 'Old idea', active: false,
        stateChangedAt: yesterday, closure: {'reasonLabel': 'Not planned'},
      ));
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      await tester.scrollUntilVisible(find.text('Old idea'), 200);
      expect(find.text('Weekly summary'), findsOneWidget);
      expect(find.textContaining('Live since'), findsOneWidget);
      expect(find.text('Open Notes'), findsOneWidget);
      expect(find.text("What's New"), findsOneWidget);
      expect(find.text('Declined: Not planned'), findsOneWidget);
    });

    testWidgets("Open {app} hides when the app isn't installed", (tester) async {
      final q = FakeQueue();
      DevQueueHost.isAppInstalled = (_) => false;
      addTearDown(() => DevQueueHost.isAppInstalled = null);
      await q.addItem('feature__live', itemFields(
        state: 'live', code: 'live', label: 'Live', title: 'Weekly summary', active: false,
        stateChangedAt: DateTime.now(), shippedAppId: 'notes',
      ));
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      await tester.scrollUntilVisible(find.text('Weekly summary'), 200);
      expect(find.text('Open Notes'), findsNothing);
    });

    testWidgets("Shipped keeps the group's requests and adds teammates' and bonus changes", (tester) async {
      final q = FakeQueue();
      DevQueueHost.isAppInstalled = (id) => id == 'notes';
      addTearDown(() => DevQueueHost.isAppInstalled = null);
      final now = DateTime.now();
      q.respond = (call) {
        if (call.name == 'devQueueGroupShipped') {
          expect(call.data, {'groupId': 'g1'});
          return {
            'groupId': 'g1',
            'team': [
              {'itemKey': 'u_bob__feature__x', 'title': 'Pin notes', 'appId': 'notes', 'appName': 'Notes',
                'requesterName': 'Bob', 'liveAt': now.subtract(const Duration(days: 2)).toIso8601String()},
            ],
            'bonus': [
              {'id': 'r1', 'title': 'Notes can have tags.', 'apps': [{'appId': 'notes', 'name': 'Notes'}],
                'liveAt': now.toIso8601String()},
            ],
          };
        }
        if (call.name == 'devQueueListManaged') return {'groups': <Object?>[]};
        return {'success': true};
      };
      await q.addItem('feature__mine', {
        ...itemFields(state: 'live', code: 'live', label: 'Live', title: 'Weekly summary', active: false,
            stateChangedAt: now.subtract(const Duration(days: 1)), shippedAppId: 'notes'),
        'groupId': 'g1',
      });
      await q.addItem('feature__elsewhere', {
        ...itemFields(state: 'live', code: 'live', label: 'Live', title: 'Other group thing', active: false,
            stateChangedAt: now, shippedAppId: 'notes'),
        'groupId': 'g2',
      });
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: _User(), service: q.service, groupId: 'g1'),
      ));
      await _settle(tester);
      await tester.scrollUntilVisible(find.text('Notes can have tags.'), 200);
      expect(find.text('Weekly summary'), findsOneWidget);
      expect(find.text('Pin notes'), findsOneWidget);
      expect(find.textContaining('Asked for by Bob'), findsOneWidget);
      expect(find.text('Other group thing'), findsNothing);
      expect(find.text('Bonus improvements'), findsOneWidget);
      // Newest first: yours from yesterday above Bob's from two days ago.
      expect(tester.getTopLeft(find.text('Weekly summary')).dy, lessThan(tester.getTopLeft(find.text('Pin notes')).dy));
    });

    testWidgets('a failed group read still shows your own Shipped', (tester) async {
      final q = FakeQueue();
      q.respond = (call) {
        if (call.name == 'devQueueGroupShipped') throw const DevQueueException('permission-denied');
        if (call.name == 'devQueueListManaged') return {'groups': <Object?>[]};
        return {'success': true};
      };
      await q.addItem('feature__mine', {
        ...itemFields(state: 'live', code: 'live', label: 'Live', title: 'Weekly summary', active: false,
            stateChangedAt: DateTime.now()),
        'groupId': 'g1',
      });
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: _User(), service: q.service, groupId: 'g1'),
      ));
      await _settle(tester);
      await tester.scrollUntilVisible(find.text('Weekly summary'), 200);
      expect(find.text('Bonus improvements'), findsNothing);
    });

    testWidgets('a failed stream offers Try again', (tester) async {
      final q = FakeQueue();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: _User(), service: _FailingService(q)),
      ));
      await _settle(tester);
      expect(find.text("Couldn't load your queue."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('Managed workspaces tab for triagers', (tester) async {
      final q = FakeQueue();
      var listed = 0;
      q.respond = (call) {
        if (call.name == 'devQueueListManaged') {
          listed++;
          return {
            'groups': [
              {
                'groupId': 'acme',
                'name': 'Acme',
                'items': [
                  {
                    'itemKey': 'bug__h1',
                    'itemType': 'bug',
                    'itemId': 'h1',
                    'title': 'Totals are wrong',
                    'submitterName': 'Ada',
                    'excerpt': 'The totals row double counts',
                    'createdAt': DateTime.now().toIso8601String(),
                    'held': listed == 1,
                    'status': {'code': 'received', 'label': 'Received'},
                  },
                ],
              },
            ],
          };
        }
        return {'success': true};
      };
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      expect(find.byType(TabBar), findsOneWidget);
      await tester.tap(find.text('Managed workspaces'));
      await tester.pumpAndSettle();
      expect(find.text('Acme'), findsOneWidget);
      expect(find.text('Totals are wrong'), findsOneWidget);
      expect(find.textContaining('Ada'), findsOneWidget);
      expect(find.text('Received'), findsOneWidget);
      await tester.tap(find.text('Send to pipeline'));
      await tester.pumpAndSettle();
      expect(q.calls.where((c) => c.name == 'devQueueSendToPipeline').single.data, {'itemType': 'bug', 'itemId': 'h1'});
      expect(find.text('Sent'), findsOneWidget);
      expect(listed, 2);
    });

    testWidgets('Managed workspaces empty state', (tester) async {
      final q = FakeQueue()
        ..respond = (call) => {
              'groups': [
                {'groupId': 'acme', 'name': 'Acme', 'items': <Object?>[]},
              ],
            };
      await tester.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: DevQueueScreen(currentUser: _User(), service: q.service)));
      await _settle(tester);
      await tester.tap(find.text('Managed workspaces'));
      await tester.pumpAndSettle();
      expect(find.text('No requests from the workspaces you manage.'), findsOneWidget);
    });
  });

  group('Waiting on you and Ready to try', () {
    testWidgets('the answer box calls devQueueAnswer and is disabled while empty', (tester) async {
      final q = FakeQueue();
      await q.addItem('bug__w', itemFields(
        state: 'awaiting_user', code: 'waiting_on_you', label: 'Waiting on you', title: 'Totals',
        detail: 'Which totals?',
        waiting: {
          'reason': 'clarification',
          'askedBy': 'agent',
          'question': 'Which totals?',
          'deadline': DateTime(2026, 11, 10),
        },
      ));
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: _User(), service: q.service, now: DateTime(2026, 11, 8, 9)),
      ));
      await _settle(tester);
      expect(find.text('Which totals?'), findsWidgets);
      expect(find.text("We're holding your spot until Tuesday."), findsOneWidget);
      final send = find.widgetWithText(FilledButton, 'Send answer');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, 'Your answer'), 'The monthly ones');
      await tester.pump();
      await tester.tap(send);
      await _settle(tester);
      final call = q.calls.firstWhere((c) => c.name == 'devQueueAnswer');
      expect(call.data['itemKey'], 'bug__w');
      expect(call.data['answer'], 'The monthly ones');
      expect(call.data['idempotencyKey'], isNotEmpty);
    });

    testWidgets('a staff question after the slot was released', (tester) async {
      final q = FakeQueue();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: Scaffold(
          body: DevQueueAnswerBox(
            itemKey: 'bug__w',
            question: 'Can you add a screenshot?',
            waiting: const DevWaiting(reason: DevWaitingReason.clarification, askedBy: 'staff', slotReleased: true),
            service: q.service,
          ),
        ),
      ));
      expect(
        find.text('Your spot went to your next request. Answer and this goes back to the front of your queue.'),
        findsOneWidget,
      );
      expect(find.text('Answering reopens your request.'), findsOneWidget);
    });

    testWidgets('an error keeps the text and shows the message', (tester) async {
      final q = FakeQueue()..respond = (call) => throw const DevQueueException('not-waiting');
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: Scaffold(body: DevQueueAnswerBox(itemKey: 'bug__w', question: 'Q?', service: q.service)),
      ));
      await tester.enterText(find.byType(TextField), 'An answer');
      await tester.pump();
      await tester.tap(find.text('Send answer'));
      await _settle(tester);
      expect(find.text('An answer'), findsOneWidget);
      expect(find.text(const DevQueueException('not-waiting').message), findsOneWidget);
    });

    DevQueueItem readyItem() => DevQueueItem.fromMap('feature__r', {
          'state': 'awaiting_user',
          'status': {'code': 'ready_to_try', 'label': 'Ready to try'},
          'waiting': {'reason': 'preview_approval', 'sha': 'sha1', 'previewUrl': 'https://preview.example'},
        });

    testWidgets('Try it, the real-data hint, and Approve', (tester) async {
      final q = FakeQueue();
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: Scaffold(
          body: DevQueuePreviewActions(
            item: readyItem(),
            service: q.service,
            openLink: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      ));
      expect(
        find.text("Opens a test version of Bluejay with your change. Sign in with your usual email and password. It uses a test copy of your group's data, so nothing you do there changes your real data."),
        findsOneWidget,
      );
      await tester.tap(find.text('Try it'));
      expect(opened, ['https://preview.example']);
      await tester.tap(find.text('Approve'));
      await _settle(tester);
      expect(q.calls.single.name, 'devQueueApprovePreview');
      expect(q.calls.single.data, {'itemKey': 'feature__r', 'sha': 'sha1'});
      expect(find.text("Thanks. It's with the reviewer now."), findsOneWidget);
    });

    testWidgets('Ask for a tweak', (tester) async {
      final q = FakeQueue();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: Scaffold(body: SingleChildScrollView(child: DevQueuePreviewActions(item: readyItem(), service: q.service))),
      ));
      expect(find.text('What should change?'), findsNothing);
      await tester.tap(find.text('Ask for a tweak'));
      await tester.pump();
      final send = find.widgetWithText(FilledButton, 'Send tweak');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, 'What should change?'), 'Make the button bigger');
      await tester.pump();
      await tester.tap(send);
      await _settle(tester);
      expect(q.calls.single.name, 'devQueueRequestTweak');
      expect(q.calls.single.data['itemKey'], 'feature__r');
      expect(q.calls.single.data['sha'], 'sha1');
      expect(q.calls.single.data['text'], 'Make the button bigger');
      expect(find.text("Got it. We're making your tweak."), findsOneWidget);
    });
  });

  group('DevStatusPill and DevTicketStatus', () {
    testWidgets('label and detail', (tester) async {
      await tester.pumpWidget(_app(DevStatusPill(DevStatus.fromMap({
        'code': 'building',
        'label': 'Building',
        'detail': 'Making your tweak',
      })!)));
      expect(find.text('Building'), findsOneWidget);
      expect(find.text('Making your tweak'), findsOneWidget);
    });

    testWidgets('nothing without a devStatus code', (tester) async {
      await tester.pumpWidget(_app(const DevTicketStatus(devStatus: null, queueItemId: null, isOwner: false)));
      expect(find.byType(DevStatusPill), findsNothing);
    });

    testWidgets('non-owners see the pill only', (tester) async {
      final q = FakeQueue();
      await tester.pumpWidget(_app(DevTicketStatus(
        devStatus: const {'code': 'checking', 'label': 'Checking'},
        queueItemId: 'bug__x',
        isOwner: false,
        currentUser: _User(),
        service: q.service,
      )));
      await _settle(tester);
      expect(find.text('Checking'), findsOneWidget);
      expect(find.text('Open in your queue'), findsNothing);
    });

    testWidgets('the owner gets the queue link and the answer box', (tester) async {
      final q = FakeQueue();
      await q.addItem('bug__x', itemFields(
        state: 'awaiting_user', code: 'waiting_on_you', label: 'Waiting on you', detail: 'Which page?',
        waiting: {'reason': 'clarification', 'askedBy': 'agent', 'question': 'Which page?'},
      ));
      await tester.pumpWidget(_app(DevTicketStatus(
        devStatus: const {'code': 'waiting_on_you', 'label': 'Waiting on you', 'detail': 'Which page?'},
        queueItemId: 'bug__x',
        isOwner: true,
        currentUser: _User(),
        service: q.service,
      )));
      await _settle(tester);
      expect(find.text('Open in your queue'), findsOneWidget);
      expect(find.text('Send answer'), findsOneWidget);
    });

    testWidgets('a managed owner answers but has no queue link', (tester) async {
      final q = FakeQueue();
      await q.addItem('bug__m', itemFields(
        state: 'awaiting_user', code: 'waiting_on_you', label: 'Waiting on you', managed: true,
        waiting: {'reason': 'clarification', 'askedBy': 'staff', 'question': 'Which page?'},
      ));
      await tester.pumpWidget(_app(DevTicketStatus(
        devStatus: const {'code': 'waiting_on_you', 'label': 'Waiting on you'},
        queueItemId: 'bug__m',
        isOwner: true,
        currentUser: _User(),
        service: q.service,
      )));
      await _settle(tester);
      expect(find.text('Open in your queue'), findsNothing);
      expect(find.text('Send answer'), findsOneWidget);
      expect(find.text('Answering reopens your request.'), findsOneWidget);
    });

    testWidgets('a platform admin answers platform work without a queue link', (tester) async {
      final q = FakeQueue();
      await q.addItem('feature__p', itemFields(
        state: 'awaiting_user', code: 'waiting_on_you', label: 'Waiting on you', detail: 'Which page?',
        waiting: {'reason': 'clarification', 'askedBy': 'agent', 'question': 'Which page?'},
      ));
      await tester.pumpWidget(_app(DevTicketStatus(
        devStatus: const {'code': 'waiting_on_you', 'label': 'Waiting on you', 'detail': 'Which page?'},
        queueItemId: 'feature__p',
        isOwner: false,
        canAnswer: true,
        currentUser: _User(),
        service: q.service,
      )));
      await _settle(tester);
      expect(find.text('Open in your queue'), findsNothing);
      expect(find.text('Send answer'), findsOneWidget);
    });
  });

  test('devPlatformRequesterName names the source', () {
    expect(devPlatformRequesterName('advisor-round'), 'Advisor rounds');
    expect(devPlatformRequesterName('spare-capacity'), 'Spare-capacity worker');
    expect(devPlatformRequesterName('automations-sweep'), 'Automations contract sweep');
    expect(devPlatformRequesterName(null), 'Bluejay platform');
  });
}

class _FailingService extends DevQueueService {
  final FakeQueue base;

  _FailingService(this.base) : super(firestore: base.firestore, call: (n, d) async => {'groups': <Object?>[]});

  @override
  Stream<List<DevQueueItem>> watchActive(String uid) => Stream.error(StateError('denied'));
}
