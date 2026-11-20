/// Text-to-speech that actually speaks in the language asked for.
///
/// `FlutterTts.setLanguage` is not enough on its own. On web it only switches
/// voice when an installed voice's tag *starts with* the exact tag given
/// (`sr-RS`, `es-ES`), and silently does nothing otherwise — including on the
/// first call, before the browser has finished loading its voice list. The
/// utterance then plays in the browser's default voice, which is the user's
/// own language: a learner hears a Serbian phrase read with English phonetics.
///
/// [LanguageSpeaker] resolves an installed voice for the [AppLanguage] itself
/// (exact tag first, then any regional variant of the same language), selects
/// it explicitly, and reports [SpeakOutcome.noVoice] instead of falling back
/// to a wrong-language voice when the device has none.
library;

import 'package:flutter_tts/flutter_tts.dart';

import 'language_catalog.dart';

/// What [LanguageSpeaker.speak] did.
enum SpeakOutcome {
  /// Handed to the TTS engine with a voice for the requested language (or,
  /// when the engine doesn't report its voices at all, with the locale tag).
  spoken,

  /// The device reports installed voices, but none for this language —
  /// nothing was played, so the caller can say so.
  noVoice,
}

/// Normalizes a platform locale tag for comparison: engines variously report
/// `sr-RS`, `sr_RS` and `SR-rs`.
String _normalizeTag(String tag) => tag.trim().replaceAll('_', '-').toLowerCase();

String _primarySubtag(String tag) => _normalizeTag(tag).split('-').first;

/// Picks the installed voice that best matches [language], from voices shaped
/// as `FlutterTts.getVoices` returns them (`{'name': ..., 'locale': ...}`).
///
/// Prefers an exact match on [AppLanguage.ttsLocaleId], then any voice for the
/// same primary language subtag (a `sr-Latn-RS` or `sr-ME` voice still
/// pronounces Serbian correctly). Returns null when there is none — callers
/// must not fall back to an arbitrary voice, since that is precisely the
/// wrong-language playback this exists to prevent.
Map<String, String>? pickTtsVoice(
  AppLanguage language,
  List<Map<String, String>> voices,
) {
  final wanted = _normalizeTag(language.ttsLocaleId);
  final wantedPrimary = _primarySubtag(language.ttsLocaleId);

  Map<String, String>? sameLanguage;
  for (final voice in voices) {
    final locale = voice['locale'];
    if (locale == null || locale.isEmpty || (voice['name'] ?? '').isEmpty) continue;
    if (_normalizeTag(locale) == wanted) return voice;
    if (sameLanguage == null && _primarySubtag(locale) == wantedPrimary) {
      sameLanguage = voice;
    }
  }
  return sameLanguage;
}

/// A [FlutterTts] wrapper that speaks text in a given [AppLanguage].
///
/// One instance per screen, replacing a bare `FlutterTts()`; call [stop] from
/// `dispose`.
class LanguageSpeaker {
  final FlutterTts _tts;
  List<Map<String, String>>? _voices;

  LanguageSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  /// Speaks [text] with a voice for [language].
  ///
  /// Never throws: a TTS engine error is reported as [SpeakOutcome.noVoice],
  /// since either way the learner heard nothing.
  Future<SpeakOutcome> speak(String text, AppLanguage language) async {
    try {
      await _tts.stop();
      final voices = await _installedVoices();
      if (voices.isEmpty) {
        // The engine won't list its voices (some Android engines before
        // they've bound), so there's nothing to choose between — the locale
        // tag is the best request available.
        await _tts.setLanguage(language.ttsLocaleId);
        await _tts.speak(text);
        return SpeakOutcome.spoken;
      }

      final voice = pickTtsVoice(language, voices);
      if (voice == null) return SpeakOutcome.noVoice;

      // setLanguage first so the utterance's lang matches the voice (on web
      // it would otherwise keep whatever language was last requested), then
      // pin the exact voice.
      await _tts.setLanguage(voice['locale']!);
      await _tts.setVoice({'name': voice['name']!, 'locale': voice['locale']!});
      await _tts.speak(text);
      return SpeakOutcome.spoken;
    } catch (_) {
      return SpeakOutcome.noVoice;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// The engine's installed voices, cached once non-empty.
  ///
  /// Browsers load voices asynchronously and return an empty list until they
  /// have, so an empty answer is retried briefly before being believed.
  Future<List<Map<String, String>>> _installedVoices() async {
    final cached = _voices;
    if (cached != null) return cached;
    for (var attempt = 0; attempt < 5; attempt++) {
      final voices = await _readVoices();
      if (voices.isNotEmpty) return _voices = voices;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return const [];
  }

  Future<List<Map<String, String>>> _readVoices() async {
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];
    return [
      for (final voice in raw)
        if (voice is Map)
          {
            'name': '${voice['name'] ?? ''}',
            'locale': '${voice['locale'] ?? ''}',
          },
    ];
  }
}
