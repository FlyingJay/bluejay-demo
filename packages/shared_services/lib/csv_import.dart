import 'dart:convert';

import 'package:csv/csv.dart';

/// Reading spreadsheet uploads: [parseCsvTable] splits a CSV into its header
/// and data rows, and [guessCsvColumns] proposes which column feeds each of
/// an import's fields, for a column-mapping step the person can correct.
///
/// The writing side is `csv_export.dart`. `event_planner`
/// (attendee_csv.dart) still parses its own uploads and could move here.

/// One data line of a CSV, with the line number a person sees in their file.
class CsvRow {
  const CsvRow(this.line, this.cells);

  final int line;
  final List<String> cells;

  /// The trimmed cell at [index], or '' when the column is absent.
  String cell(int? index) => index == null || index < 0 || index >= cells.length ? '' : cells[index];
}

/// A CSV split into its header line and non-blank data rows.
class CsvTable {
  const CsvTable({this.headers = const [], this.rows = const [], this.error});

  const CsvTable.failed(String message) : this(error: message);

  final List<String> headers;
  final List<CsvRow> rows;

  /// Why the file couldn't be read at all; null when it could.
  final String? error;

  /// Index of the first header matching any of [aliases] once normalized.
  int? column(Iterable<String> aliases) {
    final wanted = aliases.map(normalizeCsvHeader).toSet();
    final index = headers.indexWhere((h) => wanted.contains(normalizeCsvHeader(h)));
    return index == -1 ? null : index;
  }
}

/// `Parent Code`, `parent_code` and `PARENT-CODE` all become `parentcode`.
String normalizeCsvHeader(String header) => header.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Reads CSV text with any line ending, an optional byte-order mark and
/// quoted cells. Cells are trimmed strings and numbers are never
/// reinterpreted, so codes like `007` survive. Blank lines are skipped but
/// still counted, so [CsvRow.line] matches the file.
CsvTable parseCsvTable(String text) {
  final normalized = text.replaceFirst('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.trim().isEmpty) return const CsvTable.failed('The file is empty.');

  final List<List<dynamic>> table;
  try {
    table = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(normalized);
  } catch (_) {
    return const CsvTable.failed('The file could not be read as CSV.');
  }
  if (table.isEmpty) return const CsvTable.failed('The file is empty.');

  String clean(Object? value) => (value ?? '').toString().trim();
  final rows = <CsvRow>[];
  for (var i = 1; i < table.length; i++) {
    final cells = table[i].map(clean).toList();
    if (cells.every((c) => c.isEmpty)) continue;
    rows.add(CsvRow(i + 1, cells));
  }
  return CsvTable(headers: table.first.map(clean).toList(), rows: rows);
}

/// Decodes picked file bytes as UTF-8, tolerating stray invalid bytes.
String decodeCsvBytes(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// A field an import can fill from a column: its [key], the [label] shown in
/// the mapping step, and the header spellings ([aliases], compared with
/// [normalizeCsvHeader]) that select it automatically.
class CsvImportField {
  const CsvImportField(this.key, this.label, {this.aliases = const []});

  final String key;
  final String label;
  final List<String> aliases;
}

/// The column (an index into [headers]) each of [fields] most likely comes
/// from: a header equal to the field's key, label or one of its aliases,
/// once normalized. Each column feeds at most one field (the first field
/// that claims it); a field with no match maps to null.
Map<String, int?> guessCsvColumns(List<String> headers, List<CsvImportField> fields) {
  final normalized = headers.map(normalizeCsvHeader).toList();
  final taken = <int>{};
  final mapping = <String, int?>{};
  for (final field in fields) {
    final names = {field.key, field.label, ...field.aliases}.map(normalizeCsvHeader).toSet();
    int? found;
    for (var i = 0; i < normalized.length; i++) {
      if (!taken.contains(i) && normalized[i].isNotEmpty && names.contains(normalized[i])) {
        found = i;
        break;
      }
    }
    if (found != null) taken.add(found);
    mapping[field.key] = found;
  }
  return mapping;
}
