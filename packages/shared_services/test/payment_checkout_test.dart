import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/payments/payment_checkout.dart';
import 'package:shared_services/payments/payment_checkout_view.dart';

/// A server that behaves like paymentsCreateOrder / paymentsConfirmOrder.
class FakeBackend implements PaymentsBackend {
  FakeBackend({this.createError, this.surcharges = const []});

  PaymentCheckoutException? createError;
  final List<Map<String, dynamic>> surcharges;

  /// What the server says after Stripe: the order's status as verified there.
  String serverStatus = 'requires_payment';
  String fulfillment = 'pending';
  String? lastPaymentError;
  final createCalls = <Map<String, String>>[];
  int confirmCalls = 0;
  bool alreadyPaid = false;

  Map<String, dynamic> _order(String status) => {
        'orderId': 'order_1',
        'kind': 'test.widget',
        'status': status,
        'currency': 'cad',
        'description': 'Widget',
        'lineItems': [
          {'id': 'base', 'label': 'Widget', 'amountCents': 5000, 'quantity': 1},
          {'id': 'addon', 'label': 'Add-on', 'amountCents': 1500, 'quantity': 1},
        ],
        'subtotalCents': 6500,
        'surcharges': surcharges,
        'totalCents': 6500 + surcharges.fold<int>(0, (sum, s) => sum + (s['amountCents'] as int)),
        'fulfillment': {'status': fulfillment},
        'lastPaymentError': lastPaymentError,
      };

  @override
  Future<Map<String, dynamic>> createOrder({
    required String kind,
    required String targetId,
    required String groupId,
  }) async {
    createCalls.add({'kind': kind, 'targetId': targetId, 'groupId': groupId});
    final error = createError;
    if (error != null) throw error;
    // Like the server after a failed attempt: a confirmable PaymentIntent again.
    final n = createCalls.length;
    return {
      ..._order(alreadyPaid ? 'succeeded' : 'requires_payment'),
      'clientSecret': alreadyPaid ? null : 'pi_${n}_secret_$n',
      'publishableKey': 'pk_test_platform',
      'stripeAccountId': 'acct_1OrgAccount01',
    };
  }

  @override
  Future<Map<String, dynamic>> getOrder(String orderId) async => _order(serverStatus);

  @override
  Future<Map<String, dynamic>> confirmOrder(String orderId) async {
    confirmCalls += 1;
    return _order(serverStatus);
  }
}

class FakeConfirmer implements PaymentConfirmer {
  FakeConfirmer({this.outcome = PaymentConfirmOutcome.submitted, this.message});

  PaymentConfirmOutcome outcome;
  String? message;
  final prepared = <Map<String, String>>[];
  final confirmed = <String>[];
  int releases = 0;
  PaymentBillingDetails? lastBilling;

  @override
  Future<void> release() async {
    releases += 1;
  }

  @override
  Future<void> prepare({required String publishableKey, required String stripeAccountId}) async {
    prepared.add({'publishableKey': publishableKey, 'stripeAccountId': stripeAccountId});
  }

  @override
  Widget buildCardInput(BuildContext context, {required ValueChanged<bool> onCompleteChanged}) {
    return TextButton(
      key: const Key('fake-card-complete'),
      onPressed: () => onCompleteChanged(true),
      child: const Text('Fill card'),
    );
  }

  @override
  Future<PaymentConfirmResult> confirm({
    required String clientSecret,
    PaymentBillingDetails billing = const PaymentBillingDetails(),
  }) async {
    confirmed.add(clientSecret);
    lastBilling = billing;
    return PaymentConfirmResult(outcome, message: message);
  }
}

void main() {
  group('PaymentCheckout', () {
    test('start creates an order (no amount sent) and binds the confirmer to the connected account', () async {
      final backend = FakeBackend();
      final confirmer = FakeConfirmer();
      final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
      final session = await checkout.start(kind: 'test.widget', targetId: 'w1', groupId: 'g1');
      expect(backend.createCalls.single, {'kind': 'test.widget', 'targetId': 'w1', 'groupId': 'g1'});
      expect(confirmer.prepared.single,
          {'publishableKey': 'pk_test_platform', 'stripeAccountId': 'acct_1OrgAccount01'});
      expect(session.order.totalCents, 6500);
      expect(session.order.lineItems.map((i) => i.label), ['Widget', 'Add-on']);
      expect(session.clientSecret, 'pi_1_secret_1');
    });

    test('confirm returns the server-verified order, never the client\'s opinion', () async {
      final backend = FakeBackend();
      final confirmer = FakeConfirmer();
      final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
      final session = await checkout.start(kind: 'test.widget', targetId: 'w1', groupId: 'g1');

      // Stripe accepted the attempt, but the server hasn't seen a success.
      var result = await checkout.confirm(session);
      expect(result.order.isSucceeded, isFalse);
      expect(result.message, isNotNull);

      backend.serverStatus = 'succeeded';
      backend.fulfillment = 'fulfilled';
      result = await checkout.confirm(session, billing: const PaymentBillingDetails(name: 'Pat'));
      expect(result.order.isSucceeded, isTrue);
      expect(result.order.isFulfilled, isTrue);
      expect(result.message, isNull);
      expect(confirmer.confirmed, ['pi_1_secret_1', 'pi_1_secret_1']);
      expect(confirmer.lastBilling?.name, 'Pat');
      expect(backend.confirmCalls, 2);
    });

    test('a declined card still asks the server, and reports the decline', () async {
      final backend = FakeBackend()..serverStatus = 'failed';
      final confirmer = FakeConfirmer(outcome: PaymentConfirmOutcome.failed, message: 'Your card was declined.');
      final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
      final session = await checkout.start(kind: 'test.widget', targetId: 'w1', groupId: 'g1');
      final result = await checkout.confirm(session);
      expect(result.order.status, 'failed');
      expect(result.message, 'Your card was declined.');
      expect(backend.confirmCalls, 1);
    });

    test('a cancelled authentication (3-D Secure closed) does not call the server', () async {
      final backend = FakeBackend();
      final confirmer = FakeConfirmer(outcome: PaymentConfirmOutcome.canceled, message: 'Cancelled');
      final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
      final session = await checkout.start(kind: 'test.widget', targetId: 'w1', groupId: 'g1');
      final result = await checkout.confirm(session);
      expect(result.canceled, isTrue);
      expect(result.order.isSucceeded, isFalse);
      expect(backend.confirmCalls, 0);
    });

    test('an already-paid order needs no confirmation', () async {
      final backend = FakeBackend()
        ..alreadyPaid = true
        ..serverStatus = 'succeeded';
      final confirmer = FakeConfirmer();
      final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
      final session = await checkout.start(kind: 'test.widget', targetId: 'w1', groupId: 'g1');
      expect(session.clientSecret, isNull);
      expect(confirmer.prepared, isEmpty);
      final result = await checkout.confirm(session);
      expect(result.order.isSucceeded, isTrue);
      expect(confirmer.confirmed, isEmpty);
    });

    test('payments-not-set-up reasons are recognisable', () {
      expect(const PaymentCheckoutException('x', reason: 'payments_not_configured').paymentsNotSetUp, isTrue);
      expect(const PaymentCheckoutException('x', reason: 'charges_not_enabled').paymentsNotSetUp, isTrue);
      expect(const PaymentCheckoutException('x', code: 'permission-denied').paymentsNotSetUp, isFalse);
    });

    test('formatPaymentAmount', () {
      expect(formatPaymentAmount(123456, 'cad'), '\$1,234.56 CAD');
      expect(formatPaymentAmount(5, 'usd'), '\$0.05 USD');
    });
  });

  group('PaymentCheckoutView', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the itemized total including surcharges, and pays once the server confirms',
        (tester) async {
      final backend = FakeBackend(surcharges: [
        {'id': 'card', 'label': 'Card fee', 'amountCents': 100},
      ]);
      final confirmer = FakeConfirmer();
      final paid = <PaymentOrder>[];
      await pump(
        tester,
        PaymentCheckoutView(
          kind: 'test.widget',
          targetId: 'w1',
          groupId: 'g1',
          checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
          onPaid: paid.add,
        ),
      );
      expect(find.text('Add-on'), findsOneWidget);
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('Card fee'), findsOneWidget);
      expect(find.text('\$66.00 CAD'), findsOneWidget);

      final pay = find.byKey(const Key('payment-checkout-pay'));
      expect(tester.widget<FilledButton>(pay).onPressed, isNull, reason: 'card incomplete');
      await tester.tap(find.byKey(const Key('fake-card-complete')));
      await tester.pump();
      backend.serverStatus = 'succeeded';
      backend.fulfillment = 'fulfilled';
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(paid, hasLength(1));
      expect(paid.single.isSucceeded, isTrue);
      expect(find.byKey(const Key('payment-checkout-paid')), findsOneWidget);
    });

    testWidgets('a decline is shown and nothing is reported paid', (tester) async {
      final backend = FakeBackend()..lastPaymentError = 'Your card was declined.';
      final confirmer = FakeConfirmer(outcome: PaymentConfirmOutcome.failed, message: 'Your card was declined.');
      final paid = <PaymentOrder>[];
      await pump(
        tester,
        PaymentCheckoutView(
          kind: 'test.widget',
          targetId: 'w1',
          groupId: 'g1',
          checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
          onPaid: paid.add,
        ),
      );
      await tester.tap(find.byKey(const Key('fake-card-complete')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('payment-checkout-pay')));
      await tester.pumpAndSettle();
      expect(paid, isEmpty);
      expect(find.text('Your card was declined.'), findsOneWidget);
    });

    testWidgets('an organization without payments shows the not-set-up path, never a card field',
        (tester) async {
      final backend = FakeBackend(
        createError: const PaymentCheckoutException(
          "Payments aren't set up for this organization yet.",
          code: 'failed-precondition',
          reason: 'payments_not_configured',
        ),
      );
      final confirmer = FakeConfirmer();
      await pump(
        tester,
        PaymentCheckoutView(
          kind: 'test.widget',
          targetId: 'w1',
          groupId: 'g1',
          checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
          onPaid: (_) {},
          notSetUpBuilder: (context, message) => Text('QUOTE ONLY: $message', key: const Key('quote-only')),
        ),
      );
      expect(find.byKey(const Key('quote-only')), findsOneWidget);
      expect(find.byKey(const Key('fake-card-complete')), findsNothing);
      expect(confirmer.prepared, isEmpty);
    });

    testWidgets('other start errors offer a retry', (tester) async {
      final backend = FakeBackend(
        createError: const PaymentCheckoutException('Too many checkout attempts.', code: 'resource-exhausted'),
      );
      await pump(
        tester,
        PaymentCheckoutView(
          kind: 'test.widget',
          targetId: 'w1',
          groupId: 'g1',
          checkout: PaymentCheckout(backend: backend, confirmer: FakeConfirmer()),
          onPaid: (_) {},
        ),
      );
      expect(find.byKey(const Key('payment-checkout-error')), findsOneWidget);
      backend.createError = null;
      // Rate limited: Try again is held back for a few seconds first.
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.byKey(const Key('payment-checkout-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-checkout-pay')), findsOneWidget);
      expect(backend.createCalls, hasLength(2));
    });
  });
}
