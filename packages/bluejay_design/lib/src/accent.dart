import 'package:flutter/painting.dart';

import 'tokens.dart';

/// WCAG contrast ratio between two opaque colors, from 1 (identical) to 21
/// (black on white).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// The minimum contrast an accent must reach: WCAG AA for normal text.
const double kMinAccentContrast = 4.5;

/// The lowest contrast [color] has against the light backgrounds it sits on
/// and against white text placed on it.
double accentContrast(Color color) {
  final opaque = color.withValues(alpha: 1);
  final onWhite = contrastRatio(opaque, BjNeutral.surface);
  final onCanvas = contrastRatio(opaque, BjNeutral.canvas);
  return onWhite < onCanvas ? onWhite : onCanvas;
}

/// Whether [color] works as an accent: readable as text and icons on white
/// and the canvas, and readable with white text on top of it. Rejects light
/// yellows, light greys and pastels.
bool isAccessibleAccent(Color color) =>
    accentContrast(color) >= kMinAccentContrast;

/// The closest accessible version of [color]: same hue and saturation,
/// darkened just enough to pass [isAccessibleAccent]. Returns [color]
/// unchanged when it already passes.
Color nearestAccessibleShade(Color color) {
  final opaque = color.withValues(alpha: 1);
  if (isAccessibleAccent(opaque)) return opaque;
  var hsl = HSLColor.fromColor(opaque);
  while (hsl.lightness > 0) {
    hsl = hsl.withLightness((hsl.lightness - 0.005).clamp(0.0, 1.0));
    final candidate = hsl.toColor();
    if (isAccessibleAccent(candidate)) return candidate;
  }
  return hsl.toColor();
}

/// A secondary accent derived from [primary]: the hue shifted a little so
/// gradients between the two read as one soft family, kept accessible.
Color deriveSecondary(Color primary) {
  final hsl = HSLColor.fromColor(primary.withValues(alpha: 1));
  final shifted = hsl.withHue((hsl.hue + 32) % 360);
  return nearestAccessibleShade(shifted.toColor());
}

/// A named, pre-checked accent color.
class BjSwatch {
  const BjSwatch(this.name, this.color);

  final String name;
  final Color color;
}

/// Curated accents offered first in the picker. Every entry passes
/// [isAccessibleAccent]; a unit test enforces it.
abstract final class BjSwatches {
  static const indigo = BjSwatch('Indigo', Color(0xFF4F46E5));
  static const violet = BjSwatch('Violet', Color(0xFF7C3AED));
  static const blue = BjSwatch('Blue', Color(0xFF2563EB));
  static const ocean = BjSwatch('Ocean', Color(0xFF0369A1));
  static const teal = BjSwatch('Teal', Color(0xFF0F766E));
  static const emerald = BjSwatch('Emerald', Color(0xFF047857));
  static const forest = BjSwatch('Forest', Color(0xFF3F6212));
  static const amber = BjSwatch('Amber', Color(0xFFB45309));
  static const rust = BjSwatch('Rust', Color(0xFFC2410C));
  static const crimson = BjSwatch('Crimson', Color(0xFFB91C1C));
  static const rose = BjSwatch('Rose', Color(0xFFBE185D));
  static const orchid = BjSwatch('Orchid', Color(0xFFA21CAF));
  static const slate = BjSwatch('Slate', Color(0xFF475569));

  static const List<BjSwatch> all = [
    indigo,
    violet,
    blue,
    ocean,
    teal,
    emerald,
    forest,
    amber,
    rust,
    crimson,
    rose,
    orchid,
    slate,
  ];
}

/// The accent pair a theme is built from. [secondary] defaults to a hue
/// shift of [primary]. Both are forced accessible, so a stored value that
/// predates validation still renders readably.
class BjAccent {
  BjAccent({required Color primary, Color? secondary})
      : primary = nearestAccessibleShade(primary),
        secondary = nearestAccessibleShade(
            secondary ?? deriveSecondary(nearestAccessibleShade(primary)));

  /// Bluejay's default accent.
  static final BjAccent standard = BjAccent(primary: BjSwatches.indigo.color);

  final Color primary;
  final Color secondary;

  /// Parses `#RRGGBB` / `RRGGBB` / `#AARRGGBB` hex strings, as stored on
  /// group docs. Returns null for anything else.
  static Color? parseHex(String? hex) {
    if (hex == null) return null;
    var s = hex.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : Color(v);
  }

  /// `#RRGGBB`, uppercase.
  static String toHex(Color color) {
    final v = color.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// Builds an accent from stored hex strings, falling back to [standard].
  static BjAccent fromHex(String? primaryHex, [String? secondaryHex]) {
    final p = parseHex(primaryHex);
    if (p == null) return standard;
    return BjAccent(primary: p, secondary: parseHex(secondaryHex));
  }

  @override
  bool operator ==(Object other) =>
      other is BjAccent &&
      other.primary == primary &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(primary, secondary);
}
