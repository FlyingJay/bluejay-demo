/// Record search's word prefixes (plans/record-search/OVERVIEW.md §5): the
/// Dart twin of functions/_search_prefixes.js. The server indexes each
/// searchable record's fields into `searchPrefixes` with that file; a search
/// splits its query into terms with this one. Both are tested against
/// security/search_prefixes_cases.json, so change them together.
library;

/// The field the server keeps on every searchable record.
const String searchPrefixesField = 'searchPrefixes';

const int _minPrefix = 2;
const int _maxPrefix = 10;

/// Most prefixes one record carries.
const int maxSearchPrefixes = 80;

const Map<String, String> _folds = {
  'a': 'àáâãäåāăą', 'c': 'çćĉċč', 'd': 'ďđð', 'e': 'èéêëēĕėęě', 'g': 'ĝğġģ', 'h': 'ĥħ',
  'i': 'ìíîïĩīĭįı', 'j': 'ĵ', 'k': 'ķ', 'l': 'ĺļľŀł', 'n': 'ñńņňŉ', 'o': 'òóôõöøōŏő',
  'r': 'ŕŗř', 's': 'śŝşš', 't': 'ţťŧ', 'u': 'ùúûüũūŭůűų', 'w': 'ŵ', 'y': 'ýÿŷ', 'z': 'źżž',
};

final Map<String, String> _foldMap = {
  for (final entry in _folds.entries)
    for (final ch in entry.value.runes) String.fromCharCode(ch): entry.key,
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
  'þ': 'th',
};

final RegExp _marks = RegExp(r'\p{M}', unicode: true);
final RegExp _separators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _digits = RegExp(r'^[0-9]+$');

/// [text] lowercased, with combining marks dropped and accents folded.
String foldSearchText(String text) {
  final lower = text.toLowerCase().replaceAll(_marks, '');
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    out.write(_foldMap[ch] ?? ch);
  }
  return out.toString();
}

/// The words of [text], folded, in order.
List<String> searchWords(String text) =>
    foldSearchText(text).split(_separators).where((w) => w.isNotEmpty).toList();

int _length(String s) => s.runes.length;

String _take(String s, int n) => String.fromCharCodes(s.runes.take(n));

List<String> _prefixesOf(String word) => [
      for (var n = _minPrefix; n <= _length(word) && n <= _maxPrefix; n++) _take(word, n),
    ];

List<String> _digitTails(String text) {
  final runs = searchWords(text).where(_digits.hasMatch).toList();
  return [
    for (var i = 0; i < runs.length; i++) runs.sublist(i).join(),
  ].where((tail) => tail.length >= _minPrefix).toList();
}

Object? _readPath(Map<String, dynamic> data, String path) {
  Object? value = data;
  for (final key in path.split('.')) {
    if (value is! Map) return null;
    value = value[key];
  }
  return value;
}

List<String> _valuesAt(Map<String, dynamic> data, String path) {
  final value = _readPath(data, path);
  final list = value is List ? value : [value];
  return [
    for (final v in list)
      if (v is String) v else if (v is num) '$v',
  ];
}

/// The searchPrefixes the server writes for [data] under a `search` block
/// ([fields], [digitFields], [hiddenWhen]); the client only reads them.
/// Here so the Dart and JS functions are tested against the same cases.
List<String> searchPrefixesFor(
  Map<String, dynamic> data, {
  required List<String> fields,
  List<String> digitFields = const [],
  List<String> hiddenWhen = const [],
}) {
  if (data['deletedAt'] != null) return const [];
  if (hiddenWhen.any((f) => _readPath(data, f) == true)) return const [];
  final out = <String>{};
  void add(Iterable<String> prefixes) {
    for (final p in prefixes) {
      if (out.length >= maxSearchPrefixes) return;
      out.add(p);
    }
  }

  for (final field in fields) {
    for (final value in _valuesAt(data, field)) {
      for (final word in searchWords(value)) {
        add(_prefixesOf(word));
      }
      if (digitFields.contains(field)) {
        for (final tail in _digitTails(value)) {
          add(_prefixesOf(tail));
        }
      }
    }
  }
  return out.toList();
}

/// The terms [query] searches for: its folded words of at least two
/// characters, each cut to ten, without repeats. Empty when nothing is
/// long enough to search.
List<String> searchTerms(String query) {
  final out = <String>[];
  for (final word in searchWords(query)) {
    if (_length(word) < _minPrefix) continue;
    final term = _take(word, _maxPrefix);
    if (!out.contains(term)) out.add(term);
  }
  return out;
}

/// The term a search asks Firestore for: the longest (the most selective),
/// the first of equals. Null for none.
String? primarySearchTerm(List<String> terms) {
  String? best;
  for (final t in terms) {
    if (best == null || _length(t) > _length(best)) best = t;
  }
  return best;
}

/// Whether a record carrying [prefixes] matches every one of [terms].
bool matchesAllSearchTerms(Object? prefixes, List<String> terms) {
  final set = prefixes is List ? prefixes.whereType<String>().toSet() : const <String>{};
  return terms.every(set.contains);
}
