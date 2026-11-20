import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _darkRoom = Color(0xFF312E2B);
const _lightTable = Color(0xFFF5F3FF);

Color _textColor(WidgetTester tester, String text) {
  final rich = tester.widget<RichText>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)));
  return rich.text.style!.color!;
}

Widget _app(Widget home) =>
    MaterialApp(theme: BluejayTheme.build(), home: home);

void main() {
  group('AppBar', () {
    testWidgets('title and icons follow foregroundColor', (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        appBar: AppBar(
          backgroundColor: _darkRoom,
          foregroundColor: Colors.white,
          title: const Text('Chess'),
        ),
      )));
      expect(_textColor(tester, 'Chess'), Colors.white);
    });

    testWidgets('defaults to ink on the canvas', (tester) async {
      await tester.pumpWidget(
          _app(Scaffold(appBar: AppBar(title: const Text('Notes')))));
      expect(_textColor(tester, 'Notes'), BjNeutral.ink);
    });
  });

  for (final bg in [_darkRoom, _lightTable, const Color(0xFF2E7D32)]) {
    group('BjGameTheme on $bg', () {
      final palette = BjGamePalette(background: bg);
      final data = bjGameThemeData(BluejayTheme.build(), palette);
      final bj = data.extension<BjTheme>()!;

      test('text reads on the background and surface', () {
        for (final c in [
          data.textTheme.bodyMedium!.color!,
          data.textTheme.titleLarge!.color!,
          data.textTheme.bodySmall!.color!,
          bj.ink,
          bj.inkMuted,
        ]) {
          expect(contrastRatio(c, bg), greaterThanOrEqualTo(4.5));
          expect(contrastRatio(c, palette.resolvedSurface),
              greaterThanOrEqualTo(4.5));
        }
      });

      test('every tone reads on its own tint', () {
        for (final t in BjTone.values) {
          final tone = bj.tone(t);
          expect(contrastRatio(tone.foreground, tone.background),
              greaterThanOrEqualTo(4.5),
              reason: '$t');
        }
      });

      testWidgets('app bar, card and pill follow the palette', (tester) async {
        await tester.pumpWidget(_app(BjGameTheme(
          palette: palette,
          child: Scaffold(
            appBar: AppBar(title: const Text('Play')),
            body: const BjCard(child: Text('Score')),
          ),
        )));
        expect(_textColor(tester, 'Play'), palette.resolvedForeground);
        expect(_textColor(tester, 'Score'), palette.resolvedForeground);
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(scaffold.backgroundColor ?? data.scaffoldBackgroundColor, bg);
      });
    });
  }

  testWidgets('dialogs opened inside a game inherit it', (tester) async {
    const palette = BjGamePalette(background: _darkRoom);
    await tester.pumpWidget(_app(BjGameTheme(
      palette: palette,
      child: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(title: Text('Resign?')),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_textColor(tester, 'Resign?'), palette.resolvedForeground);
  });
}
