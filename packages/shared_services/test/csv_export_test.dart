import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/csv_export.dart';

void main() {
  test('cells are quoted only when needed, with quotes doubled', () {
    expect(csvCell('plain'), 'plain');
    expect(csvCell('a,b'), '"a,b"');
    expect(csvCell('say "hi"'), '"say ""hi"""');
    expect(csvCell('two\nlines'), '"two\nlines"');
    expect(csvCell(null), '');
    expect(csvCell(''), '');
  });

  test('text that would run as a formula is neutralized; numbers are not', () {
    expect(csvCell('=SUM(A1)'), "'=SUM(A1)");
    expect(csvCell('+1'), "'+1");
    expect(csvCell('-x'), "'-x");
    expect(csvCell('@cmd'), "'@cmd");
    expect(csvCell('=a,b'), '"\'=a,b"');
    expect(csvCell(-1.5), '-1.5');
    expect(csvCell(-3), '-3');
  });

  test('numbers are written so spreadsheets parse them', () {
    expect(csvCell(42), '42');
    expect(csvCell(42.0), '42');
    expect(csvCell(0.25), '0.25');
    expect(csvCell(3.3e-7), '0.00000033');
    expect(csvCell(double.nan), '');
    expect(csvCell(double.infinity), '');
  });

  test('encodeCsv joins rows with CRLF and csvBytes adds a BOM', () {
    final csv = encodeCsv([
      ['name', 'cost'],
      ['Ünïcode, Inc', 1.25],
    ]);
    expect(csv, 'name,cost\r\n"Ünïcode, Inc",1.25\r\n');
    final bytes = csvBytes(csv);
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes.sublist(3)), csv);
  });

  test('csvFileName is safe and ends in .csv', () {
    expect(csvFileName('usage 2026-11'), 'usage 2026-11.csv');
    expect(csvFileName('a/b:c'), 'a_b_c.csv');
    expect(csvFileName('x.CSV'), 'x.CSV');
    expect(csvFileName('  '), 'export.csv');
  });
}
