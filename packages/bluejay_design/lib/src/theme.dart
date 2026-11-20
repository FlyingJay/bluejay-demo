import 'package:animations/animations.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'accent.dart';
import 'tokens.dart';

/// Semantic tones for pills, banners, stat tiles and state views.
enum BjTone { neutral, accent, info, success, warning, danger }

/// Foreground, soft background and border for one [BjTone].
@immutable
class BjToneColors {
  const BjToneColors(this.foreground, this.background, this.border);

  final Color foreground;
  final Color background;
  final Color border;
}

/// The design system's theme extension: accent-derived tints, gradients,
/// tones and shadows that [ColorScheme] has no slot for. Read it with
/// `context.bj`.
@immutable
class BjTheme extends ThemeExtension<BjTheme> {
  const BjTheme({
    required this.accent,
    required this.accentSoft,
    required this.accentWash,
    required this.secondary,
    required this.secondarySoft,
    this.surface = BjNeutral.surface,
    this.surfaceMuted = BjNeutral.surfaceMuted,
    this.border = BjNeutral.border,
    this.borderStrong = BjNeutral.borderStrong,
    this.ink = BjNeutral.ink,
    this.inkMuted = BjNeutral.inkMuted,
    this.inkSubtle = BjNeutral.inkSubtle,
    this.tones,
  });

  factory BjTheme.fromAccent(BjAccent accent) => BjTheme(
        accent: accent.primary,
        accentSoft: Color.lerp(accent.primary, Colors.white, 0.88)!,
        accentWash: Color.lerp(accent.primary, Colors.white, 0.95)!,
        secondary: accent.secondary,
        secondarySoft: Color.lerp(accent.secondary, Colors.white, 0.88)!,
      );

  /// The accent itself: buttons, links, selected states.
  final Color accent;

  /// A soft tint of the accent for selected rows, icon wells and pills.
  final Color accentSoft;

  /// The faintest accent tint, for page washes behind content.
  final Color accentWash;

  final Color secondary;
  final Color secondarySoft;

  /// The neutrals components draw with. They default to [BjNeutral]; a
  /// game play screen ([BjGameTheme]) swaps in ones derived from its
  /// palette, so components read `context.bj.ink` rather than the constant.
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color borderStrong;
  final Color ink;
  final Color inkMuted;
  final Color inkSubtle;

  /// Replacement colors for [tone]; null keeps the light-canvas defaults.
  final Map<BjTone, BjToneColors>? tones;

  /// Bold gradient for hero headers and primary highlights. White text on
  /// it is accessible at both ends.
  LinearGradient get heroGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accent, secondary],
      );

  /// Soft gradient for icon wells, empty states and highlighted cards.
  LinearGradient get softGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accentSoft, secondarySoft],
      );

  /// The page background: a faint accent wash fading into the canvas.
  LinearGradient get canvasGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, 0.45],
        colors: [accentWash, BjNeutral.canvas],
      );

  /// Resting shadow for raised surfaces.
  List<BoxShadow> get shadowSm => [
        BoxShadow(
          color: BjNeutral.shadow.withValues(alpha: 0.04),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: accent.withValues(alpha: 0.05),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  /// Hover / lifted shadow.
  List<BoxShadow> get shadowMd => [
        BoxShadow(
          color: BjNeutral.shadow.withValues(alpha: 0.06),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
        BoxShadow(
          color: accent.withValues(alpha: 0.12),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ];

  BjToneColors tone(BjTone tone) {
    final custom = tones?[tone];
    if (custom != null) return custom;
    return defaultTone(tone, accent: accent, accentSoft: accentSoft);
  }

  /// The light-canvas colors for [tone].
  static BjToneColors defaultTone(BjTone tone,
      {required Color accent, required Color accentSoft}) {
    switch (tone) {
      case BjTone.neutral:
        return const BjToneColors(
            BjNeutral.inkMuted, BjNeutral.surfaceMuted, BjNeutral.border);
      case BjTone.accent:
        return BjToneColors(
            accent, accentSoft, Color.lerp(accent, Colors.white, 0.7)!);
      case BjTone.info:
        return const BjToneColors(
            Color(0xFF1D4ED8), Color(0xFFEFF6FF), Color(0xFFBFDBFE));
      case BjTone.success:
        return const BjToneColors(
            Color(0xFF047857), Color(0xFFECFDF5), Color(0xFFA7F3D0));
      case BjTone.warning:
        return const BjToneColors(
            Color(0xFFB45309), Color(0xFFFFFBEB), Color(0xFFFDE68A));
      case BjTone.danger:
        return const BjToneColors(
            Color(0xFFB91C1C), Color(0xFFFEF2F2), Color(0xFFFECACA));
    }
  }

  @override
  BjTheme copyWith({
    Color? accent,
    Color? accentSoft,
    Color? accentWash,
    Color? secondary,
    Color? secondarySoft,
    Color? surface,
    Color? surfaceMuted,
    Color? border,
    Color? borderStrong,
    Color? ink,
    Color? inkMuted,
    Color? inkSubtle,
    Map<BjTone, BjToneColors>? tones,
  }) =>
      BjTheme(
        accent: accent ?? this.accent,
        accentSoft: accentSoft ?? this.accentSoft,
        accentWash: accentWash ?? this.accentWash,
        secondary: secondary ?? this.secondary,
        secondarySoft: secondarySoft ?? this.secondarySoft,
        surface: surface ?? this.surface,
        surfaceMuted: surfaceMuted ?? this.surfaceMuted,
        border: border ?? this.border,
        borderStrong: borderStrong ?? this.borderStrong,
        ink: ink ?? this.ink,
        inkMuted: inkMuted ?? this.inkMuted,
        inkSubtle: inkSubtle ?? this.inkSubtle,
        tones: tones ?? this.tones,
      );

  @override
  BjTheme lerp(BjTheme? other, double t) {
    if (other == null) return this;
    return BjTheme(
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      secondarySoft: Color.lerp(secondarySoft, other.secondarySoft, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      inkSubtle: Color.lerp(inkSubtle, other.inkSubtle, t)!,
      tones: t < 0.5 ? tones : other.tones,
    );
  }
}

extension BjContext on BuildContext {
  /// The design system's tokens for the current theme. Falls back to the
  /// default accent when the app isn't themed with [BluejayTheme].
  BjTheme get bj =>
      Theme.of(this).extension<BjTheme>() ??
      BjTheme.fromAccent(BjAccent.standard);
}

/// Builds the app-wide [ThemeData]. Apps don't call this; the launcher's
/// `MaterialApp` does, so every pushed route inherits it.
abstract final class BluejayTheme {
  static ThemeData build({BjAccent? accent}) {
    final a = accent ?? BjAccent.standard;
    final bj = BjTheme.fromAccent(a);

    final scheme = ColorScheme.fromSeed(
      seedColor: a.primary,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ).copyWith(
      primary: a.primary,
      onPrimary: Colors.white,
      primaryContainer: bj.accentSoft,
      onPrimaryContainer: Color.lerp(a.primary, BjNeutral.ink, 0.45),
      secondary: a.secondary,
      onSecondary: Colors.white,
      secondaryContainer: bj.secondarySoft,
      onSecondaryContainer: Color.lerp(a.secondary, BjNeutral.ink, 0.45),
      error: const Color(0xFFB91C1C),
      onError: Colors.white,
      errorContainer: const Color(0xFFFEF2F2),
      onErrorContainer: const Color(0xFF7F1D1D),
      surface: BjNeutral.surface,
      onSurface: BjNeutral.ink,
      onSurfaceVariant: BjNeutral.inkMuted,
      surfaceContainerLowest: BjNeutral.surface,
      surfaceContainerLow: BjNeutral.canvas,
      surfaceContainer: BjNeutral.surfaceMuted,
      surfaceContainerHigh: const Color(0xFFEBEEF5),
      surfaceContainerHighest: const Color(0xFFE4E8F1),
      surfaceTint: Colors.transparent,
      outline: BjNeutral.borderStrong,
      outlineVariant: BjNeutral.border,
      shadow: BjNeutral.shadow,
    );

    final text = _textTheme();
    const pill = StadiumBorder();
    final radiusMd = BjRadius.all(BjRadius.md);
    final radiusLg = BjRadius.all(BjRadius.lg);
    final radiusXl = BjRadius.all(BjRadius.xl);
    const buttonPadding =
        EdgeInsets.symmetric(horizontal: BjSpace.xl, vertical: BjSpace.md);
    const buttonSize = Size(64, 44);
    final buttonText = text.labelLarge;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: BjFont.body,
      textTheme: text,
      scaffoldBackgroundColor: BjNeutral.canvas,
      canvasColor: BjNeutral.canvas,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      extensions: [bj],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SharedAxisPageTransitionsBuilder(
              transitionType: SharedAxisTransitionType.horizontal),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: SharedAxisPageTransitionsBuilder(
              transitionType: SharedAxisTransitionType.horizontal),
          TargetPlatform.linux: SharedAxisPageTransitionsBuilder(
              transitionType: SharedAxisTransitionType.horizontal),
          TargetPlatform.fuchsia: SharedAxisPageTransitionsBuilder(
              transitionType: SharedAxisTransitionType.horizontal),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: BjNeutral.canvas.withValues(alpha: 0.92),
        foregroundColor: BjNeutral.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleSpacing: BjSpace.lg,
        // No titleTextStyle, iconTheme or actionsIconTheme: a colored one
        // here wins over AppBar(foregroundColor:), which left dark-on-dark
        // titles on apps with their own app bar color. AppBar falls back to
        // textTheme.titleLarge and 24px icons in foregroundColor.
      ),
      cardTheme: CardThemeData(
        color: BjNeutral.surface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radiusLg,
          side: const BorderSide(color: BjNeutral.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
          color: BjNeutral.border, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: pill,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      // Most screens use ElevatedButton as their primary action, so it
      // renders as a filled accent pill.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: a.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: BjNeutral.surfaceMuted,
          disabledForegroundColor: BjNeutral.inkSubtle,
          elevation: 0,
          shadowColor: a.primary.withValues(alpha: 0.35),
          shape: pill,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ).copyWith(
          elevation: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.hovered) && !s.contains(WidgetState.disabled)
                  ? 3
                  : 0),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BjNeutral.ink,
          backgroundColor: BjNeutral.surface,
          side: const BorderSide(color: BjNeutral.borderStrong),
          shape: pill,
          padding: buttonPadding,
          minimumSize: buttonSize,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: pill,
          padding: const EdgeInsets.symmetric(
              horizontal: BjSpace.lg, vertical: BjSpace.sm),
          textStyle: buttonText,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: BjNeutral.inkMuted),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: a.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BjRadius.all(18)),
        extendedTextStyle: buttonText,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BjNeutral.surface,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: BjSpace.lg, vertical: BjSpace.md + 2),
        hintStyle: text.bodyMedium?.copyWith(color: BjNeutral.inkSubtle),
        labelStyle: text.bodyMedium?.copyWith(color: BjNeutral.inkMuted),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((s) =>
            (text.bodyMedium ?? const TextStyle()).copyWith(
                color: s.contains(WidgetState.error)
                    ? scheme.error
                    : s.contains(WidgetState.focused)
                        ? a.primary
                        : BjNeutral.inkMuted)),
        border: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: BjNeutral.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: const BorderSide(color: BjNeutral.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: BorderSide(color: a.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radiusMd,
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(side: BorderSide(color: BjNeutral.border)),
        side: const BorderSide(color: BjNeutral.border),
        backgroundColor: BjNeutral.surface,
        selectedColor: bj.accentSoft,
        checkmarkColor: a.primary,
        labelStyle: text.labelMedium?.copyWith(color: BjNeutral.ink),
        secondaryLabelStyle:
            text.labelMedium?.copyWith(color: scheme.onPrimaryContainer),
        padding: const EdgeInsets.symmetric(
            horizontal: BjSpace.sm, vertical: BjSpace.xs),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: BjNeutral.surface,
          selectedBackgroundColor: bj.accentSoft,
          selectedForegroundColor: scheme.onPrimaryContainer,
          foregroundColor: BjNeutral.inkMuted,
          side: const BorderSide(color: BjNeutral.border),
          textStyle: text.labelMedium,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: a.primary,
        unselectedLabelColor: BjNeutral.inkMuted,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: BjNeutral.border,
        indicator: UnderlineTabIndicator(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          borderSide: BorderSide(color: a.primary, width: 3),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
        iconColor: BjNeutral.inkMuted,
        titleTextStyle: text.titleSmall,
        subtitleTextStyle:
            text.bodySmall?.copyWith(color: BjNeutral.inkMuted),
        selectedColor: a.primary,
        selectedTileColor: bj.accentSoft,
        contentPadding: const EdgeInsets.symmetric(horizontal: BjSpace.lg),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: BjNeutral.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: BjNeutral.shadow.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(borderRadius: radiusXl),
        titleTextStyle: text.titleLarge,
        contentTextStyle:
            text.bodyMedium?.copyWith(color: BjNeutral.inkMuted),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: BjNeutral.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: BjNeutral.borderStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: BjNeutral.ink,
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        actionTextColor: bj.accentSoft,
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
        elevation: 4,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: BjNeutral.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shadowColor: BjNeutral.shadow.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: radiusMd,
          side: const BorderSide(color: BjNeutral.border),
        ),
        textStyle: text.bodyMedium,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(BjNeutral.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: radiusMd,
            side: const BorderSide(color: BjNeutral.border),
          )),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: BjNeutral.ink,
          borderRadius: BjRadius.all(BjRadius.sm),
        ),
        textStyle: text.labelSmall?.copyWith(color: Colors.white),
        waitDuration: const Duration(milliseconds: 400),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: a.primary,
        linearTrackColor: bj.accentSoft,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
        borderRadius: BjRadius.all(BjRadius.pill),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BjRadius.all(6)),
        side: const BorderSide(color: BjNeutral.borderStrong, width: 1.6),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Colors.transparent
                : BjNeutral.borderStrong),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: BjNeutral.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: bj.accentSoft,
        labelTextStyle: WidgetStatePropertyAll(text.labelSmall),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: BjNeutral.surface,
        indicatorColor: bj.accentSoft,
        selectedIconTheme: IconThemeData(color: a.primary),
        unselectedIconTheme: const IconThemeData(color: BjNeutral.inkMuted),
        selectedLabelTextStyle: text.labelMedium?.copyWith(color: a.primary),
        unselectedLabelTextStyle:
            text.labelMedium?.copyWith(color: BjNeutral.inkMuted),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: a.primary,
        textColor: Colors.white,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(BjNeutral.surface),
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: radiusMd)),
        ),
      ),
    );
  }

  /// Bricolage Grotesque: the display cut for headings, the text cut for
  /// body and labels. Sizes follow what the apps already use (a dense
  /// 13-14px body), with lighter weights than the w700-heavy literals most
  /// apps carry today.
  static TextTheme _textTheme() {
    const ink = BjNeutral.ink;
    TextStyle heading(double size, FontWeight w, [double height = 1.2]) =>
        TextStyle(
          fontFamily: BjFont.heading,
          fontSize: size,
          fontWeight: w,
          height: height,
          color: ink,
          letterSpacing: -0.1,
        );
    TextStyle body(double size, FontWeight w,
            {double height = 1.45, Color color = ink, double spacing = 0}) =>
        TextStyle(
          fontFamily: BjFont.body,
          fontSize: size,
          fontWeight: w,
          height: height,
          color: color,
          letterSpacing: spacing,
        );
    return TextTheme(
      displayLarge: heading(48, FontWeight.w700, 1.1),
      displayMedium: heading(40, FontWeight.w700, 1.1),
      displaySmall: heading(32, FontWeight.w700, 1.15),
      headlineLarge: heading(28, FontWeight.w700),
      headlineMedium: heading(24, FontWeight.w700),
      headlineSmall: heading(22, FontWeight.w700),
      titleLarge: heading(20, FontWeight.w700),
      titleMedium: heading(16, FontWeight.w500, 1.3),
      titleSmall: body(14, FontWeight.w600, height: 1.35),
      bodyLarge: body(15, FontWeight.w400),
      bodyMedium: body(14, FontWeight.w400),
      bodySmall: body(13, FontWeight.w400, color: BjNeutral.inkMuted),
      labelLarge: body(14, FontWeight.w600, height: 1.2, spacing: 0.1),
      labelMedium: body(13, FontWeight.w500, height: 1.2),
      labelSmall:
          body(11.5, FontWeight.w600, height: 1.2, spacing: 0.3),
    );
  }
}
