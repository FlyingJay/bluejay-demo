import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contrast', () {
    test('black on white is 21:1', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    });

    test('every curated swatch is an accessible accent', () {
      for (final s in BjSwatches.all) {
        expect(isAccessibleAccent(s.color), isTrue,
            reason: '${s.name} is ${accentContrast(s.color).toStringAsFixed(2)}:1');
      }
    });

    test('swatch names are unique', () {
      final names = BjSwatches.all.map((s) => s.name).toSet();
      expect(names.length, BjSwatches.all.length);
    });

    test('rejects light yellows, greys and pastels', () {
      for (final c in const [
        Color(0xFFFDE047), // light yellow
        Color(0xFFD1D5DB), // light grey
        Color(0xFFF9A8D4), // pastel pink
        Color(0xFF93C5FD), // pastel blue
        Color(0xFFFFFFFF),
      ]) {
        expect(isAccessibleAccent(c), isFalse, reason: BjAccent.toHex(c));
      }
    });

    test('neutral text colors are readable on surface and canvas', () {
      for (final ink in const [BjNeutral.ink, BjNeutral.inkMuted, BjNeutral.inkSubtle]) {
        expect(contrastRatio(ink, BjNeutral.surface), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(ink, BjNeutral.canvas), greaterThanOrEqualTo(4.5));
      }
    });
  });

  group('nearestAccessibleShade', () {
    test('leaves accessible colors alone', () {
      final c = BjSwatches.teal.color;
      expect(nearestAccessibleShade(c), c);
    });

    test('darkens light colors just enough, keeping the hue', () {
      const yellow = Color(0xFFFDE047);
      final fixed = nearestAccessibleShade(yellow);
      expect(isAccessibleAccent(fixed), isTrue);
      expect(accentContrast(fixed), lessThan(kMinAccentContrast + 0.3));
      expect(HSLColor.fromColor(fixed).hue,
          closeTo(HSLColor.fromColor(yellow).hue, 1.5));
    });
  });

  group('BjAccent', () {
    test('forces stored colors accessible and derives a secondary', () {
      final a = BjAccent(primary: const Color(0xFFD1D5DB));
      expect(isAccessibleAccent(a.primary), isTrue);
      expect(isAccessibleAccent(a.secondary), isTrue);
      expect(a.secondary, isNot(a.primary));
    });

    test('hex round trip', () {
      expect(BjAccent.toHex(const Color(0xFF4F46E5)), '#4F46E5');
      expect(BjAccent.parseHex('#4f46e5'), const Color(0xFF4F46E5));
      expect(BjAccent.parseHex('4F46E5'), const Color(0xFF4F46E5));
      expect(BjAccent.parseHex('nope'), isNull);
      expect(BjAccent.parseHex(null), isNull);
    });

    test('fromHex falls back to the standard accent', () {
      expect(BjAccent.fromHex(null), BjAccent.standard);
      expect(BjAccent.fromHex('#zzzzzz'), BjAccent.standard);
      expect(BjAccent.fromHex('#0F766E').primary, const Color(0xFF0F766E));
    });
  });
}
