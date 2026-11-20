/// Group seats (plans/group-seats/DESIGN.md): how many people a group may
/// hold and the plans that set it. Members and pending invitations take
/// seats; guests don't. The Users app and Group Admin read a group's seats
/// and change its plan through the `groupSeats*` callables
/// (functions/group_seats.js); nothing here reads Firestore directly.
library;

import 'package:cloud_functions/cloud_functions.dart';

import 'cloud_functions.dart';
import 'platform_tax.dart';

/// One plan from `platform_config/group_seats`.
class SeatPlan {
  const SeatPlan({
    required this.id,
    required this.name,
    required this.seats,
    required this.priceMonthly,
    this.devQueues = 1,
  });

  final String id;
  final String name;
  final int seats;
  final double priceMonthly;

  /// Development queues the plan includes: how many of the group's requests
  /// can be in flight at once, shared by its members.
  final int devQueues;

  bool get isPaid => priceMonthly > 0;

  factory SeatPlan.fromData(Object? data) {
    final map = _map(data);
    return SeatPlan(
      id: _string(map['id']),
      name: _string(map['name']),
      seats: _int(map['seats']),
      priceMonthly: _double(map['priceMonthly']),
      devQueues: map['devQueues'] is num ? _int(map['devQueues']) : 1,
    );
  }
}

/// "1 developer agent", "2 developer agents".
String devQueuesLabel(int n) => n == 1 ? '1 developer agent' : '$n developer agents';

/// A group's development queues (`devQueues` in `groupSeatsStatus`).
class DevQueueSummary {
  const DevQueueSummary({this.mode, this.included, this.addOns = 0, this.bonus = 0, this.total});

  /// The group's dev queue mode: `pool` (one shared pool), `managed` or
  /// `platform` (run by Bluejay), or null (each member has their own queue).
  final String? mode;

  /// What the group's plan gives its shared pool; null without one.
  final int? included;

  /// Add-on queues the group's admins bought.
  final int addOns;

  /// Bonus queues Bluejay gave the group, never billed.
  final int bonus;

  /// [included] + [addOns] + [bonus]; null without a shared pool.
  final int? total;

  bool get isShared => mode == 'pool';

  factory DevQueueSummary.fromData(Object? data) {
    final map = _map(data);
    return DevQueueSummary(
      mode: _optString(map['mode']),
      included: map['included'] is num ? _int(map['included']) : null,
      addOns: _int(map['addOns']),
      bonus: _int(map['bonus']),
      total: map['total'] is num ? _int(map['total']) : null,
    );
  }
}

/// Add-on seats and development queues: today's prices and what the group
/// has bought (`addOns` in `groupSeatsStatus`, managers only).
class SeatAddOns {
  const SeatAddOns({
    required this.seatPriceMonthly,
    required this.devQueuePriceMonthly,
    required this.juniorDeveloperMonthly,
    this.seats = 0,
    this.devQueues = 0,
    this.paidSeats = 0,
    this.paidDevQueues = 0,
    this.monthly = 0,
    this.payerEmail,
    this.maxSeats = 1000,
    this.maxDevQueues = 50,
    this.canBuyDevQueues = true,
    this.days = 1,
    this.daysInMonth = 1,
  });

  final double seatPriceMonthly;
  final double devQueuePriceMonthly;

  /// What a junior developer costs a month, for the comparison beside a
  /// development queue's price.
  final double juniorDeveloperMonthly;

  /// Bought now.
  final int seats;
  final int devQueues;

  /// The most of each already paid for this month: going back up to these
  /// charges nothing more.
  final int paidSeats;
  final int paidDevQueues;

  /// What [seats] and [devQueues] are billed a month.
  final double monthly;
  final String? payerEmail;
  final int maxSeats;
  final int maxDevQueues;

  /// False when Bluejay runs the group's queue (managed or staff groups).
  final bool canBuyDevQueues;

  /// The rest of this month, which a purchase today is charged for.
  final int days;
  final int daysInMonth;

  /// How much less a development queue costs than a junior developer, in
  /// whole percent (0 when it doesn't).
  int get savingsPercent {
    if (juniorDeveloperMonthly <= 0 || devQueuePriceMonthly >= juniorDeveloperMonthly) return 0;
    return ((1 - devQueuePriceMonthly / juniorDeveloperMonthly) * 100).floor();
  }

  /// The monthly price of [seats] and [devQueues] at today's prices.
  double monthlyFor({required int seats, required int devQueues}) =>
      ((seatPriceMonthly * 100).round() * seats + (devQueuePriceMonthly * 100).round() * devQueues) / 100;

  /// What changing to [seats] and [devQueues] charges today: each count
  /// above what was already paid this month, for the rest of the month (the
  /// server's `addOnsChangeCharge`). Going down charges nothing.
  double chargeToday({required int seats, required int devQueues}) {
    final added = monthlyFor(
      seats: seats > paidSeats ? seats - paidSeats : 0,
      devQueues: devQueues > paidDevQueues ? devQueues - paidDevQueues : 0,
    );
    if (daysInMonth <= 0) return added;
    return ((added * 100).round() * days / daysInMonth).round() / 100;
  }

  static SeatAddOns? fromData(Object? data) {
    if (data is! Map) return null;
    final map = _map(data);
    return SeatAddOns(
      seatPriceMonthly: _double(map['seatPriceMonthly']),
      devQueuePriceMonthly: _double(map['devQueuePriceMonthly']),
      juniorDeveloperMonthly: _double(map['juniorDeveloperMonthly']),
      seats: _int(map['seats']),
      devQueues: _int(map['devQueues']),
      paidSeats: _int(map['paidSeats']),
      paidDevQueues: _int(map['paidDevQueues']),
      monthly: _double(map['monthly']),
      payerEmail: _optString(map['payerEmail']),
      maxSeats: map['maxSeats'] is num ? _int(map['maxSeats']) : 1000,
      maxDevQueues: map['maxDevQueues'] is num ? _int(map['maxDevQueues']) : 50,
      canBuyDevQueues: map['canBuyDevQueues'] != false,
      days: map['days'] is num ? _int(map['days']) : 1,
      daysInMonth: map['daysInMonth'] is num ? _int(map['daysInMonth']) : 1,
    );
  }
}

/// The paid (or comped) plan a group is on: `group_seat_plans/{groupId}`.
class SeatPlanSubscription {
  const SeatPlanSubscription({
    required this.plan,
    required this.status,
    required this.priceMonthly,
    required this.currency,
    required this.comped,
    this.payerId,
    this.payerEmail,
    this.endsAt,
    this.lastBilledPeriod,
    this.nextPlan,
  });

  final String plan;

  /// `active`, `canceled` (keeps its seats until [endsAt]) or `ended`.
  final String status;
  final double priceMonthly;
  final String currency;

  /// Set up by a platform admin and never billed; only Seat Management changes it.
  final bool comped;
  final String? payerId;
  final String? payerEmail;
  final DateTime? endsAt;
  final String? lastBilledPeriod;

  /// The plan id a paid plan moves to on the 1st (a switch to fewer seats),
  /// or null when none is scheduled.
  final String? nextPlan;

  bool get isActive => status == 'active';
  bool get isCanceled => status == 'canceled';

  static SeatPlanSubscription? fromData(Object? data) {
    if (data is! Map) return null;
    final map = _map(data);
    return SeatPlanSubscription(
      plan: _string(map['plan']),
      status: _string(map['status']),
      priceMonthly: _double(map['priceMonthly']),
      currency: _string(map['currency'], 'CAD'),
      comped: map['comped'] == true,
      payerId: map['payerId'] as String?,
      payerEmail: map['payerEmail'] as String?,
      endsAt: _date(map['endsAt']),
      lastBilledPeriod: map['lastBilledPeriod'] as String?,
      nextPlan: _optString(map['nextPlan']),
    );
  }
}

/// The group's paid registration fee (`group_subscriptions`,
/// plans/purchasable-groups) as `groupSeatsStatus` reports it to managers.
/// A live paid seat plan includes it ([included]).
class SeatRegistration {
  const SeatRegistration({required this.priceMonthly, required this.status, required this.included});

  final double priceMonthly;

  /// `active`, `canceled`, `included` or `ended`.
  final String status;

  /// Whether a paid seat plan includes the fee, so it isn't billed on its own.
  final bool included;

  static SeatRegistration? fromData(Object? data) {
    if (data is! Map) return null;
    final map = _map(data);
    return SeatRegistration(
      priceMonthly: _double(map['priceMonthly']),
      status: _string(map['status']),
      included: map['included'] == true,
    );
  }
}

/// One plan a group admin can choose now and what choosing it does
/// (`planChanges`, the server's `planChangeQuote`).
class SeatPlanChange {
  const SeatPlanChange({
    required this.planId,
    required this.effective,
    required this.charge,
    required this.credits,
    this.resumes = false,
  });

  /// Effective [now]: more seats, switched today and charged [charge].
  static const String now = 'now';

  /// Effective [periodEnd]: fewer seats, switched on the 1st, nothing charged now.
  static const String periodEnd = 'periodEnd';

  /// Effective [keep]: the live plan again, taking back a scheduled switch.
  static const String keep = 'keep';

  final String planId;

  /// [now], [periodEnd] or [keep].
  final String effective;

  /// Charged today (after [credits]); 0 unless [isNow].
  final double charge;

  /// The unused part of this month's seat plan and registration fees,
  /// already taken off [charge].
  final double credits;

  /// Choosing it resumes the current, canceled plan (a [periodEnd] switch).
  final bool resumes;

  bool get isNow => effective == now;
  bool get isPeriodEnd => effective == periodEnd;
  bool get isKeep => effective == keep;

  /// The plan from [plans] this change moves to, or null if unknown.
  SeatPlan? planIn(List<SeatPlan> plans) {
    for (final plan in plans) {
      if (plan.id == planId) return plan;
    }
    return null;
  }

  factory SeatPlanChange.fromData(Object? data) {
    final map = _map(data);
    return SeatPlanChange(
      planId: _string(map['plan']),
      effective: _string(map['effective']),
      charge: _double(map['charge']),
      credits: _double(map['credits']),
      resumes: map['resumes'] == true,
    );
  }
}

/// A group's seats, as `groupSeatsStatus` answers (DESIGN.md `SeatStatus`).
class SeatStatus {
  const SeatStatus({
    required this.groupId,
    required this.groupName,
    required this.plan,
    required this.bonusSeats,
    this.addOnSeats = 0,
    required this.unlimited,
    required this.limit,
    required this.members,
    required this.pending,
    required this.used,
    required this.available,
    required this.canManage,
    required this.plans,
    required this.currency,
    this.subscription,
    this.hasPaymentMethod,
    this.registration,
    this.planChanges = const [],
    this.devQueues = const DevQueueSummary(),
    this.addOns,
    this.tax = PlatformTax.off,
  });

  final String groupId;
  final String groupName;
  final SeatPlan plan;
  final int bonusSeats;

  /// Seats the group's admins bought on top of the plan.
  final int addOnSeats;
  final bool unlimited;

  /// Null when [unlimited].
  final int? limit;
  final int members;
  final int pending;

  /// [members] + [pending].
  final int used;

  /// Seats left, counting pending invitations; null when [unlimited].
  final int? available;

  /// A group admin (or a platform admin): may change plans, cancel and resume.
  final bool canManage;

  /// Every plan, cheapest first.
  final List<SeatPlan> plans;
  final String currency;

  /// Only for [canManage] callers.
  final SeatPlanSubscription? subscription;

  /// Whether the caller has a default card (only for [canManage] callers).
  final bool? hasPaymentMethod;

  bool get isFull => !unlimited && (available ?? 0) <= 0;

  /// The group's paid registration fee (only for [canManage] callers).
  final SeatRegistration? registration;

  /// The paid plans a [canManage] caller can choose now, each with what it
  /// would do (switch today, on the 1st, or keep the live plan).
  final List<SeatPlanChange> planChanges;

  /// The group's development queues.
  final DevQueueSummary devQueues;

  /// Add-on prices and what the group bought (only for [canManage] callers).
  final SeatAddOns? addOns;

  /// Whether prices are quoted plus tax (off until Bluejay is registered).
  final PlatformTax tax;

  /// [planChanges] whose plan is known, cheapest first, paired with it.
  List<(SeatPlan, SeatPlanChange)> get planOptions {
    final options = <(SeatPlan, SeatPlanChange)>[];
    for (final change in planChanges) {
      final plan = change.planIn(plans);
      if (plan != null) options.add((plan, change));
    }
    options.sort((a, b) => a.$1.priceMonthly.compareTo(b.$1.priceMonthly));
    return options;
  }

  /// The [planOptions] that add seats today (effective now): what a full
  /// group needs.
  List<(SeatPlan, SeatPlanChange)> get upgradeOptions => planOptions.where((o) => o.$2.isNow).toList();

  /// The plan [subscription] moves to on the 1st, if one is scheduled.
  SeatPlan? get nextPlan {
    final id = subscription?.nextPlan;
    if (id == null) return null;
    for (final plan in plans) {
      if (plan.id == id) return plan;
    }
    return null;
  }

  factory SeatStatus.fromData(Object? data) {
    final map = _map(data);
    return SeatStatus(
      groupId: _string(map['groupId']),
      groupName: _string(map['groupName']),
      plan: SeatPlan.fromData(map['plan']),
      bonusSeats: _int(map['bonusSeats']),
      addOnSeats: _int(map['addOnSeats']),
      unlimited: map['unlimited'] == true,
      limit: map['limit'] == null ? null : _int(map['limit']),
      members: _int(map['members']),
      pending: _int(map['pending']),
      used: _int(map['used']),
      available: map['available'] == null ? null : _int(map['available']),
      canManage: map['canManage'] == true,
      plans: (map['plans'] is List ? map['plans'] as List : const []).map(SeatPlan.fromData).toList(),
      currency: _string(map['currency'], 'CAD'),
      subscription: SeatPlanSubscription.fromData(map['subscription']),
      hasPaymentMethod: map['hasPaymentMethod'] as bool?,
      registration: SeatRegistration.fromData(map['registration']),
      planChanges:
          (map['planChanges'] is List ? map['planChanges'] as List : const []).map(SeatPlanChange.fromData).toList(),
      devQueues: DevQueueSummary.fromData(map['devQueues']),
      addOns: SeatAddOns.fromData(map['addOns']),
      tax: PlatformTax.fromData(map['tax']),
    );
  }
}

/// Whether [error] is a server refusal for lack of seats (`details.reason == 'no-seats'`).
bool isNoSeatsError(Object error) {
  if (error is! FirebaseFunctionsException) return false;
  final details = error.details;
  return details is Map && details['reason'] == 'no-seats';
}

/// The message to show for a failed `groupSeats*` (or `inviteMember`) call:
/// the server's own message when it sent one.
String seatErrorMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    final message = (error.message ?? '').trim();
    if (message.isNotEmpty) return message;
    return switch (error.code) {
      'unavailable' || 'deadline-exceeded' => "Couldn't reach Bluejay. Check your connection and try again.",
      'permission-denied' => "You don't have permission to do that.",
      _ => 'Something went wrong. Try again.',
    };
  }
  return 'Something went wrong. Try again.';
}

/// The `groupSeats*` callables. Screens take one so tests can pass a fake.
class GroupSeatsApi {
  const GroupSeatsApi();

  Future<SeatStatus> status(String groupId) async =>
      SeatStatus.fromData(await BluejayCallable.call('groupSeatsStatus', {'groupId': groupId}));

  /// Moves [groupId] onto paid [plan] (`groupSeatsChangePlan`), billed
  /// monthly to the caller's default card: more seats switch today with a
  /// prorated charge, fewer seats switch on the 1st, and the live plan again
  /// takes back a scheduled switch. [plan]'s price is sent back as the price
  /// the caller accepted.
  Future<SeatStatus> changePlan(String groupId, SeatPlan plan) async => SeatStatus.fromData(await BluejayCallable.call(
      'groupSeatsChangePlan', {'groupId': groupId, 'plan': plan.id, 'acceptedPriceMonthly': plan.priceMonthly}));

  Future<SeatStatus> cancel(String groupId) async =>
      SeatStatus.fromData(await BluejayCallable.call('groupSeatsCancel', {'groupId': groupId}));

  Future<SeatStatus> resume(String groupId) async =>
      SeatStatus.fromData(await BluejayCallable.call('groupSeatsResume', {'groupId': groupId}));

  /// Sets [groupId]'s add-on [seats] and [devQueues]
  /// (`groupSeatsSetAddOns`), billed monthly to the caller's default card:
  /// what goes up is charged today for the rest of the month, what goes down
  /// comes off now. [addOns]' prices are sent back as the prices the caller
  /// accepted.
  Future<SeatStatus> setAddOns(String groupId, SeatAddOns addOns, {required int seats, required int devQueues}) async =>
      SeatStatus.fromData(await BluejayCallable.call('groupSeatsSetAddOns', {
        'groupId': groupId,
        'seats': seats,
        'devQueues': devQueues,
        'acceptedSeatPriceMonthly': addOns.seatPriceMonthly,
        'acceptedDevQueuePriceMonthly': addOns.devQueuePriceMonthly,
      }));

  /// Asks the group's admins for more seats; returns how many were notified.
  Future<int> requestMore(String groupId, {String? message}) async {
    final data = _map(await BluejayCallable.call('groupSeatsRequestMore', {
      'groupId': groupId,
      if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
    }));
    return _int(data['notified']);
  }
}

Map<String, dynamic> _map(Object? data) =>
    data is Map ? data.map((key, value) => MapEntry(key.toString(), value)) : <String, dynamic>{};

String _string(Object? value, [String fallback = '']) => value is String ? value : fallback;

String? _optString(Object? value) => value is String && value.isNotEmpty ? value : null;

int _int(Object? value) => value is num ? value.toInt() : 0;

double _double(Object? value) => value is num ? value.toDouble() : 0;

DateTime? _date(Object? value) => value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;
