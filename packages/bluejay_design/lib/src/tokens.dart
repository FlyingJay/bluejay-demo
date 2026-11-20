import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// Spacing scale on a 4-pt grid. Use these instead of literal paddings so
/// every screen shares one rhythm.
abstract final class BjSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii. Cards use [lg], inputs [md], chips and buttons [pill],
/// dialogs and sheets [xl].
abstract final class BjRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static BorderRadius all(double r) => BorderRadius.all(Radius.circular(r));
}

/// Motion durations and curves. Short and eased-out so the UI feels quick
/// but never snaps.
abstract final class BjMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOutCubic;
}

/// Width breakpoints and content max widths.
abstract final class BjBreakpoint {
  /// Below this is a phone layout.
  static const double medium = 600;

  /// At or above this, master/detail and multi-column layouts kick in.
  static const double expanded = 900;

  /// Max content width for forms and reading.
  static const double formWidth = 720;

  /// Max content width for lists and dashboards.
  static const double pageWidth = 1100;

  static bool isCompact(double width) => width < medium;
  static bool isExpanded(double width) => width >= expanded;
}

/// Neutral palette shared by every accent: bright canvas, white surfaces,
/// slate ink. Text colors all clear 4.5:1 on [surface] and [canvas].
abstract final class BjNeutral {
  static const Color canvas = Color(0xFFF7F8FC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceMuted = Color(0xFFF1F3F9);
  static const Color border = Color(0xFFE6E8F0);
  static const Color borderStrong = Color(0xFFCDD2DE);
  static const Color ink = Color(0xFF172033);
  static const Color inkMuted = Color(0xFF475569);
  static const Color inkSubtle = Color(0xFF5F6B7D);
  static const Color shadow = Color(0xFF172033);
}

/// The brand colors from the Bluejay logo. The logo, link previews,
/// document covers and other dark brand surfaces use them; app screens use
/// the accent instead. White text reads on both.
abstract final class BjBrand {
  /// The bird in the logo.
  static const Color navy = Color(0xFF0F3048);

  /// A deeper navy for gradients that start from [navy].
  static const Color navyDeep = Color(0xFF08182A);
}

/// Font families, bundled in the launcher's pubspec. Both are cuts of
/// Bricolage Grotesque at a semi-condensed width, so labels and rows fit
/// more text across a phone: [heading] is the display optical size,
/// [body] the text size for body copy and labels.
abstract final class BjFont {
  static const String heading = 'BricolageDisplay';
  static const String body = 'BricolageText';

  /// The font files behind each family, relative to the launcher's
  /// `assets/fonts/`. `loadBjFonts` (package:bluejay_design/testing.dart)
  /// reads this, so a font change is one edit here plus the pubspec.
  static const Map<String, List<String>> files = {
    heading: [
      'BricolageDisplay-500.ttf',
      'BricolageDisplay-700.ttf',
      'BricolageDisplay-800.ttf',
    ],
    body: [
      'BricolageText-400.ttf',
      'BricolageText-500.ttf',
      'BricolageText-600.ttf',
      'BricolageText-700.ttf',
    ],
  };
}
