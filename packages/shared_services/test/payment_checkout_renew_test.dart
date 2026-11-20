import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/payments/payment_checkout.dart';
import 'package:shared_services/payments/payment_checkout_view.dart';
import 'package:shared_services/payments/stripe_payment_checkout.dart';

/// A server whose every createOrder returns a fresh PaymentIntent secret,
/// and whose confirm answer is [serverStatus].
class _Backend implements PaymentsBackend {
  final createCalls = <String>[];
  String serverStatus = 'requires_payment';
  PaymentCheckoutException? createError;

  Map<String, dynamic> _order(String status) => {
        'orderId': 'order_1',
        'kind': 'k',
        'status': status,
        'currency': 'cad',
        'lineItems': [
          {'id': 'a', 'label': 'Thing', 'amountCents': 5000},
        ],
        'subtotalCents': 5000,
        'totalCents': 5000,
        'fulfillment': {'status': status == 'succeeded' ? 'fulfilled' : 'pending'},
        'lastPaymentError': status == 'failed' ? 'Your card was declined.' : null,
      };

  @override
  Future<Map<String, dynamic>> createOrder({
    required String kind,
    required String targetId,
    required String groupId,
  }) async {
    createCalls.add('$kind/$targetId/$groupId');
    final error = createError;
    if (error != null) throw error;
    final n = createCalls.length;
    return {
      ..._order('requires_payment'),
      'clientSecret': 'pi_${n}_secret_$n',
      'publishableKey': 'pk_test_platform',
      'stripeAccountId': 'acct_1OrgAccount01',
    };
  }

  @override
  Future<Map<String, dynamic>> confirmOrder(String orderId) async => _order(serverStatus);

  @override
  Future<Map<String, dynamic>> getOrder(String orderId) async => _order(serverStatus);
}

class _Confirmer implements PaymentConfirmer {
  final prepared = <String>[];
  final confirmed = <String>[];
  int releases = 0;
  PaymentConfirmOutcome outcome = PaymentConfirmOutcome.submitted;

  @override
  Future<void> prepare({required String publishableKey, required String stripeAccountId}) async {
    prepared.add(stripeAccountId);
  }

  @override
  Widget buildCardInput(BuildContext context, {required ValueChanged<bool> onCompleteChanged}) =>
      TextButton(key: const Key('fill'), onPressed: () => onCompleteChanged(true), child: const Text('fill'));

  @override
  Future<PaymentConfirmResult> confirm({
    required String clientSecret,
    PaymentBillingDetails billing = const PaymentBillingDetails(),
  }) async {
    confirmed.add(clientSecret);
    return PaymentConfirmResult(outcome, message: outcome == PaymentConfirmOutcome.failed ? 'Declined.' : null);
  }

  @override
  Future<void> release() async => releases += 1;
}

class _RecordingSettings extends _Settings {
  _RecordingSettings(super.publishableKey, super.stripeAccountId);

  final appliedAccounts = <String?>[];

  @override
  Future<void> apply() async {
    appliedAccounts.add(stripeAccountId);
    await super.apply();
  }
}

class _Settings implements StripeSettingsBinding {
  _Settings(this.publishableKey, this.stripeAccountId);

  @override
  String? publishableKey;
  @override
  String? stripeAccountId;
  int applies = 0;

  @override
  Future<void> apply() async => applies += 1;
}

void main() {
  testWidgets('after a decline the form gets a fresh PaymentIntent before the payer can retry', (tester) async {
    final backend = _Backend();
    final confirmer = _Confirmer()..outcome = PaymentConfirmOutcome.failed;
    backend.serverStatus = 'failed';
    final paid = <PaymentOrder>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentCheckoutView(
            kind: 'k',
            targetId: 't',
            groupId: 'g',
            checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
            onPaid: paid.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(find.text('Declined.'), findsOneWidget);
    expect(backend.createCalls, hasLength(2), reason: 'renewed after the failed attempt');
    expect(confirmer.prepared, hasLength(2), reason: 're-bound before the form is shown again');

    // The retry uses the renewed secret, and succeeds.
    confirmer.outcome = PaymentConfirmOutcome.submitted;
    backend.serverStatus = 'succeeded';
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(confirmer.confirmed, ['pi_1_secret_1', 'pi_2_secret_2']);
    expect(paid, hasLength(1));
    expect(confirmer.releases, greaterThanOrEqualTo(1), reason: 'released once paid');

    // Leaving the screen releases the binding too.
    final before = confirmer.releases;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(confirmer.releases, before + 1);
  });

  test('PaymentCheckout releases the binding when the order is paid, not between attempts', () async {
    final backend = _Backend();
    final confirmer = _Confirmer();
    final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
    final session = await checkout.start(kind: 'k', targetId: 't', groupId: 'g');
    backend.serverStatus = 'requires_payment';
    await checkout.confirm(session);
    expect(confirmer.releases, 0);
    backend.serverStatus = 'succeeded';
    final result = await checkout.confirm(session);
    expect(result.order.isSucceeded, isTrue);
    expect(confirmer.releases, 1);
    final renewed = await checkout.renew(session);
    expect(renewed.clientSecret, 'pi_2_secret_2');
    expect(renewed.kind, 'k');
  });

  test('StripePaymentConfirmer restores the previous Stripe settings on release', () async {
    final settings = _Settings('pk_test_platform_billing', null);
    final confirmer = StripePaymentConfirmer(leases: StripeLeaseManager(settings));
    await confirmer.prepare(publishableKey: 'pk_test_platform', stripeAccountId: 'acct_1OrgAccount01');
    expect(settings.stripeAccountId, 'acct_1OrgAccount01');
    expect(settings.publishableKey, 'pk_test_platform');
    expect(confirmer.isLeased, isTrue);
    // Re-preparing (renew) keeps the ORIGINAL settings to restore.
    await confirmer.prepare(publishableKey: 'pk_test_platform', stripeAccountId: 'acct_1OtherAcct02');
    await confirmer.release();
    expect(settings.stripeAccountId, isNull, reason: 'no other screen acts on a connected account');
    expect(settings.publishableKey, 'pk_test_platform_billing');
    expect(confirmer.isLeased, isFalse);
    final applies = settings.applies;
    await confirmer.release();
    expect(settings.applies, applies, reason: 'release is idempotent');
  });

  test('overlapping leases released out of order always end on the platform defaults', () async {
    for (final order in [
      [0, 1, 2],
      [2, 1, 0],
      [1, 0, 2],
      [0, 2, 1],
    ]) {
      final settings = _Settings('pk_test_platform_billing', null);
      final manager = StripeLeaseManager(settings);
      final confirmers = [for (var i = 0; i < 3; i++) StripePaymentConfirmer(leases: manager)];
      for (var i = 0; i < 3; i++) {
        await confirmers[i].prepare(publishableKey: 'pk_test_platform', stripeAccountId: 'acct_$i');
      }
      expect(settings.stripeAccountId, 'acct_2', reason: 'the newest lease wins');
      final live = {0, 1, 2};
      for (final i in order) {
        await confirmers[i].release();
        live.remove(i);
        if (live.isNotEmpty) {
          final newest = live.reduce((a, b) => a > b ? a : b);
          expect(settings.stripeAccountId, 'acct_$newest', reason: 'after releasing $i in $order');
        }
      }
      expect(settings.stripeAccountId, isNull, reason: 'defaults restored ($order)');
      expect(settings.publishableKey, 'pk_test_platform_billing');
      expect(manager.activeLeases, 0);
    }
  });

  test('re-binding a lease to another account never passes through the defaults', () async {
    final settings = _RecordingSettings('pk_default', null);
    final manager = StripeLeaseManager(settings);
    final confirmer = StripePaymentConfirmer(leases: manager);
    await confirmer.prepare(publishableKey: 'pk', stripeAccountId: 'acct_a');
    await confirmer.prepare(publishableKey: 'pk', stripeAccountId: 'acct_b');
    expect(settings.appliedAccounts, ['acct_a', 'acct_b', 'acct_b']);
    expect(manager.activeLeases, 1);
    await confirmer.release();
    expect(settings.stripeAccountId, isNull);
  });

  testWidgets('a refunded order never fires onPaid and says it was refunded', (tester) async {
    final backend = _Backend()..serverStatus = 'refunded';
    final confirmer = _Confirmer();
    final paid = <PaymentOrder>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentCheckoutView(
            kind: 'k',
            targetId: 't',
            groupId: 'g',
            checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
            onPaid: paid.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(paid, isEmpty);
    expect(find.byKey(const Key('payment-checkout-refunded')), findsOneWidget);
    expect(find.text('Payment refunded'), findsOneWidget);
    expect(find.byKey(const Key('payment-checkout-paid')), findsNothing);
  });

  test('order states: succeeded vs delivered vs refunded', () {
    PaymentOrder o(String status, {String fulfillment = 'pending'}) => PaymentOrder.fromMap({
          'orderId': 'o', 'status': status, 'fulfillment': {'status': fulfillment},
        });
    expect(o('succeeded').isSucceeded, isTrue);
    expect(o('succeeded').isDelivered, isFalse);
    expect(o('succeeded', fulfillment: 'fulfilled').isDelivered, isTrue);
    expect(o('partially_refunded', fulfillment: 'fulfilled').isSucceeded, isFalse);
    expect(o('partially_refunded').isRefunded, isTrue);
    expect(o('refunded').isFullyRefunded, isTrue);
  });

  Future<(_Backend, _Confirmer)> pumpDeclining(WidgetTester tester) async {
    final backend = _Backend()..serverStatus = 'failed';
    final confirmer = _Confirmer()..outcome = PaymentConfirmOutcome.failed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentCheckoutView(
            kind: 'k',
            targetId: 't',
            groupId: 'g',
            checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
            onPaid: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fill')));
    await tester.pump();
    return (backend, confirmer);
  }

  testWidgets('a failed renew never leaves a dead form: it shows a Try again that starts over', (tester) async {
    final (backend, _) = await pumpDeclining(tester);
    backend.createError = const PaymentCheckoutException('Server busy.', code: 'unavailable');
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-checkout-error')), findsOneWidget);
    final retry = find.byKey(const Key('payment-checkout-retry'));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    backend.createError = null;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-checkout-pay')), findsOneWidget);
  });

  testWidgets('after "too many attempts", Try again waits (and backs off further)', (tester) async {
    final (backend, _) = await pumpDeclining(tester);
    backend.createError = const PaymentCheckoutException('Too many checkout attempts.', code: 'resource-exhausted');
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    final retry = find.byKey(const Key('payment-checkout-retry'));
    expect(tester.widget<TextButton>(retry).onPressed, isNull, reason: 'held back');
    expect(find.text('Try again shortly'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    // Still rate limited: the next wait is longer.
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.widget<TextButton>(retry).onPressed, isNull, reason: 'backed off to 10s');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
  });

  testWidgets('an order under review shows a notice, no card form, and is never renewed', (tester) async {
    final backend = _Backend()..serverStatus = 'needs_review';
    final confirmer = _Confirmer();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentCheckoutView(
            kind: 'k',
            targetId: 't',
            groupId: 'g',
            checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
            onPaid: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fill')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-checkout-review')), findsOneWidget);
    expect(find.byKey(const Key('fill')), findsNothing);
    expect(backend.createCalls, hasLength(1), reason: 'no new checkout for a payment under review');
    expect(confirmer.releases, 1);
  });
}
