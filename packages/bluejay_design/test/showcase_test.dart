// Renders the design-system gallery as PNGs with the real bundled fonts,
// for design review and PR screenshots. Off by default (pixels depend on
// the host's font rendering). Run with:
//
//   BJ_DESIGN_SCREENSHOTS=1 flutter test test/showcase_test.dart --update-goldens
//
// Output: test/showcase/out/*.png (git-ignored).

import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:bluejay_design/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'showcase/gallery.dart';

final _enabled = Platform.environment['BJ_DESIGN_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const fonts = '../../assets/fonts';
  await loadBjFonts(fonts);
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await (FontLoader('MaterialIcons')
        ..addFont(file('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')))
      .load();
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {'phone': const Size(390, 3200), 'desktop': const Size(1280, 2300)};
  final accents = {
    'indigo': BjAccent.standard,
    'teal': BjAccent(primary: BjSwatches.teal.color),
    'rose': BjAccent(primary: BjSwatches.rose.color),
  };

  for (final size in sizes.entries) {
    for (final accent in accents.entries) {
      if (size.key == 'desktop' && accent.key != 'indigo') continue;
      testWidgets('gallery ${size.key} ${accent.key}', (t) async {
        t.view.physicalSize = size.value * 2;
        t.view.devicePixelRatio = 2;
        FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BluejayTheme.build(accent: accent.value),
          home: const GalleryScreen(),
        ));
        await t.pump(const Duration(seconds: 2));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('showcase/out/gallery_${size.key}_${accent.key}.png'));
        t.view.reset();
      }, skip: !_enabled);
    }
  }
}
