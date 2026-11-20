import 'dart:convert';
import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// design_tokens.json is the design system's values in a form other tools
/// read: the brand guide's sync check in bluejayorg/bluejay-business
/// (brand/tools/check_design_sync.py) compares the guide against it. This
/// test fails when a token changes and the file wasn't regenerated.
///
///   BJ_UPDATE_TOKENS=1 flutter test test/design_tokens_test.dart
void main() {
  test('design_tokens.json matches the design system', () {
    final file = File('design_tokens.json');
    final expected =
        '${const JsonEncoder.withIndent('  ').convert(designTokens())}\n';
    if (Platform.environment['BJ_UPDATE_TOKENS'] == '1') {
      file.writeAsStringSync(expected);
      return;
    }
    expect(file.existsSync() ? file.readAsStringSync() : '', expected,
        reason: 'Tokens changed. Regenerate with '
            '`BJ_UPDATE_TOKENS=1 flutter test test/design_tokens_test.dart`, '
            'then update the brand guide in bluejayorg/bluejay-business '
            '(brand/BRAND_GUIDE.md; brand/tools/check_design_sync.py lists '
            'what differs).');
  });
}

String _hex(Color c) => BjAccent.toHex(c);

Map<String, String> _toneMap(BjToneColors t) => {
      'foreground': _hex(t.foreground),
      'background': _hex(t.background),
      'border': _hex(t.border),
    };

Map<String, Object> designTokens() {
  final accent = BjAccent.standard;
  final bj = BjTheme.fromAccent(accent);
  final text = BluejayTheme.build().textTheme;
  Map<String, Object> style(TextStyle? s) => {
        'family': s!.fontFamily!,
        'size': s.fontSize!,
        'weight': s.fontWeight!.value,
        'lineHeight': s.height!,
      };
  return {
    'brand': {
      'navy': _hex(BjBrand.navy),
      'navyDeep': _hex(BjBrand.navyDeep),
    },
    'neutral': {
      'canvas': _hex(BjNeutral.canvas),
      'surface': _hex(BjNeutral.surface),
      'surfaceMuted': _hex(BjNeutral.surfaceMuted),
      'border': _hex(BjNeutral.border),
      'borderStrong': _hex(BjNeutral.borderStrong),
      'ink': _hex(BjNeutral.ink),
      'inkMuted': _hex(BjNeutral.inkMuted),
      'inkSubtle': _hex(BjNeutral.inkSubtle),
    },
    'accent': {
      'primary': _hex(accent.primary),
      'secondary': _hex(accent.secondary),
      'accentSoft': _hex(bj.accentSoft),
      'accentWash': _hex(bj.accentWash),
      'secondarySoft': _hex(bj.secondarySoft),
    },
    'tone': {
      for (final t in BjTone.values)
        t.name: _toneMap(bj.tone(t)),
    },
    'categorical': {
      for (final (name, color) in [
        ('violet', BjCategorical.violet),
        ('teal', BjCategorical.teal),
        ('amber', BjCategorical.amber),
        ('blue', BjCategorical.blue),
        ('rose', BjCategorical.rose),
        ('green', BjCategorical.green),
        ('fuchsia', BjCategorical.fuchsia),
        ('orange', BjCategorical.orange),
      ])
        name: _hex(color),
    },
    'swatches': {
      for (final s in BjSwatches.all) s.name: _hex(s.color),
    },
    'minContrast': kMinAccentContrast,
    'radius': {
      'xs': BjRadius.xs,
      'sm': BjRadius.sm,
      'md': BjRadius.md,
      'lg': BjRadius.lg,
      'xl': BjRadius.xl,
      'pill': BjRadius.pill,
    },
    'space': {
      'xxs': BjSpace.xxs,
      'xs': BjSpace.xs,
      'sm': BjSpace.sm,
      'md': BjSpace.md,
      'lg': BjSpace.lg,
      'xl': BjSpace.xl,
      'xxl': BjSpace.xxl,
      'xxxl': BjSpace.xxxl,
    },
    'motionMs': {
      'fast': BjMotion.fast.inMilliseconds,
      'medium': BjMotion.medium.inMilliseconds,
      'slow': BjMotion.slow.inMilliseconds,
    },
    'breakpoint': {
      'medium': BjBreakpoint.medium,
      'expanded': BjBreakpoint.expanded,
      'formWidth': BjBreakpoint.formWidth,
      'pageWidth': BjBreakpoint.pageWidth,
    },
    'font': {
      'heading': BjFont.heading,
      'body': BjFont.body,
    },
    'type': {
      'displayLarge': style(text.displayLarge),
      'displayMedium': style(text.displayMedium),
      'displaySmall': style(text.displaySmall),
      'headlineLarge': style(text.headlineLarge),
      'headlineMedium': style(text.headlineMedium),
      'headlineSmall': style(text.headlineSmall),
      'titleLarge': style(text.titleLarge),
      'titleMedium': style(text.titleMedium),
      'titleSmall': style(text.titleSmall),
      'bodyLarge': style(text.bodyLarge),
      'bodyMedium': style(text.bodyMedium),
      'bodySmall': style(text.bodySmall),
      'labelLarge': style(text.labelLarge),
      'labelMedium': style(text.labelMedium),
      'labelSmall': style(text.labelSmall),
    },
  };
}
