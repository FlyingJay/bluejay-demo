import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/language_catalog.dart';
import 'package:shared_services/language_speaker.dart';

Map<String, String> _voice(String name, String locale) => {'name': name, 'locale': locale};

void main() {
  final serbian = AppLanguage.byCode('sr');
  final spanish = AppLanguage.byCode('es');

  group('pickTtsVoice', () {
    test('prefers the exact locale tag', () {
      final voices = [
        _voice('English', 'en-US'),
        _voice('Mexican Spanish', 'es-MX'),
        _voice('Castilian Spanish', 'es-ES'),
      ];
      expect(pickTtsVoice(spanish, voices), _voice('Castilian Spanish', 'es-ES'));
    });

    test('matches underscore and differently-cased tags', () {
      final voices = [_voice('English', 'en_US'), _voice('Srpski', 'SR_rs')];
      expect(pickTtsVoice(serbian, voices), _voice('Srpski', 'SR_rs'));
    });

    test('falls back to another region of the same language', () {
      final voices = [_voice('English', 'en-US'), _voice('Srpski latinica', 'sr-Latn-RS')];
      expect(pickTtsVoice(serbian, voices), _voice('Srpski latinica', 'sr-Latn-RS'));
    });

    test('never falls back to a voice for a different language', () {
      // The reported bug: with no Serbian voice, playback came out in the
      // default (native-language) voice. No match must mean no voice.
      final voices = [_voice('English', 'en-US'), _voice('Croatian', 'hr-HR')];
      expect(pickTtsVoice(serbian, voices), isNull);
    });

    test('does not treat a shared prefix as the same language', () {
      // `startsWith` matching would pair a hypothetical `srn` voice with `sr`.
      final voices = [_voice('Sranan', 'srn-SR')];
      expect(pickTtsVoice(serbian, voices), isNull);
    });

    test('skips voices missing a name or locale', () {
      final voices = [_voice('', 'sr-RS'), _voice('Srpski', '')];
      expect(pickTtsVoice(serbian, voices), isNull);
    });
  });
}
