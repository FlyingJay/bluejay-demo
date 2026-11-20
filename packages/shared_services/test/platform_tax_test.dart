import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/platform_tax.dart';

void main() {
  const on = {'enabled': true, 'rateBps': 1300, 'label': 'HST (Ontario)', 'registrationNumber': '123456789 RT0001'};

  group('PlatformTax.fromData', () {
    test('off unless enabled with a registration number', () {
      for (final data in [
        null,
        'yes',
        <String, Object?>{},
        {'enabled': false, 'registrationNumber': 'RT1'},
        {'enabled': true},
        {'enabled': true, 'registrationNumber': '  '},
        {'enabled': 'true', 'registrationNumber': 'RT1'},
      ]) {
        expect(PlatformTax.fromData(data), PlatformTax.off, reason: '$data');
      }
    });

    test('on with the rate, label and number', () {
      final tax = PlatformTax.fromData(on);
      expect(tax.enabled, isTrue);
      expect(tax.rateBps, 1300);
      expect(tax.label, 'HST (Ontario)');
      expect(tax.registrationNumber, '123456789 RT0001');
    });
  });

  group('wording', () {
    test('while tax is off, every phrase is empty or plain', () {
      const tax = PlatformTax.off;
      expect('CA\$49.99/month${tax.plusShort}', r'CA$49.99/month');
      expect('I agree to pay CA\$49.99${tax.plus} for this group', r'I agree to pay CA$49.99 for this group');
      expect('Up to 5 people${tax.commaPlus}', 'Up to 5 people');
      expect('billed on the 1st${tax.plusAside} to your card', 'billed on the 1st to your card');
      expect('Per group${tax.before}', 'Per group');
      expect('Paid invoices${tax.commaBefore}', 'Paid invoices');
      expect(tax.plusTaxThen('billed monthly to your card.'), 'Billed monthly to your card.');
    });

    test('while tax is on, each phrase names it', () {
      final tax = PlatformTax.fromData(on);
      expect('CA\$49.99/month${tax.plusShort}', r'CA$49.99/month + tax');
      expect('I agree to pay CA\$49.99${tax.plus} for this group', r'I agree to pay CA$49.99 plus tax for this group');
      expect('Up to 5 people${tax.commaPlus}', 'Up to 5 people, plus tax');
      expect('billed on the 1st${tax.plusAside} to your card', 'billed on the 1st, plus tax, to your card');
      expect('Per group${tax.before}', 'Per group before tax');
      expect('Paid invoices${tax.commaBefore}', 'Paid invoices, before tax');
      expect(tax.plusTaxThen('billed monthly to your card.'), 'Plus tax, billed monthly to your card.');
    });

    test('an invoice uses the tax it was issued with', () {
      expect('Per group${const PlatformTax.applied(true).before}', 'Per group before tax');
      expect('Per group${const PlatformTax.applied(false).before}', 'Per group');
      expect(PlatformTax.registrationLine('RT1'), "Bluejay's tax registration number: RT1");
    });
  });
}
