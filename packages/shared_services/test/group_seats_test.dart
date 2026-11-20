import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/group_seats.dart';

Map<String, dynamic> statusData({Object? planChanges, Object? subscription, Object? registration}) => {
      'groupId': 'fam',
      'groupName': 'Family',
      'plan': {'id': 'team', 'name': 'Team', 'seats': 25, 'priceMonthly': 249},
      'limit': 25,
      'members': 20,
      'pending': 1,
      'used': 21,
      'available': 4,
      'canManage': true,
      'plans': [
        {'id': 'personal', 'name': 'Personal', 'seats': 10, 'priceMonthly': 0},
        {'id': 'team', 'name': 'Team', 'seats': 25, 'priceMonthly': 249},
        {'id': 'business', 'name': 'Business', 'seats': 50, 'priceMonthly': 999},
      ],
      'currency': 'CAD',
      'subscription': subscription,
      'hasPaymentMethod': true,
      'registration': registration,
      'planChanges': planChanges,
    };

void main() {
  test('parses registration, planChanges and nextPlan', () {
    final status = SeatStatus.fromData(statusData(
      subscription: {'plan': 'business', 'status': 'active', 'priceMonthly': 999, 'nextPlan': 'team'},
      registration: {'priceMonthly': 49.99, 'status': 'included', 'included': true},
      planChanges: [
        {'plan': 'team', 'effective': 'periodEnd', 'charge': 0, 'credits': 0},
        {'plan': 'business', 'effective': 'keep', 'charge': 0, 'credits': 0},
      ],
    ));
    expect(status.subscription!.nextPlan, 'team');
    expect(status.nextPlan!.name, 'Team');
    expect(status.registration!.priceMonthly, 49.99);
    expect(status.registration!.included, isTrue);
    expect(status.planChanges.map((c) => c.effective), ['periodEnd', 'keep']);
    expect(status.planOptions.map((o) => o.$1.id), ['team', 'business']);
    expect(status.planOptions.first.$2.isPeriodEnd, isTrue);
    expect(status.upgradeOptions, isEmpty);
  });

  test('reads whether prices are quoted plus tax; off when the server sends none', () {
    expect(SeatStatus.fromData(statusData()).tax.enabled, isFalse);
    final taxed = SeatStatus.fromData({
      ...statusData(),
      'tax': {'enabled': true, 'rateBps': 1300, 'label': 'HST (Ontario)', 'registrationNumber': 'RT1'},
    });
    expect(taxed.tax.enabled, isTrue);
    expect(taxed.tax.registrationNumber, 'RT1');
  });

  test('upgradeOptions keeps only the changes that add seats today', () {
    final status = SeatStatus.fromData(statusData(planChanges: [
      {'plan': 'business', 'effective': 'now', 'charge': 512.4, 'credits': 140.25},
      {'plan': 'gone', 'effective': 'now', 'charge': 1, 'credits': 0},
    ]));
    expect(status.planOptions, hasLength(1), reason: 'a plan the status does not list is skipped');
    final (plan, change) = status.upgradeOptions.single;
    expect(plan.id, 'business');
    expect(change.isNow, isTrue);
    expect(change.charge, 512.4);
    expect(change.credits, 140.25);
    expect(change.planIn(status.plans), same(plan));
  });

  test('a member sees no registration, plan changes or next plan', () {
    final status = SeatStatus.fromData(statusData());
    expect(status.registration, isNull);
    expect(status.planChanges, isEmpty);
    expect(status.nextPlan, isNull);
    expect(status.subscription, isNull);
  });

  test('add-on charge counts only what goes above this month\'s paid counts', () {
    final addOns = SeatAddOns.fromData({
      'seatPriceMonthly': 24.68,
      'devQueuePriceMonthly': 296.37,
      'juniorDeveloperMonthly': 5833.33,
      'seats': 0,
      'devQueues': 0,
      'paidSeats': 0,
      'paidDevQueues': 1,
      'days': 21,
      'daysInMonth': 30,
    })!;
    expect(addOns.chargeToday(seats: 0, devQueues: 1), 0, reason: 'paid for this month already');
    expect(addOns.chargeToday(seats: 0, devQueues: 2), 207.46);
    expect(addOns.chargeToday(seats: 2, devQueues: 0), 34.55);
    expect(addOns.savingsPercent, 94);
  });
}
