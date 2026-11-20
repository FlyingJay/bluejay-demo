/// Test helpers for screenshot tests. Import from test code only: it uses
/// `dart:io`.
///
/// ```dart
/// import 'package:bluejay_design/testing.dart';
///
/// setUpAll(() => loadBjFonts('../../assets/fonts'));
/// ```
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'src/tokens.dart';

/// Loads the design system's font families ([BjFont.files]) from
/// [fontsDir], the launcher's `assets/fonts/` relative to the test's
/// working directory (`../../assets/fonts` from a package, `assets/fonts`
/// from the repo root), so screenshots render with the real fonts.
Future<void> loadBjFonts(String fontsDir) async {
  for (final entry in BjFont.files.entries) {
    final loader = FontLoader(entry.key);
    for (final name in entry.value) {
      loader.addFont(File('$fontsDir/$name')
          .readAsBytes()
          .then((bytes) => ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}
