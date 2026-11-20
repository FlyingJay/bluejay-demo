import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/payments/payment_checkout.dart';
import 'package:shared_services/payments/payment_checkout_testing.dart';
import 'package:shared_services/payments/payment_checkout_view.dart';
import 'package:shared_services/payments/stripe_payment_checkout.dart';

/// The Stripe SDK settings, recorded (no platform channel).
class _Settings implements StripeSettingsBinding {
  _Settings(this.publishableKey, this.stripeAccountId);

  @override
  String? publishableKey;
  @override
  String? stripeAccountId;
  final applied = <String?>[];

  @override
  Future<void> apply() async => applied.add(stripeAccountId);
}

/// A server answering like paymentsCreateOrder for a platform-account kind.
class _PlatformBackend extends FakePaymentsBackend {
  _PlatformBackend({this.stripeAccountId}) : super(platformAccount: true, description: 'Bluejay usage');

  /// A misconfigured answer: a platform order that names a connected account.
  final String? stripeAccountId;

  @override
  Future<Map<String, dynamic>> createOrder({
    required String kind,
    required String targetId,
    required String groupId,
  }) async {
    final map = await super.createOrder(kind: kind, targetId: targetId, groupId: groupId);
    if (stripeAccountId != null) map['stripeAccountId'] = stripeAccountId;
    return map;
  }
}

void main() {
  test('a platform-account session confirms on the platform: no connected account is bound', () async {
    final backend = _PlatformBackend();
    final confirmer = FakePaymentConfirmer();
    final checkout = PaymentCheckout(backend: backend, confirmer: confirmer);
    final session = await checkout.start(kind: 'platform.invoice', targetId: 'inv_1', groupId: 'g1');
    expect(session.isPlatformAccount, isTrue);
    expect(session.stripeAccountId, isEmpty);
    expect(backend.createCalls.single, {'kind': 'platform.invoice', 'targetId': 'inv_1', 'groupId': 'g1'});
    expect(confirmer.prepared.single, {'publishableKey': 'pk_test_platform', 'stripeAccountId': ''});
  });

  test('a platform session that names a connected account is refused (account confusion)', () async {
    final checkout = PaymentCheckout(
      backend: _PlatformBackend(stripeAccountId: 'acct_1OrgAccount01'),
      confirmer: FakePaymentConfirmer(),
    );
    await expectLater(
      checkout.start(kind: 'platform.invoice', targetId: 'inv_1', groupId: 'g1'),
      throwsA(isA<PaymentCheckoutException>()),
    );
  });

  test('a connected session without an account is refused', () async {
    final backend = FakePaymentsBackend();
    final checkout = PaymentCheckout(backend: _NoAccountBackend(backend), confirmer: FakePaymentConfirmer());
    await expectLater(
      checkout.start(kind: 'k', targetId: 't', groupId: 'g'),
      throwsA(isA<PaymentCheckoutException>()),
    );
  });

  test('a platform lease unbinds the SDK from a connected account, and releasing restores the newest lease', () async {
    final settings = _Settings('pk_default', null);
    final manager = StripeLeaseManager(settings);
    final connected = StripePaymentConfirmer(leases: manager);
    final platform = StripePaymentConfirmer(leases: manager);
    await connected.prepare(publishableKey: 'pk', stripeAccountId: 'acct_org');
    expect(settings.stripeAccountId, 'acct_org');
    await platform.prepare(publishableKey: 'pk', stripeAccountId: '');
    expect(settings.stripeAccountId, isNull, reason: 'an invoice is paid on the platform account');
    await platform.release();
    expect(settings.stripeAccountId, 'acct_org');
    await connected.release();
    expect(settings.stripeAccountId, isNull);
    expect(settings.publishableKey, 'pk_default');
    expect(manager.activeLeases, 0);
  });

  testWidgets('PaymentCheckoutView pays a platform invoice and reports it paid', (tester) async {
    final backend = FakePaymentsBackend(platformAccount: true, serverPriceCents: 3955, description: 'Bluejay usage');
    final confirmer = FakePaymentConfirmer();
    final paid = <PaymentOrder>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentCheckoutView(
            kind: 'platform.invoice',
            targetId: 'inv_1',
            groupId: 'g1',
            checkout: PaymentCheckout(backend: backend, confirmer: confirmer),
            onPaid: paid.add,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('39.55'), findsWidgets);
    expect(confirmer.prepared.single['stripeAccountId'], '');
    await tester.tap(find.byKey(const Key('fake-card-complete')));
    await tester.pump();
    backend.serverStatus = 'succeeded';
    backend.fulfillment = 'fulfilled';
    await tester.tap(find.byKey(const Key('payment-checkout-pay')));
    await tester.pumpAndSettle();
    expect(paid, hasLength(1));
    expect(confirmer.confirmed, ['pi_1_secret_1']);
  });
}

class _NoAccountBackend implements PaymentsBackend {
  _NoAccountBackend(this.inner);
  final FakePaymentsBackend inner;

  @override
  Future<Map<String, dynamic>> createOrder({required String kind, required String targetId, required String groupId}) async {
    final map = await inner.createOrder(kind: kind, targetId: targetId, groupId: groupId);
    return {...map, 'stripeAccountId': null};
  }

  @override
  Future<Map<String, dynamic>> confirmOrder(String orderId) => inner.confirmOrder(orderId);

  @override
  Future<Map<String, dynamic>> getOrder(String orderId) => inner.getOrder(orderId);
}
