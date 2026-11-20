import 'package:flutter/material.dart';

import 'accent.dart';
import 'theme.dart';
import 'tokens.dart';

/// The colors a game draws its play screen in. Only [background] is
/// required: the rest are derived so text, icons and controls stay readable
/// on it, dark or light.
@immutable
class BjGamePalette {
  const BjGamePalette({
    required this.background,
    this.surface,
    this.foreground,
    this.accent,
  });

  /// The play screen's canvas (scaffold and app bar).
  final Color background;

  /// Cards, dialogs, sheets and menus drawn over [background]. Defaults to
  /// [background] nudged toward [foreground].
  final Color? surface;

  /// Text and icons. Defaults to white on a dark [background] and
  /// [BjNeutral.ink] on a light one.
  final Color? foreground;

  /// Filled buttons, progress and selection. Defaults to the group accent.
  final Color? accent;

  Brightness get brightness =>
      ThemeData.estimateBrightnessForColor(background);

  bool get isDark => brightness == Brightness.dark;

  Color get resolvedForeground =>
      foreground ?? (isDark ? Colors.white : BjNeutral.ink);

  /// [surface], or [background] nudged toward [resolvedForeground]; when
  /// that would cost the foreground its 4.5:1 (a mid-tone felt), nudged
  /// darker instead.
  Color get resolvedSurface {
    if (surface != null) return surface!;
    final fg = resolvedForeground;
    final lifted = Color.lerp(background, fg, 0.07)!;
    if (contrastRatio(fg, lifted) >= kMinAccentContrast) return lifted;
    return Color.lerp(background, const Color(0xFF000000), 0.18)!;
  }

  /// Secondary text: [resolvedForeground] faded into [background], kept at
  /// 4.5:1 or better.
  Color get mutedForeground {
    final fg = resolvedForeground;
    for (var t = 0.32; t >= 0; t -= 0.04) {
      final c = Color.lerp(fg, background, t)!;
      if (contrastRatio(c, background) >= kMinAccentContrast &&
          contrastRatio(c, resolvedSurface) >= kMinAccentContrast) {
        return c;
      }
    }
    return fg;
  }
}

/// Builds the theme for a game's play screen from the app theme.
///
/// Lobbies, menus, leaderboards and settings use the app theme and the Bj
/// components like every other app. The play screen has its own look (a
/// dark chess room, a felt table, a neon arcade), so it runs under this
/// theme instead: same fonts, shapes and motion as the app theme, with
/// every color re-derived from [BjGamePalette] so nothing that assumes the
/// bright canvas (ink text, white cards, pale tints) lands on the game's
/// background.
ThemeData bjGameThemeData(ThemeData base, BjGamePalette palette) {
  final dark = palette.isDark;
  final bg = palette.background;
  final fg = palette.resolvedForeground;
  final muted = palette.mutedForeground;
  final surface = palette.resolvedSurface;
  final accent = palette.accent ?? base.colorScheme.primary;
  final onAccent = ThemeData.estimateBrightnessForColor(accent) ==
          Brightness.dark
      ? Colors.white
      : BjNeutral.ink;
  // Accent used as text or an outline on the background (text buttons,
  // focused borders): lightened on dark backgrounds until it reads.
  final accentText = _readableAccent(accent, bg, dark);
  final border = fg.withValues(alpha: dark ? 0.16 : 0.14);
  final borderStrong = fg.withValues(alpha: dark ? 0.32 : 0.28);

  final scheme = base.colorScheme.copyWith(
    brightness: palette.brightness,
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: Color.lerp(surface, accent, 0.24),
    onPrimaryContainer: fg,
    secondaryContainer: Color.lerp(surface, accent, 0.16),
    onSecondaryContainer: fg,
    surface: surface,
    onSurface: fg,
    onSurfaceVariant: muted,
    surfaceContainerLowest: Color.lerp(bg, surface, 0.5),
    surfaceContainerLow: surface,
    surfaceContainer: Color.lerp(surface, fg, 0.04),
    surfaceContainerHigh: Color.lerp(surface, fg, 0.08),
    surfaceContainerHighest: Color.lerp(surface, fg, 0.12),
    outline: borderStrong,
    outlineVariant: border,
    inverseSurface: fg,
    onInverseSurface: bg,
  );

  final text = base.textTheme.apply(bodyColor: fg, displayColor: fg).copyWith(
        bodySmall: base.textTheme.bodySmall?.copyWith(color: muted),
      );
  final radiusMd = BjRadius.all(BjRadius.md);

  final bj = _gameBjTheme(base, palette, accent, accentText, border, borderStrong);

  return base.copyWith(
    brightness: palette.brightness,
    extensions: [bj],
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    iconTheme: IconThemeData(color: fg),
    primaryIconTheme: IconThemeData(color: fg),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: bg,
      foregroundColor: fg,
    ),
    cardTheme: base.cardTheme.copyWith(
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: BjRadius.all(BjRadius.lg),
        side: BorderSide(color: border),
      ),
    ),
    dividerTheme: base.dividerTheme.copyWith(color: border),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: surface,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: muted),
    ),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      dragHandleColor: borderStrong,
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: surface,
      textStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: radiusMd,
        side: BorderSide(color: border),
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      textColor: fg,
      iconColor: muted,
      titleTextStyle: text.titleSmall,
      subtitleTextStyle: text.bodySmall,
      selectedColor: accentText,
      selectedTileColor: scheme.primaryContainer,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? border : accent),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? muted : onAccent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        foregroundColor: WidgetStatePropertyAll(fg),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: borderStrong)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        foregroundColor: WidgetStatePropertyAll(accentText),
      ),
    ),
    floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
      backgroundColor: accent,
      foregroundColor: onAccent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? border : accent),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? muted : onAccent),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: fg),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: surface,
      hintStyle: text.bodyMedium?.copyWith(color: muted),
      labelStyle: text.bodyMedium?.copyWith(color: muted),
      floatingLabelStyle: text.bodyMedium?.copyWith(color: accentText),
      border: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: accentText, width: 1.6),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: surface,
      selectedColor: scheme.primaryContainer,
      checkmarkColor: fg,
      side: BorderSide(color: border),
      shape: StadiumBorder(side: BorderSide(color: border)),
      labelStyle: text.labelMedium?.copyWith(color: fg),
      secondaryLabelStyle: text.labelMedium?.copyWith(color: fg),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: surface,
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: fg,
        foregroundColor: muted,
        side: BorderSide(color: border),
        textStyle: text.labelMedium,
      ),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelColor: accentText,
      unselectedLabelColor: muted,
      dividerColor: border,
      indicator: UnderlineTabIndicator(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
        borderSide: BorderSide(color: accentText, width: 3),
      ),
    ),
    progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
      color: accentText,
      linearTrackColor: border,
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      side: BorderSide(color: borderStrong, width: 1.6),
    ),
    switchTheme: base.switchTheme.copyWith(
      trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? Colors.transparent : borderStrong),
    ),
    // The app's ink snack bar disappears into a near-black arena; on dark
    // palettes it's a raised surface instead.
    snackBarTheme: dark
        ? base.snackBarTheme.copyWith(
            backgroundColor: Color.lerp(surface, fg, 0.16),
            contentTextStyle: text.bodyMedium?.copyWith(color: fg),
            actionTextColor: accentText,
          )
        : base.snackBarTheme,
    tooltipTheme: base.tooltipTheme.copyWith(
      decoration: BoxDecoration(
        color: fg,
        borderRadius: BjRadius.all(BjRadius.sm),
      ),
      textStyle: text.labelSmall?.copyWith(color: bg),
    ),
  );
}

/// The [BjTheme] extension for a play screen: accent tints mixed into the
/// game surface instead of white, the game's neutrals, and status tones
/// redrawn on tints of the game surface. Components
/// read these through `context.bj`, so a BjCard or BjStatusPill inside the
/// game matches it.
BjTheme _gameBjTheme(ThemeData base, BjGamePalette palette, Color accent,
    Color accentText, Color border, Color borderStrong) {
  final baseBj = base.extension<BjTheme>() ??
      BjTheme.fromAccent(BjAccent.standard);
  final surface = palette.resolvedSurface;
  final fg = palette.resolvedForeground;
  final dark = palette.isDark;
  final secondary = palette.accent == null ? baseBj.secondary : accent;
  final accentSoft = Color.lerp(surface, accent, dark ? 0.24 : 0.12)!;
  final tones = {
    for (final t in BjTone.values)
      t: _gameTone(
        BjTheme.defaultTone(t, accent: accentText, accentSoft: accentSoft),
        surface,
        dark,
      ),
  };
  return baseBj.copyWith(
    accent: accent,
    accentSoft: accentSoft,
    accentWash: Color.lerp(surface, accent, dark ? 0.12 : 0.05),
    secondary: secondary,
    secondarySoft: Color.lerp(surface, secondary, dark ? 0.24 : 0.12),
    surface: surface,
    surfaceMuted: Color.lerp(surface, fg, 0.06),
    border: border,
    borderStrong: borderStrong,
    ink: fg,
    inkMuted: palette.mutedForeground,
    inkSubtle: palette.mutedForeground,
    tones: tones,
  );
}

/// A light-canvas tone redrawn on [surface]: a tint of the hue mixed into
/// the surface, with the hue lightened (dark surface) or darkened (light
/// surface) until it reads on that tint.
BjToneColors _gameTone(BjToneColors light, Color surface, bool dark) {
  final step = dark ? 0.03 : -0.03;
  late Color background;
  late Color foreground;
  // A lighter hue makes a lighter tint, so on a mid-tone surface back the
  // tint off until the hue can reach 4.5:1 on it.
  for (final mix in dark ? const [0.22, 0.16, 0.10, 0.05, 0.0] : const [0.10, 0.05, 0.0]) {
    background = Color.lerp(surface, light.foreground, mix)!;
    var hsl = HSLColor.fromColor(light.foreground);
    for (var i = 0;
        i < 40 && contrastRatio(hsl.toColor(), background) < kMinAccentContrast;
        i++) {
      hsl = hsl.withLightness((hsl.lightness + step).clamp(0.0, 1.0));
    }
    foreground = hsl.toColor();
    if (contrastRatio(foreground, background) >= kMinAccentContrast) break;
  }
  return BjToneColors(
      foreground, background, Color.lerp(background, foreground, 0.35)!);
}

Color _readableAccent(Color accent, Color background, bool dark) {
  if (contrastRatio(accent, background) >= kMinAccentContrast) return accent;
  var hsl = HSLColor.fromColor(accent.withValues(alpha: 1));
  final step = dark ? 0.03 : -0.03;
  for (var i = 0; i < 40; i++) {
    hsl = hsl.withLightness((hsl.lightness + step).clamp(0.0, 1.0));
    if (contrastRatio(hsl.toColor(), background) >= kMinAccentContrast) break;
  }
  return hsl.toColor();
}

/// Runs a game's play screen under [bjGameThemeData] for [palette].
///
/// Wrap the play screen (the board, table or arcade) in this, and leave
/// lobbies, menus and leaderboards on the app theme with [BjPage]. Dialogs
/// and sheets opened from inside inherit the game theme, so a "Resign?"
/// confirm over a dark board is dark too.
///
/// ```dart
/// BjGameTheme(
///   palette: const BjGamePalette(background: ChessColors.room),
///   child: Scaffold(appBar: AppBar(title: Text('Chess')), body: board),
/// )
/// ```
class BjGameTheme extends StatelessWidget {
  const BjGameTheme({super.key, required this.palette, required this.child});

  final BjGamePalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = bjGameThemeData(Theme.of(context), palette);
    return Theme(
      data: data,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: palette.resolvedForeground),
        child: IconTheme.merge(
          data: IconThemeData(color: palette.resolvedForeground),
          child: child,
        ),
      ),
    );
  }
}
