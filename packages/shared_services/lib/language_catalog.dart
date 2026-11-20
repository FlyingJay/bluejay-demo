/// The platform-wide catalog of human languages any bluejay app can offer.
///
/// This exists because language lists are exactly the kind of table that gets
/// copy-pasted per app and then drifts: the voice translator needed one, the
/// Language Learner needed a much longer one, and a third app will need a
/// third. Rather than duplicating (and re-researching) locale tags per
/// package, every app selects a slice of this single list — see
/// [voiceCapable] for the speech-driven slice.
library;

/// One selectable language, plus the metadata apps need to do something with
/// it: locale tags for speech, an endonym for the picker, and whether it is
/// written in a Latin script (which drives whether an app should offer
/// romanization alongside the text).
class AppLanguage {
  /// Stable app-level identifier persisted in Firestore. Usually the ISO 639
  /// code, occasionally region-qualified where the regional variant is a
  /// meaningfully different thing to learn or translate into (`pt` vs
  /// `pt-br`).
  final String code;

  /// English name, used for prompts to language models and for searching.
  final String name;

  /// The language's own name for itself. Shown in pickers so a speaker can
  /// find their language without reading English.
  final String nativeName;

  /// BCP-47 tag handed to on-device speech *recognition*.
  ///
  /// [speechLocaleId] and [ttsLocaleId] are the same tag for every entry
  /// today, but are kept distinct because `speech_to_text` and `flutter_tts`
  /// resolve locale support against two different underlying platform
  /// engines (STT vs TTS) — a locale supported for recognition is not
  /// guaranteed to have an installed voice for playback, or vice versa, so a
  /// future fix for one shouldn't need to touch the other.
  final String speechLocaleId;

  /// BCP-47 tag handed to on-device text-to-speech. See [speechLocaleId].
  final String ttsLocaleId;

  /// Whether on-device speech recognition and TTS voices for this locale ship
  /// broadly with Android's (Google) and iOS's engines.
  ///
  /// Apps whose whole interaction model is voice (the Translator) must filter
  /// to [voiceCapable]; text-first apps (the Language Learner) can offer the
  /// entire catalog, because a text-in/text-out language model has no locale
  /// restriction at all, and simply hide the "speak this" affordance where
  /// this is false.
  final bool hasVoiceSupport;

  /// False for languages written in a non-Latin script, where an app should
  /// offer a romanization alongside the native text so a learner can attempt
  /// to pronounce it before they can read the script.
  final bool isLatinScript;

  const AppLanguage({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.speechLocaleId,
    required this.ttsLocaleId,
    this.hasVoiceSupport = false,
    this.isLatinScript = true,
  });

  /// `English — English` / `Serbian — Српски`, for pickers and chips.
  String get displayName => nativeName == name ? name : '$name — $nativeName';

  @override
  String toString() => 'AppLanguage($code)';

  /// Every language in the catalog.
  ///
  /// English is deliberately first: it is the fallback returned by [byCode]
  /// for an unrecognized code, and the default "language I already speak".
  /// Serbian is deliberately second — the original voice-translator ticket
  /// asked for it specifically, and it stays prominent for the same reason.
  ///
  /// The first block is the set with broad on-device voice support; the
  /// second is the long tail that a text-based language model handles fine
  /// but that has no reliable on-device voice.
  static const List<AppLanguage> all = [
    // ── Broad on-device speech + TTS support ────────────────────────────
    AppLanguage(code: 'en', name: 'English', nativeName: 'English', speechLocaleId: 'en-US', ttsLocaleId: 'en-US', hasVoiceSupport: true),
    AppLanguage(code: 'sr', name: 'Serbian', nativeName: 'Српски', speechLocaleId: 'sr-RS', ttsLocaleId: 'sr-RS', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'es', name: 'Spanish', nativeName: 'Español', speechLocaleId: 'es-ES', ttsLocaleId: 'es-ES', hasVoiceSupport: true),
    AppLanguage(code: 'es-mx', name: 'Spanish (Mexico)', nativeName: 'Español (México)', speechLocaleId: 'es-MX', ttsLocaleId: 'es-MX', hasVoiceSupport: true),
    AppLanguage(code: 'fr', name: 'French', nativeName: 'Français', speechLocaleId: 'fr-FR', ttsLocaleId: 'fr-FR', hasVoiceSupport: true),
    AppLanguage(code: 'fr-ca', name: 'French (Canada)', nativeName: 'Français (Canada)', speechLocaleId: 'fr-CA', ttsLocaleId: 'fr-CA', hasVoiceSupport: true),
    AppLanguage(code: 'de', name: 'German', nativeName: 'Deutsch', speechLocaleId: 'de-DE', ttsLocaleId: 'de-DE', hasVoiceSupport: true),
    AppLanguage(code: 'it', name: 'Italian', nativeName: 'Italiano', speechLocaleId: 'it-IT', ttsLocaleId: 'it-IT', hasVoiceSupport: true),
    AppLanguage(code: 'pt', name: 'Portuguese', nativeName: 'Português', speechLocaleId: 'pt-PT', ttsLocaleId: 'pt-PT', hasVoiceSupport: true),
    AppLanguage(code: 'pt-br', name: 'Portuguese (Brazil)', nativeName: 'Português (Brasil)', speechLocaleId: 'pt-BR', ttsLocaleId: 'pt-BR', hasVoiceSupport: true),
    AppLanguage(code: 'ru', name: 'Russian', nativeName: 'Русский', speechLocaleId: 'ru-RU', ttsLocaleId: 'ru-RU', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'hr', name: 'Croatian', nativeName: 'Hrvatski', speechLocaleId: 'hr-HR', ttsLocaleId: 'hr-HR', hasVoiceSupport: true),
    AppLanguage(code: 'bs', name: 'Bosnian', nativeName: 'Bosanski', speechLocaleId: 'bs-BA', ttsLocaleId: 'bs-BA', hasVoiceSupport: true),
    AppLanguage(code: 'mk', name: 'Macedonian', nativeName: 'Македонски', speechLocaleId: 'mk-MK', ttsLocaleId: 'mk-MK', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'sq', name: 'Albanian', nativeName: 'Shqip', speechLocaleId: 'sq-AL', ttsLocaleId: 'sq-AL', hasVoiceSupport: true),
    AppLanguage(code: 'sl', name: 'Slovenian', nativeName: 'Slovenščina', speechLocaleId: 'sl-SI', ttsLocaleId: 'sl-SI', hasVoiceSupport: true),
    AppLanguage(code: 'zh', name: 'Chinese (Mandarin)', nativeName: '简体中文', speechLocaleId: 'zh-CN', ttsLocaleId: 'zh-CN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'zh-tw', name: 'Chinese (Taiwan)', nativeName: '繁體中文', speechLocaleId: 'zh-TW', ttsLocaleId: 'zh-TW', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'yue', name: 'Chinese (Cantonese)', nativeName: '粵語', speechLocaleId: 'yue-HK', ttsLocaleId: 'yue-HK', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ja', name: 'Japanese', nativeName: '日本語', speechLocaleId: 'ja-JP', ttsLocaleId: 'ja-JP', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ko', name: 'Korean', nativeName: '한국어', speechLocaleId: 'ko-KR', ttsLocaleId: 'ko-KR', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ar', name: 'Arabic', nativeName: 'العربية', speechLocaleId: 'ar-SA', ttsLocaleId: 'ar-SA', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'he', name: 'Hebrew', nativeName: 'עברית', speechLocaleId: 'he-IL', ttsLocaleId: 'he-IL', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'fa', name: 'Persian', nativeName: 'فارسی', speechLocaleId: 'fa-IR', ttsLocaleId: 'fa-IR', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'tr', name: 'Turkish', nativeName: 'Türkçe', speechLocaleId: 'tr-TR', ttsLocaleId: 'tr-TR', hasVoiceSupport: true),
    AppLanguage(code: 'nl', name: 'Dutch', nativeName: 'Nederlands', speechLocaleId: 'nl-NL', ttsLocaleId: 'nl-NL', hasVoiceSupport: true),
    AppLanguage(code: 'sv', name: 'Swedish', nativeName: 'Svenska', speechLocaleId: 'sv-SE', ttsLocaleId: 'sv-SE', hasVoiceSupport: true),
    AppLanguage(code: 'nb', name: 'Norwegian', nativeName: 'Norsk bokmål', speechLocaleId: 'nb-NO', ttsLocaleId: 'nb-NO', hasVoiceSupport: true),
    AppLanguage(code: 'da', name: 'Danish', nativeName: 'Dansk', speechLocaleId: 'da-DK', ttsLocaleId: 'da-DK', hasVoiceSupport: true),
    AppLanguage(code: 'fi', name: 'Finnish', nativeName: 'Suomi', speechLocaleId: 'fi-FI', ttsLocaleId: 'fi-FI', hasVoiceSupport: true),
    AppLanguage(code: 'is', name: 'Icelandic', nativeName: 'Íslenska', speechLocaleId: 'is-IS', ttsLocaleId: 'is-IS', hasVoiceSupport: true),
    AppLanguage(code: 'pl', name: 'Polish', nativeName: 'Polski', speechLocaleId: 'pl-PL', ttsLocaleId: 'pl-PL', hasVoiceSupport: true),
    AppLanguage(code: 'cs', name: 'Czech', nativeName: 'Čeština', speechLocaleId: 'cs-CZ', ttsLocaleId: 'cs-CZ', hasVoiceSupport: true),
    AppLanguage(code: 'sk', name: 'Slovak', nativeName: 'Slovenčina', speechLocaleId: 'sk-SK', ttsLocaleId: 'sk-SK', hasVoiceSupport: true),
    AppLanguage(code: 'hu', name: 'Hungarian', nativeName: 'Magyar', speechLocaleId: 'hu-HU', ttsLocaleId: 'hu-HU', hasVoiceSupport: true),
    AppLanguage(code: 'ro', name: 'Romanian', nativeName: 'Română', speechLocaleId: 'ro-RO', ttsLocaleId: 'ro-RO', hasVoiceSupport: true),
    AppLanguage(code: 'bg', name: 'Bulgarian', nativeName: 'Български', speechLocaleId: 'bg-BG', ttsLocaleId: 'bg-BG', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'uk', name: 'Ukrainian', nativeName: 'Українська', speechLocaleId: 'uk-UA', ttsLocaleId: 'uk-UA', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'el', name: 'Greek', nativeName: 'Ελληνικά', speechLocaleId: 'el-GR', ttsLocaleId: 'el-GR', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'lt', name: 'Lithuanian', nativeName: 'Lietuvių', speechLocaleId: 'lt-LT', ttsLocaleId: 'lt-LT', hasVoiceSupport: true),
    AppLanguage(code: 'lv', name: 'Latvian', nativeName: 'Latviešu', speechLocaleId: 'lv-LV', ttsLocaleId: 'lv-LV', hasVoiceSupport: true),
    AppLanguage(code: 'et', name: 'Estonian', nativeName: 'Eesti', speechLocaleId: 'et-EE', ttsLocaleId: 'et-EE', hasVoiceSupport: true),
    AppLanguage(code: 'ca', name: 'Catalan', nativeName: 'Català', speechLocaleId: 'ca-ES', ttsLocaleId: 'ca-ES', hasVoiceSupport: true),
    AppLanguage(code: 'eu', name: 'Basque', nativeName: 'Euskara', speechLocaleId: 'eu-ES', ttsLocaleId: 'eu-ES', hasVoiceSupport: true),
    AppLanguage(code: 'gl', name: 'Galician', nativeName: 'Galego', speechLocaleId: 'gl-ES', ttsLocaleId: 'gl-ES', hasVoiceSupport: true),
    AppLanguage(code: 'hi', name: 'Hindi', nativeName: 'हिन्दी', speechLocaleId: 'hi-IN', ttsLocaleId: 'hi-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'bn', name: 'Bengali', nativeName: 'বাংলা', speechLocaleId: 'bn-IN', ttsLocaleId: 'bn-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ur', name: 'Urdu', nativeName: 'اردو', speechLocaleId: 'ur-PK', ttsLocaleId: 'ur-PK', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'pa', name: 'Punjabi', nativeName: 'ਪੰਜਾਬੀ', speechLocaleId: 'pa-IN', ttsLocaleId: 'pa-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'gu', name: 'Gujarati', nativeName: 'ગુજરાતી', speechLocaleId: 'gu-IN', ttsLocaleId: 'gu-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'mr', name: 'Marathi', nativeName: 'मराठी', speechLocaleId: 'mr-IN', ttsLocaleId: 'mr-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ta', name: 'Tamil', nativeName: 'தமிழ்', speechLocaleId: 'ta-IN', ttsLocaleId: 'ta-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'te', name: 'Telugu', nativeName: 'తెలుగు', speechLocaleId: 'te-IN', ttsLocaleId: 'te-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'kn', name: 'Kannada', nativeName: 'ಕನ್ನಡ', speechLocaleId: 'kn-IN', ttsLocaleId: 'kn-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ml', name: 'Malayalam', nativeName: 'മലയാളം', speechLocaleId: 'ml-IN', ttsLocaleId: 'ml-IN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ne', name: 'Nepali', nativeName: 'नेपाली', speechLocaleId: 'ne-NP', ttsLocaleId: 'ne-NP', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'si', name: 'Sinhala', nativeName: 'සිංහල', speechLocaleId: 'si-LK', ttsLocaleId: 'si-LK', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'th', name: 'Thai', nativeName: 'ไทย', speechLocaleId: 'th-TH', ttsLocaleId: 'th-TH', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'vi', name: 'Vietnamese', nativeName: 'Tiếng Việt', speechLocaleId: 'vi-VN', ttsLocaleId: 'vi-VN', hasVoiceSupport: true),
    AppLanguage(code: 'km', name: 'Khmer', nativeName: 'ខ្មែរ', speechLocaleId: 'km-KH', ttsLocaleId: 'km-KH', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'lo', name: 'Lao', nativeName: 'ລາວ', speechLocaleId: 'lo-LA', ttsLocaleId: 'lo-LA', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'my', name: 'Burmese', nativeName: 'မြန်မာ', speechLocaleId: 'my-MM', ttsLocaleId: 'my-MM', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'id', name: 'Indonesian', nativeName: 'Bahasa Indonesia', speechLocaleId: 'id-ID', ttsLocaleId: 'id-ID', hasVoiceSupport: true),
    AppLanguage(code: 'ms', name: 'Malay', nativeName: 'Bahasa Melayu', speechLocaleId: 'ms-MY', ttsLocaleId: 'ms-MY', hasVoiceSupport: true),
    AppLanguage(code: 'fil', name: 'Filipino', nativeName: 'Filipino', speechLocaleId: 'fil-PH', ttsLocaleId: 'fil-PH', hasVoiceSupport: true),
    AppLanguage(code: 'mn', name: 'Mongolian', nativeName: 'Монгол', speechLocaleId: 'mn-MN', ttsLocaleId: 'mn-MN', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'ka', name: 'Georgian', nativeName: 'ქართული', speechLocaleId: 'ka-GE', ttsLocaleId: 'ka-GE', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'hy', name: 'Armenian', nativeName: 'Հայերեն', speechLocaleId: 'hy-AM', ttsLocaleId: 'hy-AM', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'az', name: 'Azerbaijani', nativeName: 'Azərbaycan', speechLocaleId: 'az-AZ', ttsLocaleId: 'az-AZ', hasVoiceSupport: true),
    AppLanguage(code: 'kk', name: 'Kazakh', nativeName: 'Қазақша', speechLocaleId: 'kk-KZ', ttsLocaleId: 'kk-KZ', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'uz', name: 'Uzbek', nativeName: 'Oʻzbekcha', speechLocaleId: 'uz-UZ', ttsLocaleId: 'uz-UZ', hasVoiceSupport: true),
    AppLanguage(code: 'sw', name: 'Swahili', nativeName: 'Kiswahili', speechLocaleId: 'sw-KE', ttsLocaleId: 'sw-KE', hasVoiceSupport: true),
    AppLanguage(code: 'am', name: 'Amharic', nativeName: 'አማርኛ', speechLocaleId: 'am-ET', ttsLocaleId: 'am-ET', hasVoiceSupport: true, isLatinScript: false),
    AppLanguage(code: 'zu', name: 'Zulu', nativeName: 'isiZulu', speechLocaleId: 'zu-ZA', ttsLocaleId: 'zu-ZA', hasVoiceSupport: true),
    AppLanguage(code: 'af', name: 'Afrikaans', nativeName: 'Afrikaans', speechLocaleId: 'af-ZA', ttsLocaleId: 'af-ZA', hasVoiceSupport: true),

    // ── Text-capable long tail (no reliable on-device voice) ─────────────
    // Europe
    AppLanguage(code: 'be', name: 'Belarusian', nativeName: 'Беларуская', speechLocaleId: 'be-BY', ttsLocaleId: 'be-BY', isLatinScript: false),
    AppLanguage(code: 'cnr', name: 'Montenegrin', nativeName: 'Crnogorski', speechLocaleId: 'cnr-ME', ttsLocaleId: 'cnr-ME'),
    AppLanguage(code: 'cy', name: 'Welsh', nativeName: 'Cymraeg', speechLocaleId: 'cy-GB', ttsLocaleId: 'cy-GB'),
    AppLanguage(code: 'ga', name: 'Irish', nativeName: 'Gaeilge', speechLocaleId: 'ga-IE', ttsLocaleId: 'ga-IE'),
    AppLanguage(code: 'gd', name: 'Scottish Gaelic', nativeName: 'Gàidhlig', speechLocaleId: 'gd-GB', ttsLocaleId: 'gd-GB'),
    AppLanguage(code: 'gv', name: 'Manx', nativeName: 'Gaelg', speechLocaleId: 'gv-IM', ttsLocaleId: 'gv-IM'),
    AppLanguage(code: 'kw', name: 'Cornish', nativeName: 'Kernewek', speechLocaleId: 'kw-GB', ttsLocaleId: 'kw-GB'),
    AppLanguage(code: 'br', name: 'Breton', nativeName: 'Brezhoneg', speechLocaleId: 'br-FR', ttsLocaleId: 'br-FR'),
    AppLanguage(code: 'mt', name: 'Maltese', nativeName: 'Malti', speechLocaleId: 'mt-MT', ttsLocaleId: 'mt-MT'),
    AppLanguage(code: 'lb', name: 'Luxembourgish', nativeName: 'Lëtzebuergesch', speechLocaleId: 'lb-LU', ttsLocaleId: 'lb-LU'),
    AppLanguage(code: 'fy', name: 'Western Frisian', nativeName: 'Frysk', speechLocaleId: 'fy-NL', ttsLocaleId: 'fy-NL'),
    AppLanguage(code: 'nn', name: 'Norwegian Nynorsk', nativeName: 'Nynorsk', speechLocaleId: 'nn-NO', ttsLocaleId: 'nn-NO'),
    AppLanguage(code: 'fo', name: 'Faroese', nativeName: 'Føroyskt', speechLocaleId: 'fo-FO', ttsLocaleId: 'fo-FO'),
    AppLanguage(code: 'kl', name: 'Greenlandic', nativeName: 'Kalaallisut', speechLocaleId: 'kl-GL', ttsLocaleId: 'kl-GL'),
    AppLanguage(code: 'se', name: 'Northern Sami', nativeName: 'Davvisámegiella', speechLocaleId: 'se-NO', ttsLocaleId: 'se-NO'),
    AppLanguage(code: 'yi', name: 'Yiddish', nativeName: 'ייִדיש', speechLocaleId: 'yi-001', ttsLocaleId: 'yi-001', isLatinScript: false),
    AppLanguage(code: 'co', name: 'Corsican', nativeName: 'Corsu', speechLocaleId: 'co-FR', ttsLocaleId: 'co-FR'),
    AppLanguage(code: 'oc', name: 'Occitan', nativeName: 'Occitan', speechLocaleId: 'oc-FR', ttsLocaleId: 'oc-FR'),
    AppLanguage(code: 'sc', name: 'Sardinian', nativeName: 'Sardu', speechLocaleId: 'sc-IT', ttsLocaleId: 'sc-IT'),
    AppLanguage(code: 'scn', name: 'Sicilian', nativeName: 'Sicilianu', speechLocaleId: 'scn-IT', ttsLocaleId: 'scn-IT'),
    AppLanguage(code: 'nap', name: 'Neapolitan', nativeName: 'Napulitano', speechLocaleId: 'nap-IT', ttsLocaleId: 'nap-IT'),
    AppLanguage(code: 'vec', name: 'Venetian', nativeName: 'Vèneto', speechLocaleId: 'vec-IT', ttsLocaleId: 'vec-IT'),
    AppLanguage(code: 'fur', name: 'Friulian', nativeName: 'Furlan', speechLocaleId: 'fur-IT', ttsLocaleId: 'fur-IT'),
    AppLanguage(code: 'rm', name: 'Romansh', nativeName: 'Rumantsch', speechLocaleId: 'rm-CH', ttsLocaleId: 'rm-CH'),
    AppLanguage(code: 'ast', name: 'Asturian', nativeName: 'Asturianu', speechLocaleId: 'ast-ES', ttsLocaleId: 'ast-ES'),
    AppLanguage(code: 'an', name: 'Aragonese', nativeName: 'Aragonés', speechLocaleId: 'an-ES', ttsLocaleId: 'an-ES'),
    AppLanguage(code: 'lad', name: 'Ladino', nativeName: 'Ladino', speechLocaleId: 'lad-001', ttsLocaleId: 'lad-001'),
    AppLanguage(code: 'hsb', name: 'Upper Sorbian', nativeName: 'Hornjoserbšćina', speechLocaleId: 'hsb-DE', ttsLocaleId: 'hsb-DE'),
    AppLanguage(code: 'dsb', name: 'Lower Sorbian', nativeName: 'Dolnoserbšćina', speechLocaleId: 'dsb-DE', ttsLocaleId: 'dsb-DE'),
    AppLanguage(code: 'szl', name: 'Silesian', nativeName: 'Ślōnskŏ gŏdka', speechLocaleId: 'szl-PL', ttsLocaleId: 'szl-PL'),
    AppLanguage(code: 'rue', name: 'Rusyn', nativeName: 'Русиньскый', speechLocaleId: 'rue-UA', ttsLocaleId: 'rue-UA', isLatinScript: false),
    AppLanguage(code: 'tt', name: 'Tatar', nativeName: 'Татарча', speechLocaleId: 'tt-RU', ttsLocaleId: 'tt-RU', isLatinScript: false),
    AppLanguage(code: 'ba', name: 'Bashkir', nativeName: 'Башҡортса', speechLocaleId: 'ba-RU', ttsLocaleId: 'ba-RU', isLatinScript: false),
    AppLanguage(code: 'cv', name: 'Chuvash', nativeName: 'Чӑвашла', speechLocaleId: 'cv-RU', ttsLocaleId: 'cv-RU', isLatinScript: false),
    AppLanguage(code: 'ce', name: 'Chechen', nativeName: 'Нохчийн', speechLocaleId: 'ce-RU', ttsLocaleId: 'ce-RU', isLatinScript: false),
    AppLanguage(code: 'os', name: 'Ossetian', nativeName: 'Ирон', speechLocaleId: 'os-GE', ttsLocaleId: 'os-GE', isLatinScript: false),
    AppLanguage(code: 'ab', name: 'Abkhaz', nativeName: 'Аҧсуа', speechLocaleId: 'ab-GE', ttsLocaleId: 'ab-GE', isLatinScript: false),

    // Classical, historical and constructed — all commonly studied
    AppLanguage(code: 'la', name: 'Latin', nativeName: 'Latina', speechLocaleId: 'la-VA', ttsLocaleId: 'la-VA'),
    AppLanguage(code: 'grc', name: 'Ancient Greek', nativeName: 'Ἀρχαία Ἑλληνική', speechLocaleId: 'grc-GR', ttsLocaleId: 'grc-GR', isLatinScript: false),
    AppLanguage(code: 'ang', name: 'Old English', nativeName: 'Ænglisc', speechLocaleId: 'ang-GB', ttsLocaleId: 'ang-GB'),
    AppLanguage(code: 'non', name: 'Old Norse', nativeName: 'Norrœnt mál', speechLocaleId: 'non-IS', ttsLocaleId: 'non-IS'),
    AppLanguage(code: 'cu', name: 'Church Slavonic', nativeName: 'Словѣньскъ', speechLocaleId: 'cu-RU', ttsLocaleId: 'cu-RU', isLatinScript: false),
    AppLanguage(code: 'eo', name: 'Esperanto', nativeName: 'Esperanto', speechLocaleId: 'eo-001', ttsLocaleId: 'eo-001'),
    AppLanguage(code: 'ia', name: 'Interlingua', nativeName: 'Interlingua', speechLocaleId: 'ia-001', ttsLocaleId: 'ia-001'),
    AppLanguage(code: 'vo', name: 'Volapük', nativeName: 'Volapük', speechLocaleId: 'vo-001', ttsLocaleId: 'vo-001'),

    // Middle East, Central and South Asia
    AppLanguage(code: 'arz', name: 'Arabic (Egyptian)', nativeName: 'مصرى', speechLocaleId: 'arz-EG', ttsLocaleId: 'arz-EG', isLatinScript: false),
    AppLanguage(code: 'ary', name: 'Arabic (Moroccan)', nativeName: 'الدارجة', speechLocaleId: 'ary-MA', ttsLocaleId: 'ary-MA', isLatinScript: false),
    AppLanguage(code: 'apc', name: 'Arabic (Levantine)', nativeName: 'شامي', speechLocaleId: 'apc-SY', ttsLocaleId: 'apc-SY', isLatinScript: false),
    AppLanguage(code: 'ku', name: 'Kurdish (Kurmanji)', nativeName: 'Kurmancî', speechLocaleId: 'ku-TR', ttsLocaleId: 'ku-TR'),
    AppLanguage(code: 'ckb', name: 'Kurdish (Sorani)', nativeName: 'کوردیی ناوەندی', speechLocaleId: 'ckb-IQ', ttsLocaleId: 'ckb-IQ', isLatinScript: false),
    AppLanguage(code: 'ps', name: 'Pashto', nativeName: 'پښتو', speechLocaleId: 'ps-AF', ttsLocaleId: 'ps-AF', isLatinScript: false),
    AppLanguage(code: 'prs', name: 'Dari', nativeName: 'دری', speechLocaleId: 'prs-AF', ttsLocaleId: 'prs-AF', isLatinScript: false),
    AppLanguage(code: 'bal', name: 'Balochi', nativeName: 'بلوچی', speechLocaleId: 'bal-PK', ttsLocaleId: 'bal-PK', isLatinScript: false),
    AppLanguage(code: 'sd', name: 'Sindhi', nativeName: 'سنڌي', speechLocaleId: 'sd-PK', ttsLocaleId: 'sd-PK', isLatinScript: false),
    AppLanguage(code: 'ks', name: 'Kashmiri', nativeName: 'کٲشُر', speechLocaleId: 'ks-IN', ttsLocaleId: 'ks-IN', isLatinScript: false),
    AppLanguage(code: 'as', name: 'Assamese', nativeName: 'অসমীয়া', speechLocaleId: 'as-IN', ttsLocaleId: 'as-IN', isLatinScript: false),
    AppLanguage(code: 'or', name: 'Odia', nativeName: 'ଓଡ଼ିଆ', speechLocaleId: 'or-IN', ttsLocaleId: 'or-IN', isLatinScript: false),
    AppLanguage(code: 'mai', name: 'Maithili', nativeName: 'मैथिली', speechLocaleId: 'mai-IN', ttsLocaleId: 'mai-IN', isLatinScript: false),
    AppLanguage(code: 'bho', name: 'Bhojpuri', nativeName: 'भोजपुरी', speechLocaleId: 'bho-IN', ttsLocaleId: 'bho-IN', isLatinScript: false),
    AppLanguage(code: 'kok', name: 'Konkani', nativeName: 'कोंकणी', speechLocaleId: 'kok-IN', ttsLocaleId: 'kok-IN', isLatinScript: false),
    AppLanguage(code: 'sat', name: 'Santali', nativeName: 'ᱥᱟᱱᱛᱟᱲᱤ', speechLocaleId: 'sat-IN', ttsLocaleId: 'sat-IN', isLatinScript: false),
    AppLanguage(code: 'mni', name: 'Meitei (Manipuri)', nativeName: 'ꯃꯤꯇꯩꯂꯣꯟ', speechLocaleId: 'mni-IN', ttsLocaleId: 'mni-IN', isLatinScript: false),
    AppLanguage(code: 'sa', name: 'Sanskrit', nativeName: 'संस्कृतम्', speechLocaleId: 'sa-IN', ttsLocaleId: 'sa-IN', isLatinScript: false),
    AppLanguage(code: 'dv', name: 'Dhivehi', nativeName: 'ދިވެހި', speechLocaleId: 'dv-MV', ttsLocaleId: 'dv-MV', isLatinScript: false),
    AppLanguage(code: 'bo', name: 'Tibetan', nativeName: 'བོད་སྐད་', speechLocaleId: 'bo-CN', ttsLocaleId: 'bo-CN', isLatinScript: false),
    AppLanguage(code: 'dz', name: 'Dzongkha', nativeName: 'རྫོང་ཁ', speechLocaleId: 'dz-BT', ttsLocaleId: 'dz-BT', isLatinScript: false),
    AppLanguage(code: 'ug', name: 'Uyghur', nativeName: 'ئۇيغۇرچە', speechLocaleId: 'ug-CN', ttsLocaleId: 'ug-CN', isLatinScript: false),
    AppLanguage(code: 'ky', name: 'Kyrgyz', nativeName: 'Кыргызча', speechLocaleId: 'ky-KG', ttsLocaleId: 'ky-KG', isLatinScript: false),
    AppLanguage(code: 'tg', name: 'Tajik', nativeName: 'Тоҷикӣ', speechLocaleId: 'tg-TJ', ttsLocaleId: 'tg-TJ', isLatinScript: false),
    AppLanguage(code: 'tk', name: 'Turkmen', nativeName: 'Türkmen', speechLocaleId: 'tk-TM', ttsLocaleId: 'tk-TM'),

    // South-East Asia and the Pacific
    AppLanguage(code: 'jv', name: 'Javanese', nativeName: 'Basa Jawa', speechLocaleId: 'jv-ID', ttsLocaleId: 'jv-ID'),
    AppLanguage(code: 'su', name: 'Sundanese', nativeName: 'Basa Sunda', speechLocaleId: 'su-ID', ttsLocaleId: 'su-ID'),
    AppLanguage(code: 'ceb', name: 'Cebuano', nativeName: 'Binisaya', speechLocaleId: 'ceb-PH', ttsLocaleId: 'ceb-PH'),
    AppLanguage(code: 'ilo', name: 'Ilocano', nativeName: 'Ilokano', speechLocaleId: 'ilo-PH', ttsLocaleId: 'ilo-PH'),
    AppLanguage(code: 'hil', name: 'Hiligaynon', nativeName: 'Ilonggo', speechLocaleId: 'hil-PH', ttsLocaleId: 'hil-PH'),
    AppLanguage(code: 'war', name: 'Waray', nativeName: 'Winaray', speechLocaleId: 'war-PH', ttsLocaleId: 'war-PH'),
    AppLanguage(code: 'pam', name: 'Kapampangan', nativeName: 'Kapampangan', speechLocaleId: 'pam-PH', ttsLocaleId: 'pam-PH'),
    AppLanguage(code: 'bcl', name: 'Bikol', nativeName: 'Bikol', speechLocaleId: 'bcl-PH', ttsLocaleId: 'bcl-PH'),
    AppLanguage(code: 'hmn', name: 'Hmong', nativeName: 'Hmoob', speechLocaleId: 'hmn-CN', ttsLocaleId: 'hmn-CN'),
    AppLanguage(code: 'mi', name: 'Māori', nativeName: 'Te Reo Māori', speechLocaleId: 'mi-NZ', ttsLocaleId: 'mi-NZ'),
    AppLanguage(code: 'haw', name: 'Hawaiian', nativeName: 'ʻŌlelo Hawaiʻi', speechLocaleId: 'haw-US', ttsLocaleId: 'haw-US'),
    AppLanguage(code: 'sm', name: 'Samoan', nativeName: 'Gagana Sāmoa', speechLocaleId: 'sm-WS', ttsLocaleId: 'sm-WS'),
    AppLanguage(code: 'to', name: 'Tongan', nativeName: 'Lea faka-Tonga', speechLocaleId: 'to-TO', ttsLocaleId: 'to-TO'),
    AppLanguage(code: 'fj', name: 'Fijian', nativeName: 'Na Vosa Vakaviti', speechLocaleId: 'fj-FJ', ttsLocaleId: 'fj-FJ'),
    AppLanguage(code: 'ty', name: 'Tahitian', nativeName: 'Reo Tahiti', speechLocaleId: 'ty-PF', ttsLocaleId: 'ty-PF'),
    AppLanguage(code: 'tpi', name: 'Tok Pisin', nativeName: 'Tok Pisin', speechLocaleId: 'tpi-PG', ttsLocaleId: 'tpi-PG'),
    AppLanguage(code: 'bi', name: 'Bislama', nativeName: 'Bislama', speechLocaleId: 'bi-VU', ttsLocaleId: 'bi-VU'),
    AppLanguage(code: 'ch', name: 'Chamorro', nativeName: 'Chamoru', speechLocaleId: 'ch-GU', ttsLocaleId: 'ch-GU'),
    AppLanguage(code: 'mh', name: 'Marshallese', nativeName: 'Kajin Majōl', speechLocaleId: 'mh-MH', ttsLocaleId: 'mh-MH'),

    // Africa
    AppLanguage(code: 'ha', name: 'Hausa', nativeName: 'Hausa', speechLocaleId: 'ha-NG', ttsLocaleId: 'ha-NG'),
    AppLanguage(code: 'yo', name: 'Yoruba', nativeName: 'Yorùbá', speechLocaleId: 'yo-NG', ttsLocaleId: 'yo-NG'),
    AppLanguage(code: 'ig', name: 'Igbo', nativeName: 'Igbo', speechLocaleId: 'ig-NG', ttsLocaleId: 'ig-NG'),
    AppLanguage(code: 'ff', name: 'Fulah', nativeName: 'Pulaar', speechLocaleId: 'ff-SN', ttsLocaleId: 'ff-SN'),
    AppLanguage(code: 'wo', name: 'Wolof', nativeName: 'Wolof', speechLocaleId: 'wo-SN', ttsLocaleId: 'wo-SN'),
    AppLanguage(code: 'bm', name: 'Bambara', nativeName: 'Bamanankan', speechLocaleId: 'bm-ML', ttsLocaleId: 'bm-ML'),
    AppLanguage(code: 'ak', name: 'Akan (Twi)', nativeName: 'Twi', speechLocaleId: 'ak-GH', ttsLocaleId: 'ak-GH'),
    AppLanguage(code: 'ee', name: 'Ewe', nativeName: 'Eʋegbe', speechLocaleId: 'ee-GH', ttsLocaleId: 'ee-GH'),
    AppLanguage(code: 'gaa', name: 'Ga', nativeName: 'Gã', speechLocaleId: 'gaa-GH', ttsLocaleId: 'gaa-GH'),
    AppLanguage(code: 'ln', name: 'Lingala', nativeName: 'Lingála', speechLocaleId: 'ln-CD', ttsLocaleId: 'ln-CD'),
    AppLanguage(code: 'kg', name: 'Kongo', nativeName: 'Kikongo', speechLocaleId: 'kg-CD', ttsLocaleId: 'kg-CD'),
    AppLanguage(code: 'rw', name: 'Kinyarwanda', nativeName: 'Ikinyarwanda', speechLocaleId: 'rw-RW', ttsLocaleId: 'rw-RW'),
    AppLanguage(code: 'rn', name: 'Kirundi', nativeName: 'Ikirundi', speechLocaleId: 'rn-BI', ttsLocaleId: 'rn-BI'),
    AppLanguage(code: 'lg', name: 'Luganda', nativeName: 'Luganda', speechLocaleId: 'lg-UG', ttsLocaleId: 'lg-UG'),
    AppLanguage(code: 'luo', name: 'Luo', nativeName: 'Dholuo', speechLocaleId: 'luo-KE', ttsLocaleId: 'luo-KE'),
    AppLanguage(code: 'ki', name: 'Kikuyu', nativeName: 'Gĩkũyũ', speechLocaleId: 'ki-KE', ttsLocaleId: 'ki-KE'),
    AppLanguage(code: 'so', name: 'Somali', nativeName: 'Soomaali', speechLocaleId: 'so-SO', ttsLocaleId: 'so-SO'),
    AppLanguage(code: 'om', name: 'Oromo', nativeName: 'Afaan Oromoo', speechLocaleId: 'om-ET', ttsLocaleId: 'om-ET'),
    AppLanguage(code: 'ti', name: 'Tigrinya', nativeName: 'ትግርኛ', speechLocaleId: 'ti-ER', ttsLocaleId: 'ti-ER', isLatinScript: false),
    AppLanguage(code: 'mg', name: 'Malagasy', nativeName: 'Malagasy', speechLocaleId: 'mg-MG', ttsLocaleId: 'mg-MG'),
    AppLanguage(code: 'ny', name: 'Chichewa', nativeName: 'Chichewa', speechLocaleId: 'ny-MW', ttsLocaleId: 'ny-MW'),
    AppLanguage(code: 'sn', name: 'Shona', nativeName: 'chiShona', speechLocaleId: 'sn-ZW', ttsLocaleId: 'sn-ZW'),
    AppLanguage(code: 'nd', name: 'Northern Ndebele', nativeName: 'isiNdebele', speechLocaleId: 'nd-ZW', ttsLocaleId: 'nd-ZW'),
    AppLanguage(code: 'xh', name: 'Xhosa', nativeName: 'isiXhosa', speechLocaleId: 'xh-ZA', ttsLocaleId: 'xh-ZA'),
    AppLanguage(code: 'st', name: 'Sesotho', nativeName: 'Sesotho', speechLocaleId: 'st-ZA', ttsLocaleId: 'st-ZA'),
    AppLanguage(code: 'tn', name: 'Setswana', nativeName: 'Setswana', speechLocaleId: 'tn-ZA', ttsLocaleId: 'tn-ZA'),
    AppLanguage(code: 'nso', name: 'Sepedi', nativeName: 'Sepedi', speechLocaleId: 'nso-ZA', ttsLocaleId: 'nso-ZA'),
    AppLanguage(code: 'ts', name: 'Tsonga', nativeName: 'Xitsonga', speechLocaleId: 'ts-ZA', ttsLocaleId: 'ts-ZA'),
    AppLanguage(code: 've', name: 'Venda', nativeName: 'Tshivenḓa', speechLocaleId: 've-ZA', ttsLocaleId: 've-ZA'),
    AppLanguage(code: 'ss', name: 'Swati', nativeName: 'siSwati', speechLocaleId: 'ss-ZA', ttsLocaleId: 'ss-ZA'),
    AppLanguage(code: 'kab', name: 'Kabyle', nativeName: 'Taqbaylit', speechLocaleId: 'kab-DZ', ttsLocaleId: 'kab-DZ'),
    AppLanguage(code: 'tzm', name: 'Tamazight', nativeName: 'ⵜⴰⵎⴰⵣⵉⵖⵜ', speechLocaleId: 'tzm-MA', ttsLocaleId: 'tzm-MA', isLatinScript: false),

    // The Americas and the Caribbean
    AppLanguage(code: 'ht', name: 'Haitian Creole', nativeName: 'Kreyòl ayisyen', speechLocaleId: 'ht-HT', ttsLocaleId: 'ht-HT'),
    AppLanguage(code: 'pap', name: 'Papiamento', nativeName: 'Papiamentu', speechLocaleId: 'pap-CW', ttsLocaleId: 'pap-CW'),
    AppLanguage(code: 'jam', name: 'Jamaican Patois', nativeName: 'Patwa', speechLocaleId: 'jam-JM', ttsLocaleId: 'jam-JM'),
    AppLanguage(code: 'srn', name: 'Sranan Tongo', nativeName: 'Sranantongo', speechLocaleId: 'srn-SR', ttsLocaleId: 'srn-SR'),
    AppLanguage(code: 'qu', name: 'Quechua', nativeName: 'Runasimi', speechLocaleId: 'qu-PE', ttsLocaleId: 'qu-PE'),
    AppLanguage(code: 'ay', name: 'Aymara', nativeName: 'Aymar aru', speechLocaleId: 'ay-BO', ttsLocaleId: 'ay-BO'),
    AppLanguage(code: 'gn', name: 'Guarani', nativeName: 'Avañeẽ', speechLocaleId: 'gn-PY', ttsLocaleId: 'gn-PY'),
    AppLanguage(code: 'nah', name: 'Nahuatl', nativeName: 'Nāhuatl', speechLocaleId: 'nah-MX', ttsLocaleId: 'nah-MX'),
    AppLanguage(code: 'quc', name: "K'iche'", nativeName: "K'iche'", speechLocaleId: 'quc-GT', ttsLocaleId: 'quc-GT'),
    AppLanguage(code: 'chr', name: 'Cherokee', nativeName: 'ᏣᎳᎩ', speechLocaleId: 'chr-US', ttsLocaleId: 'chr-US', isLatinScript: false),
    AppLanguage(code: 'nv', name: 'Navajo', nativeName: 'Diné bizaad', speechLocaleId: 'nv-US', ttsLocaleId: 'nv-US'),
    AppLanguage(code: 'iu', name: 'Inuktitut', nativeName: 'ᐃᓄᒃᑎᑐᑦ', speechLocaleId: 'iu-CA', ttsLocaleId: 'iu-CA', isLatinScript: false),
    AppLanguage(code: 'cr', name: 'Cree', nativeName: 'ᓀᐦᐃᔭᐍᐏᐣ', speechLocaleId: 'cr-CA', ttsLocaleId: 'cr-CA', isLatinScript: false),
    AppLanguage(code: 'oj', name: 'Ojibwe', nativeName: 'Anishinaabemowin', speechLocaleId: 'oj-CA', ttsLocaleId: 'oj-CA'),
  ];

  /// The slice with broad on-device speech recognition and TTS voices — the
  /// only languages a voice-driven app can responsibly offer.
  static List<AppLanguage> get voiceCapable =>
      all.where((l) => l.hasVoiceSupport).toList(growable: false);

  /// Resolves [code] to a language, falling back to the first entry
  /// (English) for an unknown or legacy code rather than throwing — stored
  /// documents outlive catalog edits.
  static AppLanguage byCode(String code) => all.firstWhere(
        (l) => l.code == code,
        orElse: () => all.first,
      );

  /// Case-insensitive search over English name, endonym and code, for the
  /// picker's search field. An empty query returns [pool] unchanged.
  static List<AppLanguage> search(String query, {List<AppLanguage>? pool}) {
    final candidates = pool ?? all;
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return List.of(candidates, growable: false);
    return candidates
        .where((l) =>
            l.name.toLowerCase().contains(needle) ||
            l.nativeName.toLowerCase().contains(needle) ||
            l.code.toLowerCase().contains(needle))
        .toList(growable: false);
  }
}
