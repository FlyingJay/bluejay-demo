import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/language_catalog.dart';

void main() {
  group('AppLanguage.all', () {
    test('every code is unique', () {
      final codes = AppLanguage.all.map((l) => l.code).toList();
      final duplicates = <String>{};
      final seen = <String>{};
      for (final code in codes) {
        if (!seen.add(code)) duplicates.add(code);
      }
      expect(duplicates, isEmpty, reason: 'duplicate language codes: $duplicates');
    });

    test('every entry has a name, endonym and both locale ids', () {
      for (final language in AppLanguage.all) {
        expect(language.name, isNotEmpty, reason: language.code);
        expect(language.nativeName, isNotEmpty, reason: language.code);
        expect(language.speechLocaleId, isNotEmpty, reason: language.code);
        expect(language.ttsLocaleId, isNotEmpty, reason: language.code);
      }
    });

    test('English is first, so it is the byCode fallback', () {
      expect(AppLanguage.all.first.code, 'en');
    });

    test('Serbian is present, in Cyrillic, with voice support', () {
      final serbian = AppLanguage.byCode('sr');
      expect(serbian.name, 'Serbian');
      expect(serbian.nativeName, 'Српски');
      expect(serbian.hasVoiceSupport, isTrue);
      expect(serbian.isLatinScript, isFalse);
      expect(serbian.speechLocaleId, 'sr-RS');
      expect(serbian.ttsLocaleId, 'sr-RS');
    });

    test('is a broad catalog, not a curated handful', () {
      expect(AppLanguage.all.length, greaterThan(150));
    });
  });

  group('voiceCapable', () {
    test('is a non-empty subset of the catalog', () {
      expect(AppLanguage.voiceCapable, isNotEmpty);
      expect(AppLanguage.voiceCapable.length, lessThan(AppLanguage.all.length));
      for (final language in AppLanguage.voiceCapable) {
        expect(language.hasVoiceSupport, isTrue);
        expect(AppLanguage.all, contains(language));
      }
    });

    test('starts with English, which the translator relies on as its fallback', () {
      expect(AppLanguage.voiceCapable.first.code, 'en');
    });
  });

  group('byCode', () {
    test('resolves a known code', () {
      expect(AppLanguage.byCode('ja').name, 'Japanese');
    });

    test('falls back to English rather than throwing on an unknown code', () {
      expect(AppLanguage.byCode('definitely-not-a-language').code, 'en');
    });
  });

  group('search', () {
    test('matches the English name case-insensitively', () {
      final results = AppLanguage.search('serb');
      expect(results.map((l) => l.code), contains('sr'));
    });

    test('matches the endonym', () {
      final results = AppLanguage.search('Српски');
      expect(results.single.code, 'sr');
    });

    test('matches the code', () {
      expect(AppLanguage.search('yue').map((l) => l.code), contains('yue'));
    });

    test('an empty query returns the pool unchanged', () {
      expect(AppLanguage.search('   ').length, AppLanguage.all.length);
      expect(
        AppLanguage.search('', pool: AppLanguage.voiceCapable).length,
        AppLanguage.voiceCapable.length,
      );
    });

    test('honours a restricted pool', () {
      final results = AppLanguage.search('a', pool: AppLanguage.voiceCapable);
      for (final language in results) {
        expect(language.hasVoiceSupport, isTrue);
      }
    });

    test('returns nothing for a query that matches nothing', () {
      expect(AppLanguage.search('zzzzqqqq'), isEmpty);
    });
  });

  group('displayName', () {
    test('pairs the English name with the endonym when they differ', () {
      expect(AppLanguage.byCode('sr').displayName, 'Serbian — Српски');
    });

    test('is not doubled up when they are the same', () {
      expect(AppLanguage.byCode('en').displayName, 'English');
    });
  });
}
