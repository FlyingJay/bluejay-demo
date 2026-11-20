import 'package:flutter/material.dart';

/// Predefined color palette for app icon backgrounds.
/// These are professional Material Design colors that pair well with
/// white or dark icon glyphs, providing great visual variety.
const List<Color> iconBackgroundPalette = [
  Color(0xFF1565C0), // design-ok: app icon palette (stored per app) — Blue 800
  Color(0xFF1976D2), // design-ok: app icon palette (stored per app) — Blue 700
  Color(0xFF2196F3), // design-ok: app icon palette (stored per app) — Blue 500
  Color(0xFF42A5F5), // design-ok: app icon palette (stored per app) — Blue 400
  Color(0xFF6AB7F5), // design-ok: app icon palette (stored per app) — Blue 300
  Color(0xFF0097A7), // design-ok: app icon palette (stored per app) — Cyan 700
  Color(0xFF00BCD4), // design-ok: app icon palette (stored per app) — Cyan 500
  Color(0xFF26C6DA), // design-ok: app icon palette (stored per app) — Cyan 400
  Color(0xFF00796B), // design-ok: app icon palette (stored per app) — Teal 700
  Color(0xFF009688), // design-ok: app icon palette (stored per app) — Teal 500
  Color(0xFF26A69A), // design-ok: app icon palette (stored per app) — Teal 400
  Color(0xFF2E7D32), // design-ok: app icon palette (stored per app) — Green 800
  Color(0xFF388E3C), // design-ok: app icon palette (stored per app) — Green 700
  Color(0xFF4CAF50), // design-ok: app icon palette (stored per app) — Green 500
  Color(0xFF66BB6A), // design-ok: app icon palette (stored per app) — Green 400
  Color(0xFF558B2F), // design-ok: app icon palette (stored per app) — Light Green 800
  Color(0xFF7CB342), // design-ok: app icon palette (stored per app) — Light Green 600
  Color(0xFF9CCC65), // design-ok: app icon palette (stored per app) — Light Green 400
  Color(0xFFF57F17), // design-ok: app icon palette (stored per app) — Yellow 900
  Color(0xFFFF8F00), // design-ok: app icon palette (stored per app) — Amber 800
  Color(0xFFFFA000), // design-ok: app icon palette (stored per app) — Amber 700
  Color(0xFFFFC107), // design-ok: app icon palette (stored per app) — Amber 500
  Color(0xFFE65100), // design-ok: app icon palette (stored per app) — Deep Orange 900
  Color(0xFFF4511E), // design-ok: app icon palette (stored per app) — Deep Orange 600
  Color(0xFFFF5722), // design-ok: app icon palette (stored per app) — Deep Orange 500
  Color(0xFFBF360C), // design-ok: app icon palette (stored per app) — Deep Orange 900 dark
  Color(0xFFD32F2F), // design-ok: app icon palette (stored per app) — Red 700
  Color(0xFFE53935), // design-ok: app icon palette (stored per app) — Red 600
  Color(0xFFF44336), // design-ok: app icon palette (stored per app) — Red 500
  Color(0xFFEF5350), // design-ok: app icon palette (stored per app) — Red 400
  Color(0xFFC62828), // design-ok: app icon palette (stored per app) — Red 900
  Color(0xFFAD1457), // design-ok: app icon palette (stored per app) — Pink 800
  Color(0xFFE91E63), // design-ok: app icon palette (stored per app) — Pink 500
  Color(0xFFF06292), // design-ok: app icon palette (stored per app) — Pink 300
  Color(0xFF6A1B9A), // design-ok: app icon palette (stored per app) — Purple 800
  Color(0xFF7B1FA2), // design-ok: app icon palette (stored per app) — Purple 700
  Color(0xFF9C27B0), // design-ok: app icon palette (stored per app) — Purple 500
  Color(0xFFAB47BC), // design-ok: app icon palette (stored per app) — Purple 400
  Color(0xFF4527A0), // design-ok: app icon palette (stored per app) — Deep Purple 800
  Color(0xFF512DA8), // design-ok: app icon palette (stored per app) — Deep Purple 700
  Color(0xFF673AB7), // design-ok: app icon palette (stored per app) — Deep Purple 500
  Color(0xFF7E57C2), // design-ok: app icon palette (stored per app) — Deep Purple 400
  Color(0xFF283593), // design-ok: app icon palette (stored per app) — Indigo 900
  Color(0xFF303F9F), // design-ok: app icon palette (stored per app) — Indigo 700
  Color(0xFF3F51B5), // design-ok: app icon palette (stored per app) — Indigo 500
  Color(0xFF5C6BC0), // design-ok: app icon palette (stored per app) — Indigo 400
  Color(0xFF37474F), // design-ok: app icon palette (stored per app) — Blue Grey 700
  Color(0xFF455A64), // design-ok: app icon palette (stored per app) — Blue Grey 600
  Color(0xFF546E7A), // design-ok: app icon palette (stored per app) — Blue Grey 500
  Color(0xFF607D8B), // design-ok: app icon palette (stored per app) — Blue Grey 400
  Color(0xFF424242), // design-ok: app icon palette (stored per app) — Grey 800
  Color(0xFF616161), // design-ok: app icon palette (stored per app) — Grey 700
  Color(0xFF757575), // design-ok: app icon palette (stored per app) — Grey 600
  Color(0xFFFFFFFF), // design-ok: app icon palette (stored per app) — White
];

/// Predefined icon glyph colors.
const List<Color> iconGlyphPalette = [
  Colors.white, // design-ok: app icon palette (stored per app)
  Color(0xFFF5F5F5), // design-ok: app icon palette (stored per app) — Grey 100
  Color(0xFFE3F2FD), // design-ok: app icon palette (stored per app) — Blue 50
  Color(0xFFE8F5E9), // design-ok: app icon palette (stored per app) — Green 50
  Color(0xFFFFF9C4), // design-ok: app icon palette (stored per app) — Yellow 100
  Color(0xFFFFEBEE), // design-ok: app icon palette (stored per app) — Red 50
  Color(0xFF212121), // design-ok: app icon palette (stored per app) — Grey 900 (near-black)
  Color(0xFF424242), // design-ok: app icon palette (stored per app) — Grey 800
  Color(0xFF1565C0), // design-ok: app icon palette (stored per app) — Blue 800
  Color(0xFF2E7D32), // design-ok: app icon palette (stored per app) — Green 800
  Color(0xFFD32F2F), // design-ok: app icon palette (stored per app) — Red 700
  Color(0xFF6A1B9A), // design-ok: app icon palette (stored per app) — Purple 800
];

/// Converts a hex color string (e.g. "#2196F3" or "2196F3") to a [Color].
/// Returns null if the string is null or invalid.
Color? colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final buffer = StringBuffer();
  final cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length == 6) {
    buffer.write('ff');
    buffer.write(cleaned);
  } else if (cleaned.length == 8) {
    buffer.write(cleaned);
  } else {
    return null;
  }
  final value = int.tryParse(buffer.toString(), radix: 16);
  return value != null ? Color(value) : null;
}

/// Converts a [Color] to a hex string in the format "#RRGGBB".
String colorToHex(Color color) {
  return '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

/// Returns true if [background] is considered "dark", meaning a light (white)
/// glyph color should be used for contrast.
bool isDarkColor(Color background) {
  final luminance = background.computeLuminance();
  return luminance < 0.35;
}
