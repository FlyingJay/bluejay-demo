import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/group_seats.dart';
import 'package:shared_ui/group_seats_ui.dart';

SeatStatus seatStatus({
  int members = 8,
  int pending = 2,
  int limit = 10,
  bool unlimited = false,
  bool canManage = false,
  bool? hasPaymentMethod = true,
  int bonusSeats = 0,
  Map<String, dynamic>? subscription,
  Map<String, dynamic>? registration,
  List<Map<String, dynamic>>? planChanges,
}) =>
    SeatStatus.fromData({
      'groupId': 'fam',
      'groupName': 'Family',
      'plan': {'id': 'personal', 'name': 'Personal', 'seats': 10, 'devQueues': 1, 'priceMonthly': 0},
      'bonusSeats': bonusSeats,
      'unlimited': unlimited,
      'limit': unlimited ? null : limit,
      'members': members,
      'pending': pending,
      'used': members + pending,
      'available': unlimited ? null : (limit - members - pending).clamp(0, limit),
      'canManage': canManage,
      'plans': [
        {'id': 'personal', 'name': 'Personal', 'seats': 10, 'devQueues': 1, 'priceMonthly': 0},
        {'id': 'team', 'name': 'Team', 'seats': 25, 'devQueues': 2, 'priceMonthly': 249},
        {'id': 'business', 'name': 'Business', 'seats': 50, 'devQueues': 10, 'priceMonthly': 999},
      ],
      'currency': 'CAD',
      'subscription': subscription,
      'hasPaymentMethod': hasPaymentMethod,
      'registration': registration,
      'planChanges': planChanges ??
          (canManage
              ? [
                  {'plan': 'team', 'effective': 'now', 'charge': 180.75, 'credits': 0},
                  {'plan': 'business', 'effective': 'now', 'charge': 725.32, 'credits': 0},
                ]
              : const []),
    });

class FakeSeatsApi extends GroupSeatsApi {
  FakeSeatsApi({this.notified = 2, this.changeResult, this.changeError});

  final int notified;
  final SeatStatus? changeResult;
  final Object? changeError;
  final List<String?> requests = [];
  final List<String> changes = [];

  @override
  Future<int> requestMore(String groupId, {String? message}) async {
    requests.add(message);
    return notified;
  }

  @override
  Future<SeatStatus> changePlan(String groupId, SeatPlan plan) async {
    changes.add(plan.id);
    if (changeError != null) throw changeError!;
    return changeResult!;
  }
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)));

void main() {
  test('formatSeatPrice groups thousands with the CA\$ symbol', () {
    expect(formatSeatPrice(999, 'CAD'), r'CA$999.00');
    expect(formatSeatPrice(1250.5, 'CAD'), r'CA$1,250.50');
    expect(formatSeatPrice(49.99, 'USD'), r'US$49.99');
  });

  group('SeatUsageBar', () {
    testWidgets('shows used, limit, available and pending invitations', (tester) async {
      await tester.pumpWidget(host(SeatUsageBar(status: seatStatus(members: 6, pending: 2))));
      expect(find.text('8 of 10 seats used · 2 available'), findsOneWidget);
      expect(find.textContaining('includes 2 pending invitations'), findsOneWidget);
      expect(find.textContaining('Personal plan'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('a full group says so', (tester) async {
      await tester.pumpWidget(host(SeatUsageBar(status: seatStatus(members: 10, pending: 0))));
      expect(find.text('10 of 10 seats used · 0 available'), findsOneWidget);
      expect(find.textContaining('no seats left'), findsOneWidget);
      expect(find.textContaining('pending'), findsNothing);
    });

    testWidgets('an unlimited group has no bar', (tester) async {
      await tester.pumpWidget(host(SeatUsageBar(status: seatStatus(unlimited: true, members: 30, pending: 0))));
      expect(find.text('Unlimited seats · 30 seats used'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  Future<void> openWith(WidgetTester tester, Future<void> Function(BuildContext) open) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open'))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showNoSeatsDialog', () {
    testWidgets('asks the admins with the message and confirms', (tester) async {
      final api = FakeSeatsApi(notified: 2);
      await openWith(tester, (c) => showNoSeatsDialog(c, status: seatStatus(members: 9, pending: 1), api: api));
      expect(find.text('No seats available'), findsOneWidget);
      expect(find.textContaining('including 1 pending invitation'), findsOneWidget);
      expect(find.textContaining('Revoking one frees its seat'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('no-seats-message')), 'Grandma');
      await tester.tap(find.byKey(const ValueKey('ask-admin')));
      await tester.pumpAndSettle();
      expect(api.requests, ['Grandma']);
      expect(find.text('Your admins were notified'), findsOneWidget);
    });

    testWidgets('no admins to notify', (tester) async {
      final api = FakeSeatsApi(notified: 0);
      await openWith(tester, (c) => showNoSeatsDialog(c, status: seatStatus(members: 10, pending: 0), api: api));
      await tester.tap(find.byKey(const ValueKey('ask-admin')));
      await tester.pumpAndSettle();
      expect(find.text('No admins to notify'), findsOneWidget);
    });
  });

  group('showSeatPlanSheet', () {
    testWidgets('lists each plan with what it costs today and returns the new status', (tester) async {
      final changed = seatStatus(members: 10, pending: 0, limit: 25, canManage: true);
      final api = FakeSeatsApi(changeResult: changed);
      SeatStatus? result;
      await openWith(
        tester,
        (c) async => result = await showSeatPlanSheet(c,
            status: seatStatus(members: 10, pending: 0, canManage: true), api: api),
      );
      expect(find.text('Change plan'), findsOneWidget);
      expect(find.text(r'Team — 25 seats, 2 developer agents — CA$249.00/month'), findsOneWidget);
      expect(find.text(r'Business — 50 seats, 10 developer agents — CA$999.00/month'), findsOneWidget);
      expect(find.text(r'CA$180.75 today for the rest of this month'), findsOneWidget);
      expect(find.textContaining('default card in your Wallet'), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-plan-includes-fee')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('seat-plan-business')));
      await tester.pump();
      expect(find.text('Switch to Business'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.tap(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.pumpAndSettle();
      expect(api.changes, ['business']);
      expect(result, same(changed));
      expect(find.byKey(const ValueKey('seat-plan-sheet')), findsNothing);
    });

    testWidgets('mentions credits and the included group fee', (tester) async {
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c,
            status: seatStatus(
              members: 10,
              pending: 0,
              canManage: true,
              registration: {'priceMonthly': 49.99, 'status': 'active', 'included': false},
              planChanges: [
                {'plan': 'team', 'effective': 'now', 'charge': 150.5, 'credits': 30.25},
              ],
            ),
            api: FakeSeatsApi()),
      );
      expect(find.text(r'CA$150.50 today for the rest of this month, after CA$30.25 already paid this month'),
          findsOneWidget);
      expect(find.textContaining(r'include the CA$49.99 monthly group fee'), findsOneWidget);
    });

    testWidgets('a smaller plan starts on the 1st, and the live plan takes back a switch', (tester) async {
      final api = FakeSeatsApi(changeResult: seatStatus(canManage: true));
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c,
            status: seatStatus(
              canManage: true,
              subscription: {'plan': 'business', 'status': 'active', 'priceMonthly': 999, 'nextPlan': 'team'},
              registration: {'priceMonthly': 49.99, 'status': 'included', 'included': true},
              planChanges: [
                {'plan': 'team', 'effective': 'periodEnd', 'charge': 0, 'credits': 0},
                {'plan': 'business', 'effective': 'keep', 'charge': 0, 'credits': 0},
              ],
            ),
            api: api),
      );
      expect(find.textContaining('moves to Team on the 1st'), findsOneWidget);
      expect(find.text('Starts on the 1st — nothing charged now'), findsOneWidget);
      expect(find.text('Keep Business (cancel the switch to Team)'), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-plan-includes-fee')), findsNothing);
      expect(find.text('Switch to Team on the 1st'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('seat-plan-business')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.tap(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.pumpAndSettle();
      expect(api.changes, ['business']);
    });

    testWidgets('upgradesOnly hides the plans that only switch on the 1st', (tester) async {
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c,
            upgradesOnly: true,
            status: seatStatus(
              members: 10,
              pending: 0,
              canManage: true,
              planChanges: [
                {'plan': 'team', 'effective': 'periodEnd', 'charge': 0, 'credits': 0},
                {'plan': 'business', 'effective': 'now', 'charge': 400, 'credits': 0},
              ],
            ),
            api: FakeSeatsApi()),
      );
      expect(find.text('Get more seats'), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-plan-team')), findsNothing);
      expect(find.byKey(const ValueKey('seat-plan-business')), findsOneWidget);
    });

    testWidgets('without a default card the confirm button is disabled', (tester) async {
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c,
            status: seatStatus(members: 10, pending: 0, canManage: true, hasPaymentMethod: false), api: FakeSeatsApi()),
      );
      expect(find.byKey(const ValueKey('seat-plan-no-card')), findsOneWidget);
      final confirm = tester.widget<FilledButton>(find.byKey(const ValueKey('seat-plan-confirm')));
      expect(confirm.onPressed, isNull);
    });

    testWidgets('shows the error when the change fails', (tester) async {
      final api = FakeSeatsApi(changeError: Exception('boom'));
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c, status: seatStatus(members: 10, pending: 0, canManage: true), api: api),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.tap(find.byKey(const ValueKey('seat-plan-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('seat-plan-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-plan-sheet')), findsOneWidget);
    });

    testWidgets('no plan to choose: explains instead', (tester) async {
      await openWith(
        tester,
        (c) => showSeatPlanSheet(c,
            upgradesOnly: true,
            status: seatStatus(members: 10, pending: 0, canManage: true, planChanges: const []),
            api: FakeSeatsApi()),
      );
      expect(find.byKey(const ValueKey('no-plan-options')), findsOneWidget);
      expect(find.byKey(const ValueKey('seat-plan-confirm')), findsNothing);
    });
  });

  test('a switch that resumes a canceled plan says so', () {
    final status = seatStatus(canManage: true, planChanges: [
      {'plan': 'team', 'effective': 'periodEnd', 'charge': 0, 'credits': 0, 'resumes': true},
    ]);
    final change = status.planChanges.single;
    expect(change.resumes, isTrue);
    expect(describeSeatPlanChange(status, change.planIn(status.plans)!, change),
        'Starts on the 1st — nothing charged now. This resumes your cancelled plan until then.');
  });
}
