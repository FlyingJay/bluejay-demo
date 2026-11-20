import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/csv_import.dart';

void main() {
  group('parseCsvTable', () {
    test('reads headers and rows with file line numbers', () {
      final table = parseCsvTable('﻿Code, Name \r\n007,"Acme, Inc."\r\n\r\n  ,  \nX,Y\n');
      expect(table.error, isNull);
      expect(table.headers, ['Code', 'Name']);
      expect(table.rows.map((r) => r.line), [2, 5]);
      expect(table.rows.first.cells, ['007', 'Acme, Inc.']);
    });

    test('reports empty input', () {
      expect(parseCsvTable('').error, isNotNull);
      expect(parseCsvTable(' \n ').error, isNotNull);
    });
  });

  group('guessCsvColumns', () {
    const fields = [
      CsvImportField('name', 'Name', aliases: ['full name']),
      CsvImportField('email', 'Email', aliases: ['e-mail address']),
      CsvImportField('alsoEmail', 'Work email', aliases: ['email']),
      CsvImportField('phone', 'Phone'),
    ];

    test('matches keys, labels and aliases once normalized', () {
      final mapping = guessCsvColumns(['FULL_NAME', 'E-mail Address', 'Notes'], fields);
      expect(mapping, {'name': 0, 'email': 1, 'alsoEmail': null, 'phone': null});
    });

    test('a column feeds only the first field that claims it', () {
      final mapping = guessCsvColumns(['Email', 'email'], fields);
      expect(mapping['email'], 0);
      expect(mapping['alsoEmail'], 1);
    });

    test('blank headers never match', () {
      expect(guessCsvColumns(['', ' '], fields).values.whereType<int>(), isEmpty);
    });
  });
}
