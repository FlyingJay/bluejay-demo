import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BjCategorical', () {
    test('every hue reads at 4.5:1 on its own tint, unadjusted', () {
      for (final c in BjCategorical.all) {
        expect(contrastRatio(c, bjTint(c)), greaterThanOrEqualTo(4.5),
            reason: '#${c.toARGB32().toRadixString(16)} on its tint');
        expect(readableOn(c, bjTint(c)), c,
            reason: 'should need no darkening');
        expect(bjToneOf(c).foreground, c);
      }
    });

    test('eight distinct hues', () {
      expect(BjCategorical.all, hasLength(8));
      expect(BjCategorical.all.toSet(), hasLength(8));
    });

    test('at wraps and forKey is stable', () {
      expect(BjCategorical.at(8), BjCategorical.at(0));
      expect(BjCategorical.forKey('invoices'), BjCategorical.forKey('invoices'));
      final spread = {
        for (final k in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'])
          BjCategorical.forKey(k)
      };
      expect(spread.length, greaterThan(3));
    });
  });

  test('readableOn reaches AA for light user colors', () {
    for (final c in [
      const Color(0xFFFFC107),
      const Color(0xFF9CCC65),
      const Color(0xFFFDE047),
      BjSwatches.teal.color,
    ]) {
      final bg = bjTint(c);
      expect(contrastRatio(readableOn(c, bg), bg), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('BjStatusPill labels a custom color readably', (t) async {
    const amber = Color(0xFFFFC107);
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: const Scaffold(body: BjStatusPill(label: 'urgent', color: amber)),
    ));
    final text = t.widget<Text>(find.text('urgent'));
    expect(contrastRatio(text.style!.color!, bjTint(amber)),
        greaterThanOrEqualTo(4.5));
  });

  test('white text reads on the brand navies', () {
    for (final c in const [BjBrand.navy, BjBrand.navyDeep]) {
      expect(contrastRatio(Colors.white, c), greaterThanOrEqualTo(4.5));
    }
  });
}
