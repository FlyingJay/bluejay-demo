import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:flutter/widgets.dart';

import 'save_bytes.dart';

/// Building and saving CSV files from app data.
///
/// [encodeCsv] is RFC 4180 (the `csv` package's [ListToCsvConverter]: CRLF
/// line endings, fields quoted only when they need it). On top of that it
/// neutralizes spreadsheet formulas in text cells: a cell that
/// starts with `=`, `+`, `-`, `@`, tab or CR is prefixed with `'`, so a name
/// or label someone typed can't run as a formula when the file is opened in
/// Excel or Sheets (CSV injection). Numbers are written as numbers and never
/// prefixed, so negative values stay numeric.
///
/// [downloadCsv] saves the result: a browser download on web, the platform
/// share sheet elsewhere (save_bytes.dart, which writes no app data, so an
/// app that reaches its data only through callables can export too).
///
/// Follow-up: `forms` (form_exporter.dart), `bordereau_report`
/// (bordereau_csv_export.dart), `event_planner` (attendee_csv.dart) and
/// `security_audit` (violations_export.dart) still hand-roll CSV escaping
/// and their own download helpers; they should move to this library.

const _formulaTriggers = ['=', '+', '-', '@', '\t', '\r'];

const _converter = ListToCsvConverter(eol: '\r\n');

/// One cell's text before quoting: `null` is empty; numbers are written
/// as-is (non-finite numbers are empty); everything else is `toString()`ed
/// and formula-neutralized. Quoting is [ListToCsvConverter]'s job.
String csvText(Object? value) {
  if (value == null) return '';
  if (value is num) return value.isFinite ? _formatNumber(value) : '';
  final text = value.toString();
  return text.isNotEmpty && _formulaTriggers.any(text.startsWith) ? "'$text" : text;
}

/// One cell as it appears in the file (formula-neutralized and quoted if
/// it contains a delimiter, quote or line break).
String csvCell(Object? value) => _converter.convert([
      [csvText(value)],
    ]);

/// Integers without a trailing `.0`; doubles in full precision (no
/// exponent for ordinary magnitudes, so spreadsheets parse them).
String _formatNumber(num v) {
  if (v is int) return v.toString();
  if (v == v.truncateToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final s = v.toString();
  if (!s.contains('e')) return s;
  // Small unit prices (3.3e-7): spell them out so every spreadsheet reads a
  // number, trimming the trailing zeros toStringAsFixed adds.
  final fixed = v.toStringAsFixed(20).replaceFirst(RegExp(r'0+$'), '');
  return fixed.endsWith('.') ? fixed.substring(0, fixed.length - 1) : fixed;
}

/// [rows] (header first) as RFC 4180 CSV text (via the `csv` package),
/// every row CRLF-terminated.
String encodeCsv(Iterable<Iterable<Object?>> rows) {
  final cells = [
    for (final row in rows) [for (final cell in row) csvText(cell)],
  ];
  if (cells.isEmpty) return '';
  return '${_converter.convert(cells)}\r\n';
}

/// UTF-8 bytes of [csv] with a byte-order mark, which makes Excel read
/// non-ASCII names as UTF-8 instead of the system code page.
Uint8List csvBytes(String csv) => Uint8List.fromList(utf8.encode('﻿$csv'));

/// [fileName] with characters file systems reject replaced and `.csv`
/// appended if missing.
String csvFileName(String fileName) {
  final cleaned = fileName.replaceAll(RegExp(r'[\\/\x00-\x1f<>:"|?*]'), '_').trim();
  final base = cleaned.isEmpty ? 'export' : cleaned;
  return base.toLowerCase().endsWith('.csv') ? base : '$base.csv';
}

/// Saves [rows] as a CSV named [fileName]: a browser download on web, the
/// share sheet on mobile/desktop. Pass the [BuildContext] of the control the
/// user tapped (iPad anchors the share popover to it).
Future<void> downloadCsv(BuildContext context, String fileName, Iterable<Iterable<Object?>> rows) {
  return saveBytes(
    context,
    csvBytes(encodeCsv(rows)),
    csvFileName(fileName),
    mimeType: 'text/csv',
  );
}
