import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storage/src/models.dart';
import 'package:storage/src/storage_plan.dart';
import 'package:storage/src/widgets/storage_plan_screen.dart';
import 'package:storage/src/widgets/usage_card.dart';

import 'support/fakes.dart';

const _gb = bytesPerGb;

StoragePlanStatus _status({
  String plan = StoragePlanStatus.free,
  int usageBytes = 10 * _gb,
  bool canManage = true,
  bool? hasPaymentMethod = true,
  bool payerIsYou = false,
  String? payerEmail,
  double estimatedMonthlyCost = 0,
}) =>
    StoragePlanStatus(
      plan: plan,
      usageBytes: usageBytes,
      freeTierGb: 50,
      uploadsAllowed: plan != StoragePlanStatus.free || usageBytes <= 50 * _gb,
      pricePerGbMonth: 0.0644,
      currentPricePerGbMonth: 0.0644,
      currency: 'CAD',
      estimatedMonthlyCost: estimatedMonthlyCost,
      canManage: canManage,
      payerIsYou: payerIsYou,
      payerEmail: payerEmail,
      hasPaymentMethod: canManage ? hasPaymentMethod : null,
    );

void main() {
  group('StoragePlanStatus', () {
    test('reads the callable payload', () {
      final status = StoragePlanStatus.fromMap({
        'plan': 'pay_as_you_go',
        'usageBytes': 60 * _gb,
        'freeTierGiB': 50,
        'uploadsAllowed': true,
        'price': {
          'pricePerGiBMonth': 0.06,
          'currentPricePerGiBMonth': 0.0644,
          'currency': 'CAD',
          'listUsdPerGiBMonth': 0.023,
          'markup': 2,
          'cadPerUsd': 1.4,
        },
        'estimatedMonthlyCost': 0.6,
        'canManage': true,
        'payerIsYou': true,
        'payerEmail': 'boss@bluejay.gg',
        'hasPaymentMethod': true,
      });
      expect(status.isPayAsYouGo, isTrue);
      expect(status.pricePerGbMonth, 0.06);
      expect(status.currentPricePerGbMonth, 0.0644);
      expect(status.freeTierBytes, 50 * _gb);
      expect(status.payerEmail, 'boss@bluejay.gg');
    });

    test('only the free tier refuses uploads past it', () {
      expect(_status(usageBytes: 49 * _gb).allowsUpload(_gb), isTrue);
      expect(_status(usageBytes: 49 * _gb).allowsUpload(_gb + 1), isFalse);
      expect(
          _status(plan: StoragePlanStatus.payAsYouGo, usageBytes: 99 * _gb)
              .allowsUpload(_gb),
          isTrue);
      expect(
          _status(plan: StoragePlanStatus.unlimited, usageBytes: 99 * _gb)
              .allowsUpload(_gb),
          isTrue);
    });

    test('formats prices and GB', () {
      expect(formatPrice(0.0644, 'CAD'), r'CA$0.0644');
      expect(formatPrice(0.05, 'USD'), r'US$0.05');
      expect(formatPrice(6.44, 'CAD'), r'CA$6.44');
      expect(formatPrice(0, 'CAD'), r'CA$0.00');
      expect(formatGb(50), '50 GB');
      expect(formatGb(12.54), '12.5 GB');
    });
  });

  group('StorageUsageCard', () {
    testWidgets('shows the group plan', (t) async {
      await t.pumpWidget(themed(Scaffold(
        body: StorageUsageCard(
          userSummary:
              const StorageUsageSummary(totalBytes: 250, totalFiles: 3),
          plan: _status(usageBytes: 10 * _gb),
        ),
      )));
      expect(find.text('3 files · Free tier · 10.0 GB of 50 GB'),
          findsOneWidget);
    });

    test('labels each plan', () {
      expect(StorageUsageCard.planLabel(null), 'Unlimited storage');
      expect(
          StorageUsageCard.planLabel(
              _status(plan: StoragePlanStatus.payAsYouGo)),
          'Pay as you go');
      expect(
          StorageUsageCard.planLabel(_status(plan: StoragePlanStatus.unlimited)),
          'Unlimited storage');
    });
  });

  group('StoragePlanScreen', () {
    Future<void> pump(
      WidgetTester t,
      StoragePlanStatus status, {
      List<String>? calls,
      StoragePlanStatus? after,
    }) async {
      t.view.physicalSize = const Size(900, 2400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(themed(StoragePlanScreen(
        load: () async => status,
        setPlan: (plan, price) async {
          calls?.add('$plan@$price');
          return after ?? status;
        },
      )));
      await t.pumpAndSettle();
    }

    testWidgets('shows usage and the price per GB and per 100 GB', (t) async {
      await pump(t, _status());
      expect(find.text('10.00 GB stored by the group'), findsOneWidget);
      expect(find.text('Free tier · up to 50 GB'), findsOneWidget);
      expect(find.text(r'CA$0.0644'), findsOneWidget);
      expect(find.text(r'CA$6.44'), findsOneWidget);
      expect(find.textContaining('Google Cloud'), findsNothing);
      expect(find.text('Billing'), findsNothing);
    });

    testWidgets('an admin turns on pay as you go at the price shown',
        (t) async {
      final calls = <String>[];
      await pump(t, _status(),
          calls: calls,
          after: _status(
              plan: StoragePlanStatus.payAsYouGo, payerIsYou: true));
      await t.tap(find.text('Pay as you go'));
      await t.pumpAndSettle();
      expect(find.text('Turn on pay as you go?'), findsOneWidget);
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(calls, ['pay_as_you_go@0.0644']);
      expect(find.text('Billing'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('members see the plan but cannot change it', (t) async {
      final calls = <String>[];
      await pump(t, _status(canManage: false), calls: calls);
      expect(find.textContaining('Only the group\'s admins'), findsOneWidget);
      await t.tap(find.text('Pay as you go'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.text('Turn on pay as you go?'), findsNothing);
      expect(calls, isEmpty);
    });

    testWidgets('an admin without a card is told to add one', (t) async {
      await pump(t, _status(hasPaymentMethod: false));
      expect(find.textContaining('Add a default card in Wallet'),
          findsOneWidget);
    });

    testWidgets('an unlimited group has no plan choice', (t) async {
      await pump(t, _status(plan: StoragePlanStatus.unlimited));
      expect(find.text('Unlimited storage'), findsOneWidget);
      expect(find.textContaining('unlimited storage at no charge'),
          findsOneWidget);
      expect(find.byType(BjOptionCards<String>), findsNothing);
    });

    testWidgets('pay as you go shows who pays and the estimate', (t) async {
      await pump(
          t,
          _status(
            plan: StoragePlanStatus.payAsYouGo,
            usageBytes: 60 * _gb,
            payerEmail: 'boss@bluejay.gg',
            estimatedMonthlyCost: 0.64,
          ));
      // Named from the group member directory; the email's local part
      // until it answers.
      expect(find.text('boss'), findsOneWidget);
      expect(find.text(r'CA$0.64'), findsOneWidget);
    });
  });
}
