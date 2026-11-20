import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/search_prefixes.dart';

/// The cases functions/_search_prefixes.test.js checks too: a record the
/// server indexes is found by the terms this side builds.
Map<String, dynamic> _cases() => jsonDecode(
      File('../../security/search_prefixes_cases.json').readAsStringSync(),
    ) as Map<String, dynamic>;

List<String> _strings(Object? list) => [for (final v in (list as List? ?? const [])) v as String];

void main() {
  test('records index exactly as the JS function does', () {
    for (final c in _cases()['records'] as List) {
      final config = c['config'] as Map<String, dynamic>;
      expect(
        searchPrefixesFor(
          Map<String, dynamic>.from(c['data'] as Map),
          fields: _strings(config['fields']),
          digitFields: _strings(config['digitFields']),
          hiddenWhen: _strings(config['hiddenWhen']),
        ),
        _strings(c['prefixes']),
        reason: c['name'] as String,
      );
    }
  });

  test('queries split into the same terms as the JS function', () {
    for (final c in _cases()['queries'] as List) {
      final terms = searchTerms(c['query'] as String);
      expect(terms, _strings(c['terms']), reason: c['query'] as String);
      expect(primarySearchTerm(terms), c['primary'], reason: c['query'] as String);
    }
  });

  test('a record matches when every term is one of its prefixes', () {
    final prefixes = searchPrefixesFor(
      {'name': 'José Smith-Jones', 'phones': ['+1 (604) 555-1234']},
      fields: ['name', 'phones'],
      digitFields: ['phones'],
    );
    expect(matchesAllSearchTerms(prefixes, searchTerms('jose smi')), isTrue);
    expect(matchesAllSearchTerms(prefixes, searchTerms('604 555-1234')), isTrue);
    expect(matchesAllSearchTerms(prefixes, searchTerms('jose brown')), isFalse);
    expect(matchesAllSearchTerms(null, ['jo']), isFalse);
  });
}
