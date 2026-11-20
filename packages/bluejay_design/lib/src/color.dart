import 'package:flutter/painting.dart';

import 'accent.dart';
import 'theme.dart' show BjToneColors;
import 'tokens.dart';

/// The soft tint a custom color sits on: [color] mixed 86% toward white.
/// Pills, tag chips and icon wells use it as the background behind a
/// user-picked or categorical color.
Color bjTint(Color color) =>
    Color.lerp(color.withValues(alpha: 1), BjNeutral.surface, 0.86)!;

/// [color] darkened, keeping its hue, until it reads at 4.5:1 (WCAG AA) on
/// [background]. Returns [color] unchanged when it already does. Use it to
/// label a user-picked color on its own [bjTint].
Color readableOn(Color color, Color background) {
  var hsl = HSLColor.fromColor(color.withValues(alpha: 1));
  while (hsl.lightness > 0 &&
      contrastRatio(hsl.toColor(), background) < kMinAccentContrast) {
    hsl = hsl.withLightness((hsl.lightness - 0.02).clamp(0.0, 1.0));
  }
  return hsl.toColor();
}

/// Foreground, background and border for a custom color, laid out like a
/// [BjToneColors] so it drops in wherever a tone does.
BjToneColors bjToneOf(Color color) {
  final bg = bjTint(color);
  return BjToneColors(
    readableOn(color, bg),
    bg,
    Color.lerp(color.withValues(alpha: 1), BjNeutral.surface, 0.6)!,
  );
}

/// Eight distinct hues for things that need telling apart but carry no
/// status meaning: file types, categories, chart series, avatars. Use
/// [BjTone] when a color means good, bad or needs attention.
///
/// Every hue is dark enough to read as text on its own [bjTint], so
/// `BjStatusPill(color: BjCategorical.violet)` and
/// `BjIconWell(color: BjCategorical.teal)` need no adjustment.
abstract final class BjCategorical {
  static const Color violet = Color(0xFF7C3AED);
  static const Color teal = Color(0xFF0E7068);
  static const Color amber = Color(0xFF92400E);
  static const Color blue = Color(0xFF1D4ED8);
  static const Color rose = Color(0xFFBE123C);
  static const Color green = Color(0xFF157034);
  static const Color fuchsia = Color(0xFFA21CAF);
  static const Color orange = Color(0xFFAD3A0A);

  /// In an order where neighbours contrast, for assigning by index.
  static const List<Color> all = [
    violet,
    teal,
    amber,
    blue,
    rose,
    green,
    fuchsia,
    orange,
  ];

  /// The [index]th hue, wrapping around after eight.
  static Color at(int index) => all[index % all.length];

  /// A stable hue for [key] (a category name, a user id), the same on every
  /// device and run.
  static Color forKey(String key) {
    // FNV-1a: String.hashCode isn't stable across platforms.
    var h = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return at(h);
  }
}
