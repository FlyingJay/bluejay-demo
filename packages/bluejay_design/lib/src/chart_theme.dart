import 'package:flutter/material.dart';

import 'color.dart';
import 'tokens.dart';

/// A complete look for charts and dashboards: series palette, surfaces,
/// ink and text styles. Dashboards specs pick one by name (`clean`,
/// `playful`, ...); chart widgets take every colour, radius and text style
/// from here, so a chart can't be styled freely and stays readable in light
/// and dark mode.
class BjChartTheme {
  const BjChartTheme({
    required this.id,
    required this.label,
    required this.palette,
    required this.positive,
    required this.negative,
    required this.neutral,
    required this.canvas,
    required this.card,
    required this.ink,
    required this.inkMuted,
    required this.gridLine,
    required this.radius,
    required this.cardBorder,
    required this.emojiAccents,
    required this.brightness,
    this.cardGradient,
  });

  final String id;
  final String label;

  /// Series colours `c1`..`c8`.
  final List<Color> palette;
  final Color positive;
  final Color negative;
  final Color neutral;
  final Color canvas;
  final Color card;
  final Color ink;
  final Color inkMuted;
  final Color gridLine;
  final double radius;
  final Color? cardBorder;
  final List<Color>? cardGradient;

  /// Whether tiles may decorate titles and empty states with emoji (the
  /// playful look).
  final bool emojiAccents;
  final Brightness brightness;

  Color series(int i) => palette[i % palette.length];

  /// A spec `colors` value (`c1`-`c8`, `positive`, `negative`, `neutral`).
  Color? named(String slot) {
    switch (slot) {
      case 'positive':
        return positive;
      case 'negative':
        return negative;
      case 'neutral':
        return neutral;
    }
    final m = RegExp(r'^c([1-8])$').firstMatch(slot);
    return m == null ? null : palette[int.parse(m.group(1)!) - 1];
  }

  /// Colour for category value [key] at position [index], honouring a spec's
  /// `colors` map.
  Color forCategory(Object? key, int index, Map<String, String> fixed) {
    final slot = fixed[key?.toString()];
    return (slot == null ? null : named(slot)) ?? series(index);
  }

  /// A sequential ramp from the card colour to the first series colour, for
  /// heatmaps; [t] is 0-1.
  Color ramp(double t) =>
      Color.lerp(card == Colors.white ? palette.first.withValues(alpha: 0.08) : gridLine, palette.first, t.clamp(0, 1))!;

  TextStyle get titleStyle => TextStyle(
        fontFamily: BjFont.heading,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: ink,
      );

  TextStyle get bigNumberStyle => TextStyle(
        fontFamily: BjFont.heading,
        fontSize: 34,
        fontWeight: FontWeight.w800,
        color: ink,
        height: 1.05,
      );

  TextStyle get labelStyle => TextStyle(fontSize: 12, color: inkMuted);

  /// Text drawn on a coloured mark (a slice, bar, treemap cell, avatar).
  TextStyle get onMarkStyle => const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white);

  /// An emoji or glyph at [size], sitting tight on its line.
  TextStyle glyph(double size) => TextStyle(fontSize: size, height: 1);

  /// Axis ticks that take no room (radar charts, whose rings label nothing).
  TextStyle get hiddenTickStyle => const TextStyle(color: Colors.transparent, fontSize: 1);

  /// Chart tooltip text and background, inverted against the card.
  TextStyle get tooltipStyle => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: brightness == Brightness.dark ? const Color(0xFF0B1220) : Colors.white,
      );

  Color get tooltipBackground => brightness == Brightness.dark ? const Color(0xFFE5E9F2) : const Color(0xE6202634);
  TextStyle get bodyStyle => TextStyle(fontSize: 13, color: ink);

  static const List<String> ids = ['clean', 'playful', 'bold', 'calm', 'midnight', 'sunrise'];

  static BjChartTheme byId(String id) => switch (id) {
        'playful' => playful,
        'bold' => bold,
        'calm' => calm,
        'midnight' => midnight,
        'sunrise' => sunrise,
        _ => clean,
      };

  static final clean = BjChartTheme(
    id: 'clean',
    label: 'Clean',
    palette: BjCategorical.all,
    positive: const Color(0xFF157034),
    negative: const Color(0xFFBE123C),
    neutral: BjNeutral.inkSubtle,
    canvas: BjNeutral.canvas,
    card: BjNeutral.surface,
    ink: BjNeutral.ink,
    inkMuted: BjNeutral.inkMuted,
    gridLine: BjNeutral.border,
    radius: BjRadius.md,
    cardBorder: BjNeutral.border,
    emojiAccents: false,
    brightness: Brightness.light,
  );

  static const playful = BjChartTheme(
    id: 'playful',
    label: 'Playful',
    palette: [
      Color(0xFFE8508A), Color(0xFF7C5CFA), Color(0xFF14A38B), Color(0xFFF59E0B),
      Color(0xFF3B82F6), Color(0xFFEF6C3E), Color(0xFF9B51E0), Color(0xFF10B981),
    ],
    positive: Color(0xFF10B981),
    negative: Color(0xFFE8508A),
    neutral: Color(0xFF8B7FA8),
    canvas: Color(0xFFFFF5FA),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF3A2350),
    inkMuted: Color(0xFF6E5A84),
    gridLine: Color(0xFFF3DDEA),
    radius: BjRadius.xl,
    cardBorder: Color(0xFFF7D6E6),
    emojiAccents: true,
    brightness: Brightness.light,
  );

  static const bold = BjChartTheme(
    id: 'bold',
    label: 'Bold',
    palette: [
      Color(0xFF1D4ED8), Color(0xFFDC2626), Color(0xFFF59E0B), Color(0xFF059669),
      Color(0xFF7C3AED), Color(0xFF0891B2), Color(0xFFDB2777), Color(0xFF65A30D),
    ],
    positive: Color(0xFF059669),
    negative: Color(0xFFDC2626),
    neutral: Color(0xFF64748B),
    canvas: Color(0xFFF1F5F9),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF0F172A),
    inkMuted: Color(0xFF475569),
    gridLine: Color(0xFFE2E8F0),
    radius: BjRadius.sm,
    cardBorder: Color(0xFF0F172A),
    emojiAccents: false,
    brightness: Brightness.light,
  );

  static const calm = BjChartTheme(
    id: 'calm',
    label: 'Calm',
    palette: [
      Color(0xFF4F7C82), Color(0xFF8AA899), Color(0xFFB08968), Color(0xFF7D8CC4),
      Color(0xFFC9A66B), Color(0xFF6B9080), Color(0xFFA27B9C), Color(0xFF5C7AEA),
    ],
    positive: Color(0xFF4F8A5B),
    negative: Color(0xFFB5544A),
    neutral: Color(0xFF7A869A),
    canvas: Color(0xFFF4F6F3),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF26323B),
    inkMuted: Color(0xFF5B6770),
    gridLine: Color(0xFFE3E8E2),
    radius: BjRadius.lg,
    cardBorder: null,
    emojiAccents: false,
    brightness: Brightness.light,
  );

  static const midnight = BjChartTheme(
    id: 'midnight',
    label: 'Midnight',
    palette: [
      Color(0xFF60A5FA), Color(0xFFF472B6), Color(0xFF34D399), Color(0xFFFBBF24),
      Color(0xFFA78BFA), Color(0xFF22D3EE), Color(0xFFFB923C), Color(0xFFA3E635),
    ],
    positive: Color(0xFF34D399),
    negative: Color(0xFFF87171),
    neutral: Color(0xFF94A3B8),
    canvas: Color(0xFF0B1220),
    card: Color(0xFF141C2F),
    ink: Color(0xFFE5E9F2),
    inkMuted: Color(0xFFA0AABF),
    gridLine: Color(0xFF243049),
    radius: BjRadius.md,
    cardBorder: Color(0xFF243049),
    emojiAccents: false,
    brightness: Brightness.dark,
  );

  static const sunrise = BjChartTheme(
    id: 'sunrise',
    label: 'Sunrise',
    palette: [
      Color(0xFFEA580C), Color(0xFFDB2777), Color(0xFF7C3AED), Color(0xFFCA8A04),
      Color(0xFF0D9488), Color(0xFFE11D48), Color(0xFF2563EB), Color(0xFF65A30D),
    ],
    positive: Color(0xFF0D9488),
    negative: Color(0xFFE11D48),
    neutral: Color(0xFF8A7560),
    canvas: Color(0xFFFFF7ED),
    card: Color(0xFFFFFFFF),
    ink: Color(0xFF3B2416),
    inkMuted: Color(0xFF7A5A44),
    gridLine: Color(0xFFF5E1CC),
    radius: BjRadius.lg,
    cardBorder: null,
    cardGradient: [Color(0xFFFFFFFF), Color(0xFFFFF1E2)],
    emojiAccents: true,
    brightness: Brightness.light,
  );
}
