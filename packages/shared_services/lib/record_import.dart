import 'csv_import.dart';
import 'generated/collection_policies.g.dart';

export 'csv_import.dart';

/// Spreadsheet import for any app's list (plans/spreadsheet-import).
///
/// An app declares what can be imported as an [ImportSpec] and registers it
/// ([registerImportSpec]); `shared_ui`'s `record_import_flow.dart` is the one
/// screen that picks the file, matches columns, previews and writes, and
/// `record_import_store.dart` writes through `ScopedCollection` with an
/// `import_batches` record that undo walks.
///
/// This file is pure (no Firestore), so the field parsers and the planner
/// are unit-tested. Three things are contracts that stay stable as parts
/// change: the spec, the registry ([ImportSpec.id]s are never reused or
/// renamed, because batch records name them) and the batch record. The
/// parts behind interfaces can be swapped without touching any spec: the
/// file reader ([ImportFileReader]; CSV today), the column matcher
/// ([ImportColumnMatcher]; header aliases today) and the writer.

/// Most data rows one import reads. Larger files wait for a server writer.
const int kMaxImportRows = 5000;

/// Largest file one import reads.
const int kMaxImportBytes = 5 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Reading files and matching columns (the swappable parts)
// ---------------------------------------------------------------------------

/// Turns a picked file into a table of text cells. Every reader produces
/// the same [CsvTable] (a header row and numbered data rows), so the
/// matcher, planner and screen never know the format.
abstract class ImportFileReader {
  const ImportFileReader();

  /// File extensions the picker offers, without the dot.
  List<String> get extensions;

  /// How the format is named to people ("CSV").
  String get formatLabel;

  bool accepts(String fileName) => extensions.any((e) => fileName.toLowerCase().endsWith('.$e'));

  CsvTable read(List<int> bytes);
}

/// CSV files, through [parseCsvTable].
class CsvImportReader extends ImportFileReader {
  const CsvImportReader();

  @override
  List<String> get extensions => const ['csv'];

  @override
  String get formatLabel => 'CSV';

  @override
  CsvTable read(List<int> bytes) => parseCsvTable(decodeCsvBytes(bytes));
}

/// The readers the import screen offers, first one preferred.
const List<ImportFileReader> kImportReaders = [CsvImportReader()];

/// Proposes which column (an index into the table's headers) feeds each of
/// a spec's fields; the person confirms or corrects it. Asynchronous so a
/// matcher can ask a service.
abstract class ImportColumnMatcher {
  const ImportColumnMatcher();

  Future<Map<String, int?>> match(CsvTable table, ImportSpec spec);
}

/// Matches headers to a field's key, label or aliases ([guessCsvColumns]).
class AliasColumnMatcher extends ImportColumnMatcher {
  const AliasColumnMatcher();

  @override
  Future<Map<String, int?>> match(CsvTable table, ImportSpec spec) async =>
      guessCsvColumns(table.headers, spec.csvFields);
}

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

enum ImportFieldType {
  text,
  integer,
  decimal,

  /// An amount, stored as whole cents.
  money,
  date,
  yesNo,

  /// One of a fixed or settings-driven list ([ImportField.choices]).
  choice,

  /// Several values in one cell, split on `;`, `,`, `|` or line breaks.
  list,
  email,
  phone,

  /// A group member, written in the file as their sign-in email; the value
  /// is their uid.
  member,

  /// Another record, written in the file by name; the value is its id
  /// ([ImportField.lookup]).
  lookup,
}

/// One allowed value of a choice field: the stored [value], the [label]
/// people see, and other spellings a file may use.
class ImportChoice {
  const ImportChoice(this.value, this.label, {this.aliases = const []});

  final String value;
  final String label;
  final List<String> aliases;
}

/// The result of parsing one cell: a value, nothing (blank), or a problem.
class ImportParsed {
  const ImportParsed(this.value) : error = null;

  const ImportParsed.blank()
      : value = null,
        error = null;

  const ImportParsed.error(String this.error) : value = null;

  final Object? value;

  /// Why the cell couldn't be read, in words for the person importing.
  final String? error;
}

/// Checks a parsed value; returns why it's wrong, or null.
typedef ImportValidator = String? Function(Object value);

/// A field a column can fill. The [type] parses the cell and words the
/// error; [validate] adds the app's own rule (non-negative, a maximum).
class ImportField {
  const ImportField(
    this.key,
    this.label,
    this.type, {
    this.aliases = const [],
    this.required = false,
    this.validate,
    this.choices,
    this.lookup,
    this.example = '',
    this.help,
  });

  const ImportField.text(String key, String label,
      {List<String> aliases = const [], bool required = false, ImportValidator? validate, String example = ''})
      : this(key, label, ImportFieldType.text,
            aliases: aliases, required: required, validate: validate, example: example);

  const ImportField.integer(String key, String label,
      {List<String> aliases = const [], bool required = false, ImportValidator? validate, String example = ''})
      : this(key, label, ImportFieldType.integer,
            aliases: aliases, required: required, validate: validate, example: example);

  const ImportField.decimal(String key, String label,
      {List<String> aliases = const [], bool required = false, ImportValidator? validate, String example = ''})
      : this(key, label, ImportFieldType.decimal,
            aliases: aliases, required: required, validate: validate, example: example);

  const ImportField.money(String key, String label,
      {List<String> aliases = const [], bool required = false, ImportValidator? validate, String example = ''})
      : this(key, label, ImportFieldType.money,
            aliases: aliases, required: required, validate: validate, example: example);

  const ImportField.date(String key, String label,
      {List<String> aliases = const [], bool required = false, ImportValidator? validate, String example = ''})
      : this(key, label, ImportFieldType.date,
            aliases: aliases, required: required, validate: validate, example: example);

  const ImportField.yesNo(String key, String label,
      {List<String> aliases = const [], bool required = false, String example = ''})
      : this(key, label, ImportFieldType.yesNo, aliases: aliases, required: required, example: example);

  const ImportField.choice(String key, String label,
      {required List<ImportChoice> Function(ImportContext ctx) choices,
      List<String> aliases = const [],
      bool required = false,
      String example = ''})
      : this(key, label, ImportFieldType.choice,
            aliases: aliases, required: required, choices: choices, example: example);

  const ImportField.list(String key, String label,
      {List<String> aliases = const [], bool required = false, String example = ''})
      : this(key, label, ImportFieldType.list, aliases: aliases, required: required, example: example);

  const ImportField.email(String key, String label,
      {List<String> aliases = const [], bool required = false, String example = ''})
      : this(key, label, ImportFieldType.email, aliases: aliases, required: required, example: example);

  const ImportField.phone(String key, String label,
      {List<String> aliases = const [], bool required = false, String example = ''})
      : this(key, label, ImportFieldType.phone, aliases: aliases, required: required, example: example);

  const ImportField.member(String key, String label,
      {List<String> aliases = const [], bool required = false, String example = ''})
      : this(key, label, ImportFieldType.member, aliases: aliases, required: required, example: example);

  const ImportField.lookup(String key, String label,
      {required Map<String, String> Function(ImportContext ctx) lookup,
      List<String> aliases = const [],
      bool required = false,
      String example = ''})
      : this(key, label, ImportFieldType.lookup,
            aliases: aliases, required: required, lookup: lookup, example: example);

  /// The key `build` reads the value under. Usually the record's own field
  /// name, so an export column maps back to it.
  final String key;
  final String label;
  final ImportFieldType type;
  final List<String> aliases;

  /// A row without a valid value here is left out whole.
  final bool required;
  final ImportValidator? validate;

  /// A choice field's allowed values.
  final List<ImportChoice> Function(ImportContext ctx)? choices;

  /// A lookup field's records: normalized name ([importKeyOf]) to id.
  final Map<String, String> Function(ImportContext ctx)? lookup;

  /// The value the downloadable template shows for this field.
  final String example;

  /// A short line under the field in the matching step.
  final String? help;

  /// Parses [raw] (a trimmed cell). [dayFirst] reads `3/4/2026` as 3 April;
  /// the planner sets it per column when any date in it only reads that way.
  ImportParsed parse(String raw, ImportContext ctx, {bool dayFirst = false}) {
    final text = stripExportQuote(raw).trim();
    if (text.isEmpty) return const ImportParsed.blank();
    final parsed = _parseType(text, ctx, dayFirst: dayFirst);
    final value = parsed.value;
    if (value == null || validate == null) return parsed;
    final problem = validate!(value);
    return problem == null ? parsed : ImportParsed.error(problem);
  }

  ImportParsed _parseType(String text, ImportContext ctx, {required bool dayFirst}) {
    switch (type) {
      case ImportFieldType.text:
        return ImportParsed(text);
      case ImportFieldType.integer:
        final n = parseImportNumber(text);
        if (n == null || n != n.roundToDouble()) return ImportParsed.error('"$text" is not a whole number');
        return ImportParsed(n.round());
      case ImportFieldType.decimal:
        final n = parseImportNumber(text);
        return n == null ? ImportParsed.error('"$text" is not a number') : ImportParsed(n);
      case ImportFieldType.money:
        final cents = parseImportMoneyCents(text);
        return cents == null ? ImportParsed.error('"$text" is not an amount') : ImportParsed(cents);
      case ImportFieldType.date:
        final date = parseImportDate(text, dayFirst: dayFirst);
        return date == null ? ImportParsed.error('"$text" is not a date (try 2026-03-31)') : ImportParsed(date);
      case ImportFieldType.yesNo:
        final b = parseImportYesNo(text);
        return b == null ? ImportParsed.error('"$text" is not yes or no') : ImportParsed(b);
      case ImportFieldType.choice:
        final options = choices?.call(ctx) ?? const <ImportChoice>[];
        final wanted = importKeyOf(text);
        for (final o in options) {
          if ({o.value, o.label, ...o.aliases}.map(importKeyOf).contains(wanted)) return ImportParsed(o.value);
        }
        final names = options.take(6).map((o) => o.label).join(', ');
        return ImportParsed.error('"$text" is not one of: $names${options.length > 6 ? '…' : ''}');
      case ImportFieldType.list:
        final items = splitImportList(text);
        return items.isEmpty ? const ImportParsed.blank() : ImportParsed(items);
      case ImportFieldType.email:
        return looksLikeImportEmail(text)
            ? ImportParsed(text.toLowerCase())
            : ImportParsed.error('"$text" is not an email address');
      case ImportFieldType.phone:
        return RegExp(r'\d').allMatches(text).length >= 3
            ? ImportParsed(text)
            : ImportParsed.error('"$text" is not a phone number');
      case ImportFieldType.member:
        final uid = ctx.memberEmails[text.toLowerCase()];
        return uid == null ? ImportParsed.error('$text is not a member of this group') : ImportParsed(uid);
      case ImportFieldType.lookup:
        final id = (lookup?.call(ctx) ?? const {})[importKeyOf(text)];
        return id == null ? ImportParsed.error('No ${label.toLowerCase()} named "$text"') : ImportParsed(id);
    }
  }
}

/// Lower-cased and trimmed with inner spaces collapsed: how names, codes
/// and duplicate keys are compared.
String importKeyOf(String text) => text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// [cell] without the leading `'` csv_export.dart adds to text that would
/// start a spreadsheet formula, so an exported file imports cleanly.
String stripExportQuote(String cell) =>
    cell.length > 1 && cell.startsWith("'") && const ['=', '+', '-', '@', '\t', '\r'].contains(cell[1])
        ? cell.substring(1)
        : cell;

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

bool looksLikeImportEmail(String text) => _emailPattern.hasMatch(text.trim());

/// A cell holding several values: split on `;`, `,`, `|` and line breaks,
/// trimmed, blanks dropped, repeats (case-insensitive) dropped.
List<String> splitImportList(String text) {
  final seen = <String>{};
  return [
    for (final part in text.split(RegExp(r'[;,|\n]')))
      if (part.trim().isNotEmpty && seen.add(part.trim().toLowerCase())) part.trim(),
  ];
}

/// A number as spreadsheets write it: `1,234.5`, `1 234`, `-3`, `(3)` for
/// negative, `12%` as 12. Null when it isn't one.
double? parseImportNumber(String text) {
  var t = text.trim().replaceAll(RegExp(r'[\s,_]'), '').replaceAll('%', '');
  var negative = false;
  if (t.startsWith('(') && t.endsWith(')')) {
    negative = true;
    t = t.substring(1, t.length - 1);
  }
  final n = double.tryParse(t);
  if (n == null || !n.isFinite) return null;
  return negative ? -n : n;
}

/// An amount in whole cents: currency symbols and codes, thousands
/// separators and accounting brackets are allowed (`$1,234.50`, `CAD 12`,
/// `(4.00)`). Rounded to the cent.
int? parseImportMoneyCents(String text) {
  final stripped = text.trim().replaceAll(RegExp(r'[A-Za-z$€£¥₹]'), '');
  final n = parseImportNumber(stripped);
  return n == null ? null : (n * 100).round();
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// A date as spreadsheets write it: `2026-03-31` (with an optional time,
/// which is dropped), `2026/3/31`, `31 Mar 2026`, `March 31, 2026`, or
/// `3/31/2026`. Slash dates with the year last are month first, unless
/// [dayFirst]. Returns the local calendar date at midnight, or null.
DateTime? parseImportDate(String text, {bool dayFirst = false}) {
  final t = text.trim();
  DateTime? valid(int y, int m, int d) {
    if (y < 100) y += 2000;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y, m, d);
    return date.month == m && date.day == d ? date : null;
  }

  var match = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[T ].*)?$').firstMatch(t);
  if (match != null) return valid(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));

  match = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})$').firstMatch(t);
  if (match != null) {
    final a = int.parse(match[1]!), b = int.parse(match[2]!), y = int.parse(match[3]!);
    return dayFirst || a > 12 ? valid(y, b, a) : valid(y, a, b);
  }

  final words = t.toLowerCase().replaceAll(',', ' ').split(RegExp(r'[\s-]+')).where((w) => w.isNotEmpty).toList();
  if (words.length == 3) {
    int? month(String w) => w.length >= 3 ? _months[w.substring(0, 3)] : null;
    final m1 = month(words[0]), m2 = month(words[1]);
    final first = int.tryParse(words[0]), second = int.tryParse(words[1]), year = int.tryParse(words[2]);
    if (year != null && m1 != null && second != null) return valid(year, m1, second);
    if (year != null && m2 != null && first != null) return valid(year, m2, first);
  }
  return null;
}

/// Whether [text] is a slash date that only reads day first (`31/3/2026`).
bool isDayFirstDate(String text) {
  final match = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})$').firstMatch(text.trim());
  return match != null && int.parse(match[1]!) > 12;
}

/// `yes`, `y`, `true`, `1`, `x` and `✓` are true; `no`, `n`, `false`, `0`
/// are false.
bool? parseImportYesNo(String text) {
  final t = text.trim().toLowerCase();
  if (const {'yes', 'y', 'true', 't', '1', 'x', '✓', '✔', 'on'}.contains(t)) return true;
  if (const {'no', 'n', 'false', 'f', '0', 'off', '-'}.contains(t)) return false;
  return null;
}

// ---------------------------------------------------------------------------
// The spec
// ---------------------------------------------------------------------------

/// A record already in the list (or a parent's subcollection).
class ImportExisting {
  const ImportExisting(this.id, this.data);

  final String id;
  final Map<String, dynamic> data;
}

/// Fields that identify an existing record. A row matches a record when
/// every field of the key has a value and they're equal once normalized
/// ([importKeyOf]); a list-valued field matches on any of its entries.
class ImportKey {
  const ImportKey(this.fields, {this.label});

  final List<String> fields;

  /// How a duplicate is described ("Same SKU as line 4"); defaults to the
  /// fields' labels.
  final String? label;
}

/// How undo takes away a record the import created.
class ImportRemove {
  const ImportRemove.delete()
      : field = null,
        mode = ImportRemoveMode.delete;

  /// Sets `deletedAt` (ScopedCollection.softDelete).
  const ImportRemove.softDelete()
      : field = null,
        mode = ImportRemoveMode.softDelete;

  /// Sets [field] to true.
  const ImportRemove.archive(String this.field) : mode = ImportRemoveMode.archive;

  final ImportRemoveMode mode;
  final String? field;

  /// Whether a record removed this way still counts as in the list.
  bool isLive(Map<String, dynamic> data) => switch (mode) {
        ImportRemoveMode.delete => true,
        ImportRemoveMode.softDelete => data['deletedAt'] == null,
        ImportRemoveMode.archive => data[field] != true,
      };
}

enum ImportRemoveMode { delete, softDelete, archive }

/// A choice the person makes for the whole import, beyond the shared
/// duplicate choice (Contacts: the relationship for rows without one).
class ImportOption {
  const ImportOption.choice(
    this.key,
    this.label, {
    required List<ImportChoice> this.choices,
    this.help,
    this.initial,
  }) : isToggle = false;

  const ImportOption.toggle(this.key, this.label, {this.help, bool this.initial = false})
      : choices = null,
        isToggle = true;

  final String key;
  final String label;
  final String? help;
  final bool isToggle;

  /// A choice option's values; a null value in the list means "none".
  final List<ImportChoice>? choices;

  /// The starting value: a choice's value (or null), or a toggle's bool.
  final Object? initial;
}

/// What the planner and the spec's hooks can see.
class ImportContext {
  const ImportContext({
    this.existing = const [],
    this.memberEmails = const {},
    this.options = const {},
    this.data = const {},
    this.parentId,
    this.uid = '',
  });

  /// The records already in the collection (or the parent's subcollection),
  /// including archived and deleted ones; the planner keeps the live ones.
  final List<ImportExisting> existing;

  /// Lower-cased member sign-in emails to uids, for member fields.
  final Map<String, String> memberEmails;

  /// The values of the spec's [ImportSpec.options].
  final Map<String, Object?> options;

  /// Whatever the spec's `prepare` loaded (settings, related records).
  final Map<String, Object?> data;
  final String? parentId;

  /// The signed-in person importing (an owner field's default).
  final String uid;

  T? option<T>(String key) => options[key] is T ? options[key] as T : null;
  T? get<T>(String key) => data[key] is T ? data[key] as T : null;

  ImportContext copyWith({
    List<ImportExisting>? existing,
    Map<String, String>? memberEmails,
    Map<String, Object?>? options,
    Map<String, Object?>? data,
    String? parentId,
    String? uid,
  }) =>
      ImportContext(
        existing: existing ?? this.existing,
        memberEmails: memberEmails ?? this.memberEmails,
        options: options ?? this.options,
        data: data ?? this.data,
        parentId: parentId ?? this.parentId,
        uid: uid ?? this.uid,
      );
}

/// One data row, parsed. [values] holds each mapped field's value (absent
/// when blank or unreadable); [problems] the reason per field for an
/// optional value that was left blank. A spec's `normalize` may fill in
/// values from others (a name from first and last name).
class ImportRow {
  ImportRow(this.line, this.cells, Map<String, Object?> values, Map<String, String> problems)
      : values = Map.of(values),
        problems = Map.of(problems);

  /// The line number in the file.
  final int line;

  /// The raw cells, for the rows-with-problems download.
  final List<String> cells;
  final Map<String, Object?> values;

  /// A field's problem, worded for the person importing and saying what
  /// happened instead ("…; left blank"). A spec's `normalize` adds its own
  /// ("…, so it goes in Furniture").
  final Map<String, String> problems;

  Object? operator [](String key) => values[key];
  void operator []=(String key, Object? value) => value == null ? values.remove(key) : values[key] = value;

  /// A text value, or ''.
  String text(String key) => values[key]?.toString() ?? '';

  /// A list value (a single value becomes a one-item list), or empty.
  List<String> list(String key) => switch (values[key]) {
        final List<dynamic> l => [for (final v in l) v.toString()],
        null => const [],
        final v => [v.toString()],
      };

  bool has(String key) => values[key] != null;
}

/// A placeholder in a planned write for the id of another record the same
/// import creates ([ImportExpansion.ensure]); the writer replaces it with
/// the id it chose.
class ImportRef {
  const ImportRef(this.key);

  final String key;

  @override
  bool operator ==(Object other) => other is ImportRef && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// What a row's `build` produced when it isn't a plain create.
sealed class ImportBuild {
  const ImportBuild();
}

/// The row creates [data].
class ImportBuildCreate extends ImportBuild {
  const ImportBuildCreate(this.data);

  final Map<String, dynamic> data;
}

/// The row matches something already handled, with the reason.
class ImportBuildDuplicate extends ImportBuild {
  const ImportBuildDuplicate(this.reason);

  final String reason;
}

/// The row can't be imported, with the reason.
class ImportBuildProblem extends ImportBuild {
  const ImportBuildProblem(this.reason);

  final String reason;
}

/// The row became an extra record ([ImportExpansion.claim]) and creates
/// nothing else.
class ImportBuildExtra extends ImportBuild {
  const ImportBuildExtra();
}

/// Extra records rows create besides their own (Contacts: the organization
/// people work at), each created once per key however many rows ask.
class ImportExpansion {
  final Map<String, PlannedCreate> _extras = {};
  final Set<String> _claimed = {};

  /// A reference to the extra record [key], planning it from [data] the
  /// first time it's asked for.
  ImportRef ensure(String key, int line, Map<String, dynamic> Function() data) {
    _extras.putIfAbsent(key, () => PlannedCreate(line, data(), extraKey: key));
    return ImportRef(key);
  }

  /// Makes the row at [line] the extra record [key] itself, replacing data
  /// an earlier [ensure] guessed. False when another row already claimed it.
  bool claim(String key, int line, Map<String, dynamic> data) {
    if (!_claimed.add(key)) return false;
    _extras[key] = PlannedCreate(line, data, extraKey: key);
    return true;
  }

  bool has(String key) => _extras.containsKey(key);

  List<PlannedCreate> get extras => _extras.values.toList();
}

typedef ImportNormalize = String? Function(ImportRow row, ImportContext ctx);
typedef ImportBuilder = Map<String, dynamic> Function(ImportRow row, ImportContext ctx);
typedef ImportExpand = ImportBuild? Function(
    ImportRow row, Map<String, dynamic> data, ImportContext ctx, ImportExpansion expansion);
typedef ImportMerge = Map<String, dynamic> Function(
    ImportExisting existing, ImportRow row, ImportContext ctx, {required bool replace});

/// What an app can import: one record type, the fields a column can fill,
/// how a row becomes a write, and how undo takes it away.
///
/// `build` and `merge` are pure and never touch Firestore; the shared
/// writer does the writing, adds [createTimestamps] (or [updateTimestamps])
/// and stamps `importBatchId`.
class ImportSpec {
  const ImportSpec({
    required this.id,
    required this.appId,
    required this.collection,
    required this.label,
    required this.singular,
    required this.fields,
    required this.build,
    this.subcollection,
    this.duplicateKeys = const [],
    this.merge,
    this.remove = const ImportRemove.delete(),
    this.allowAddAnyway = true,
    this.allowReplace = true,
    this.normalize,
    this.expand,
    this.describe,
    this.options = const [],
    this.createTimestamps = const [],
    this.updateTimestamps = const [],
    this.isLive,
    this.existingValue,
    this.requiresOneOf = const [],
    this.usesMembers = false,
    this.listName,
    this.ownerField,
  });

  /// Stable, `<app>.<record>`; stored on every batch record. Never reused
  /// or renamed.
  final String id;
  final String appId;

  /// The top-level collection, or the parent collection when
  /// [subcollection] is set.
  final String collection;

  /// For records under a parent (Task List tasks): the subcollection's
  /// name. The flow is opened with the parent's id.
  final String? subcollection;

  /// The record type, plural and capitalized ("Items"): the screen's title
  /// is "Import items".
  final String label;

  /// One record, lower case ("item").
  final String singular;

  /// What the person's records are called in messages ("your contacts");
  /// defaults to "your <label>".
  final String? listName;
  final List<ImportField> fields;

  /// Tried in order; the first key the row has every value for decides.
  final List<ImportKey> duplicateKeys;

  /// The matching step needs a column for at least one of these fields
  /// ("Match at least a name or email column"); rows are then checked by
  /// [normalize]. Empty: the required fields decide.
  final List<String> requiresOneOf;

  /// Row-level rules after the cells are parsed: fill values from others,
  /// or return why the row can't be imported.
  final ImportNormalize? normalize;

  /// A row as a create.
  final ImportBuilder build;

  /// A row that may create an extra record, link to one, or turn out to be
  /// a duplicate in a way [duplicateKeys] can't say. Returns null to keep
  /// the plain create.
  final ImportExpand? expand;

  /// A row matching [existing] as an update: only the fields that change.
  /// Defaults to [fillBlanks] over [build]'s map.
  final ImportMerge? merge;
  final ImportRemove remove;

  /// Whether "Add anyway" is offered for rows that match a record.
  final bool allowAddAnyway;

  /// Whether "Replace existing values" is offered with Update. Without it,
  /// an update only fills blanks.
  final bool allowReplace;

  /// The record's name in messages ("Already in your contacts as Maya
  /// Chen"); defaults to its `name` or `title` field.
  final String Function(Map<String, dynamic> data)? describe;
  final List<ImportOption> options;

  /// Fields set to the server time on a create (or an update).
  final List<String> createTimestamps;
  final List<String> updateTimestamps;

  /// Whether an existing record counts for duplicates; defaults to
  /// [remove]'s idea of live (not archived, not deleted).
  final bool Function(Map<String, dynamic> data)? isLive;

  /// A duplicate-key field's value on an existing record, when it isn't
  /// stored under the field's key (CRM: the contact's email inside the
  /// `contact` map). Defaults to `existing.data[field]`.
  final Object? Function(ImportExisting existing, String field)? existingValue;

  /// Whether member fields need the group's member list.
  final bool usesMembers;

  /// For a list each person keeps their own records in, inside a shared
  /// collection (Sell: a seller's products), the field holding the owner's
  /// uid: only records whose [ownerField] is [ImportContext.uid] count as
  /// duplicates or are updated. Null: every record in the list counts.
  final String? ownerField;

  /// The fields for [guessCsvColumns].
  List<CsvImportField> get csvFields => [for (final f in fields) CsvImportField(f.key, f.label, aliases: f.aliases)];

  String get messageListName => listName ?? 'your ${label.toLowerCase()}';

  ImportField? field(String key) => fields.where((f) => f.key == key).firstOrNull;

  String describeRecord(Map<String, dynamic> data) {
    final custom = describe?.call(data);
    if (custom != null && custom.isNotEmpty) return custom;
    for (final k in const ['name', 'title', 'text', 'label']) {
      final v = data[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return 'an existing $singular';
  }

  bool recordIsLive(Map<String, dynamic> data) => (isLive ?? remove.isLive)(data);

  /// The rows of a downloadable template: the field labels and one example.
  List<List<String>> templateRows() => [
        [for (final f in fields) f.label],
        [for (final f in fields) f.example],
      ];
}

/// [incoming]'s values for the fields [existing] leaves blank, or every
/// differing value when [replace]. Lists gain the entries they lack.
Map<String, dynamic> fillBlanks(Map<String, dynamic> existing, Map<String, dynamic> incoming,
    {bool replace = false}) {
  bool blank(Object? v) => v == null || (v is String && v.trim().isEmpty) || (v is Iterable && v.isEmpty);
  final changes = <String, dynamic>{};
  incoming.forEach((key, value) {
    if (blank(value)) return;
    final current = existing[key];
    if (blank(current)) {
      changes[key] = value;
    } else if (value is List && current is List) {
      final have = current.map((v) => v.toString().toLowerCase()).toSet();
      final added = value.where((v) => !have.contains(v.toString().toLowerCase())).toList();
      if (replace && !_sameValue(current, value)) {
        changes[key] = value;
      } else if (added.isNotEmpty) {
        changes[key] = [...current, ...added];
      }
    } else if (replace && !_sameValue(current, value)) {
      changes[key] = value;
    }
  });
  return changes;
}

bool _sameValue(Object? a, Object? b) => importCanonical(a) == importCanonical(b);

/// [value] as stable text: maps by sorted key, dates and Firestore
/// timestamps as milliseconds (anything with `millisecondsSinceEpoch` or
/// `toDate()`), so a value read back compares equal to the one written.
String importCanonical(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 's:$value';
  if (value is bool) return 'b:$value';
  if (value is num) return 'n:${value == value.roundToDouble() && value.abs() < 1e15 ? value.toInt() : value}';
  if (value is DateTime) return 'd:${value.millisecondsSinceEpoch}';
  if (value is List) return '[${value.map(importCanonical).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '$k=${importCanonical(value[k])}').join(',')}}';
  }
  try {
    // Firestore Timestamp, without importing cloud_firestore here.
    final date = (value as dynamic).toDate() as DateTime;
    return 'd:${date.millisecondsSinceEpoch}';
  } catch (_) {
    return 'o:$value';
  }
}

/// A short, stable fingerprint of [fields] of [data] (FNV-1a, two 32-bit
/// lanes, web-safe): how undo tells whether a record still holds what the
/// import wrote.
String importFingerprint(Map<String, dynamic> data, Iterable<String> fields) {
  final keys = fields.toList()..sort();
  final text = keys.map((k) => '$k=${importCanonical(data[k])}').join('\u0001');
  int lane(int seed) {
    var h = seed;
    for (final unit in text.codeUnits) {
      h = (h ^ unit) & 0xffffffff;
      // h * 16777619 mod 2^32 without leaving the exact-integer range on web.
      h = (((h << 24) & 0xffffffff) + h * 403) & 0xffffffff;
    }
    return h;
  }

  return lane(0x811c9dc5).toRadixString(16).padLeft(8, '0') + lane(0x01000193).toRadixString(16).padLeft(8, '0');
}

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

final Map<String, ImportSpec> _registry = {};

/// Makes [spec] findable by id, for Recent imports, undo and checks that
/// don't name the app. Registering the same spec again is a no-op; a
/// different spec under a taken id throws.
void registerImportSpec(ImportSpec spec) {
  final current = _registry[spec.id];
  if (current != null && !identical(current, spec)) {
    throw StateError('Import spec id "${spec.id}" is already registered by another spec.');
  }
  _registry[spec.id] = spec;
}

ImportSpec? importSpecById(String id) => _registry[id];

List<ImportSpec> get registeredImportSpecs => List.unmodifiable(_registry.values);

/// Why [spec] can't work against the collection policy table (empty when it
/// can): the collection must be client-writable tenant data owned by the
/// spec's app, no field may be one of its `serverFields`, and undo can't
/// hard-delete where the table blocks deletes. [policy] defaults to the
/// generated table's entry; [writtenFields] adds keys `build` writes that
/// aren't fields.
List<String> checkImportSpec(ImportSpec spec, {CollectionPolicy? policy, Iterable<String> writtenFields = const []}) {
  final p = policy ?? collectionPolicies[spec.collection];
  final problems = <String>[];
  if (!RegExp(r'^[a-z0-9-]+\.[a-z0-9_]+$').hasMatch(spec.id)) {
    problems.add('id "${spec.id}" should be "<app>.<record>" in lower case');
  }
  if (p == null) return [...problems, '${spec.collection} is not in security/collections.json'];
  if (p.kind != CollectionKind.tenant) problems.add('${spec.collection} is not tenant data');
  final sub = spec.subcollection;
  final serverOwned = sub == null ? p.serverOwned : (p.subcollections[sub] ?? p.serverOwned);
  if (serverOwned) problems.add('${spec.collection} is written only by Cloud Functions');
  if (p.apps.isNotEmpty && !p.apps.contains(spec.appId)) {
    problems.add('${spec.appId} is not one of ${spec.collection}\'s apps (${p.apps.join(', ')})');
  }
  final keys = {...spec.fields.map((f) => f.key), ...writtenFields};
  for (final f in p.serverFields) {
    if (keys.contains(f) && sub == null) problems.add('$f is a server field of ${spec.collection}');
  }
  if (p.blockDelete && sub == null && spec.remove.mode == ImportRemoveMode.delete) {
    problems.add('${spec.collection} blocks deletes, so undo must soft-delete or archive');
  }
  final fieldKeys = spec.fields.map((f) => f.key).toList();
  if (fieldKeys.toSet().length != fieldKeys.length) problems.add('field keys repeat');
  for (final k in spec.duplicateKeys.expand((k) => k.fields)) {
    if (spec.field(k) == null && spec.existingValue == null) problems.add('duplicate key $k is not a field');
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

/// What to do with a row that matches an existing record.
enum ImportDuplicates {
  /// Leave the record alone and don't import the row.
  skip,

  /// Fill in the record's blank fields (or replace its values, when
  /// [ImportSettings.replaceExisting]).
  update,

  /// Create a new record anyway.
  addAnyway;

  static ImportDuplicates parse(Object? value) =>
      ImportDuplicates.values.where((d) => d.name == value).firstOrNull ?? ImportDuplicates.skip;
}

class ImportSettings {
  const ImportSettings({this.duplicates = ImportDuplicates.skip, this.replaceExisting = false});

  final ImportDuplicates duplicates;
  final bool replaceExisting;
}

/// A record the import creates. [extraKey] is set for an extra record
/// ([ImportExpansion]); [data] may hold [ImportRef]s.
class PlannedCreate {
  const PlannedCreate(this.line, this.data, {this.extraKey});

  final int line;
  final Map<String, dynamic> data;
  final String? extraKey;
}

/// Changes to an existing record: only the fields that change.
class PlannedUpdate {
  const PlannedUpdate(this.line, this.existing, this.changes);

  final int line;
  final ImportExisting existing;
  final Map<String, dynamic> changes;
}

/// A row that won't be imported, with its line and why.
class ImportSkip {
  const ImportSkip(this.line, this.reason, {this.cells = const [], this.isDuplicate = false});

  final int line;
  final String reason;
  final List<String> cells;
  final bool isDuplicate;
}

/// An optional value that was left blank, with why.
class ImportFlag {
  const ImportFlag(this.line, this.field, this.reason);

  final int line;
  final String field;
  final String reason;
}

class ImportPlan {
  const ImportPlan({
    this.extras = const [],
    this.creates = const [],
    this.updates = const [],
    this.duplicates = const [],
    this.problems = const [],
    this.flags = const [],
    this.unchanged = 0,
    this.rowsOverLimit = 0,
    this.rowCount = 0,
    this.rows = const [],
  });

  /// Extra records ([ImportExpansion]), written before [creates] so the
  /// references to them resolve.
  final List<PlannedCreate> extras;
  final List<PlannedCreate> creates;
  final List<PlannedUpdate> updates;

  /// Rows that match a record and weren't imported.
  final List<ImportSkip> duplicates;

  /// Rows with a problem that keeps them out.
  final List<ImportSkip> problems;

  /// Optional values left blank.
  final List<ImportFlag> flags;

  /// Matching rows with nothing to change.
  final int unchanged;

  /// Rows past [kMaxImportRows] that weren't read.
  final int rowsOverLimit;

  /// Data rows read.
  final int rowCount;

  /// Every row read, parsed, by line.
  final List<ImportRow> rows;

  int get createCount => extras.length + creates.length;
  bool get hasWork => createCount > 0 || updates.isNotEmpty;

  /// Rows not imported, in file order.
  List<ImportSkip> get notImported => [...duplicates, ...problems]..sort((a, b) => a.line.compareTo(b.line));
}

/// Turns [table]'s rows into a plan for [spec], reading each field from the
/// column [mapping] names (field key to column index; null skips it).
///
/// A row whose required value is missing or unreadable is left out whole;
/// an unreadable optional value is left blank and flagged. Duplicates are
/// found on the spec's keys against the live [ImportContext.existing]
/// records and earlier rows of the file.
ImportPlan planImport(
  ImportSpec spec,
  CsvTable table,
  Map<String, int?> mapping, {
  ImportContext ctx = const ImportContext(),
  ImportSettings settings = const ImportSettings(),
  int maxRows = kMaxImportRows,
}) {
  final rows = table.rows.take(maxRows).toList();

  // A date column reads day first when any of its dates only reads that way.
  final dayFirst = <String>{
    for (final f in spec.fields.where((f) => f.type == ImportFieldType.date))
      if (mapping[f.key] != null && rows.any((r) => isDayFirstDate(r.cell(mapping[f.key])))) f.key,
  };

  final owner = spec.ownerField;
  final live = [
    for (final e in ctx.existing)
      if (spec.recordIsLive(e.data) && (owner == null || (ctx.uid.isNotEmpty && e.data[owner] == ctx.uid))) e,
  ];
  List<String> keyValues(ImportKey key, Object? Function(String field) read) {
    final parts = <List<String>>[];
    for (final field in key.fields) {
      final v = read(field);
      final values = switch (v) {
        final List<dynamic> l => [for (final x in l) importKeyOf(x.toString())],
        null => const <String>[],
        _ => [importKeyOf(v.toString())],
      }
          .where((s) => s.isNotEmpty)
          .toList();
      if (values.isEmpty) return const [];
      parts.add(values);
    }
    // One field (the usual case) or the product of several.
    var combos = <String>[''];
    for (final p in parts) {
      combos = [for (final c in combos) for (final v in p) c.isEmpty ? v : '$c\u0001$v'];
    }
    return combos;
  }

  final existingIndex = <int, Map<String, ImportExisting>>{};
  for (var k = 0; k < spec.duplicateKeys.length; k++) {
    final key = spec.duplicateKeys[k];
    final index = existingIndex[k] = {};
    for (final e in live) {
      final read = spec.existingValue;
      final values = keyValues(key, (f) => read == null ? e.data[f] : read(e, f));
      for (final v in values) {
        index.putIfAbsent(v, () => e);
      }
    }
  }

  String keyLabel(ImportKey key) =>
      key.label ?? key.fields.map((f) => spec.field(f)?.label.toLowerCase() ?? f).join(' and ');

  final expansion = ImportExpansion();
  final creates = <PlannedCreate>[];
  final updates = <PlannedUpdate>[];
  final updatedIds = <String>{};
  final duplicates = <ImportSkip>[];
  final problems = <ImportSkip>[];
  final flags = <ImportFlag>[];
  final parsedRows = <ImportRow>[];
  final seenInFile = <int, Map<String, int>>{};
  var unchanged = 0;

  for (final csvRow in rows) {
    final values = <String, Object?>{};
    final fieldProblems = <String, String>{};
    String? fatal;
    for (final field in spec.fields) {
      final column = mapping[field.key];
      if (column == null) {
        if (field.required) fatal ??= 'No ${field.label.toLowerCase()} column';
        continue;
      }
      final parsed = field.parse(csvRow.cell(column), ctx, dayFirst: dayFirst.contains(field.key));
      if (parsed.error != null) {
        if (field.required) {
          fatal ??= '${field.label}: ${parsed.error}';
        } else {
          fieldProblems[field.key] = '${parsed.error!}; left blank';
        }
      } else if (parsed.value != null) {
        values[field.key] = parsed.value;
      } else if (field.required) {
        fatal ??= 'No ${field.label.toLowerCase()}';
      }
    }
    final row = ImportRow(csvRow.line, csvRow.cells, values, fieldProblems);
    parsedRows.add(row);
    if (fatal != null) {
      problems.add(ImportSkip(row.line, fatal, cells: row.cells));
      continue;
    }
    final rowProblem = spec.normalize?.call(row, ctx);
    if (rowProblem != null) {
      problems.add(ImportSkip(row.line, rowProblem, cells: row.cells));
      continue;
    }
    row.problems.forEach((field, reason) =>
        flags.add(ImportFlag(row.line, field, '${spec.field(field)?.label ?? field}: $reason')));

    // Duplicates: the first key the row has values for decides.
    ImportExisting? match;
    String? inFile;
    for (var k = 0; k < spec.duplicateKeys.length; k++) {
      final key = spec.duplicateKeys[k];
      final values = keyValues(key, (f) => row[f]);
      if (values.isEmpty) continue;
      final seen = seenInFile[k] ??= {};
      final earlier = values.map((v) => seen[v]).whereType<int>().firstOrNull;
      if (earlier != null) {
        inFile = 'Same ${keyLabel(key)} as line $earlier';
      } else {
        for (final v in values) {
          seen[v] = row.line;
        }
        match = values.map((v) => existingIndex[k]![v]).whereType<ImportExisting>().firstOrNull;
      }
      break;
    }
    if (inFile != null && settings.duplicates != ImportDuplicates.addAnyway) {
      duplicates.add(ImportSkip(row.line, inFile, cells: row.cells, isDuplicate: true));
      continue;
    }
    if (match != null) {
      final already = 'Already in ${spec.messageListName} as ${spec.describeRecord(match.data)}';
      if (settings.duplicates == ImportDuplicates.skip || updatedIds.contains(match.id)) {
        duplicates.add(ImportSkip(row.line, already, cells: row.cells, isDuplicate: true));
        continue;
      }
      if (settings.duplicates == ImportDuplicates.update) {
        final changes = spec.merge != null
            ? spec.merge!(match, row, ctx, replace: settings.replaceExisting)
            : fillBlanks(match.data, spec.build(row, ctx), replace: settings.replaceExisting);
        if (changes.isEmpty) {
          unchanged++;
        } else {
          updatedIds.add(match.id);
          updates.add(PlannedUpdate(row.line, match, changes));
        }
        continue;
      }
    }

    final data = spec.build(row, ctx);
    switch (spec.expand?.call(row, data, ctx, expansion) ?? ImportBuildCreate(data)) {
      case ImportBuildCreate(:final data):
        creates.add(PlannedCreate(row.line, data));
      case ImportBuildDuplicate(:final reason):
        duplicates.add(ImportSkip(row.line, reason, cells: row.cells, isDuplicate: true));
      case ImportBuildProblem(:final reason):
        problems.add(ImportSkip(row.line, reason, cells: row.cells));
      case ImportBuildExtra():
        break;
    }
  }

  return ImportPlan(
    extras: expansion.extras,
    creates: creates,
    updates: updates,
    duplicates: duplicates,
    problems: problems,
    flags: flags,
    unchanged: unchanged,
    rowsOverLimit: table.rows.length - rows.length,
    rowCount: rows.length,
    rows: parsedRows,
  );
}

/// The rows that weren't imported as a CSV a person can fix and import
/// again: the file's own columns plus a Reason column.
List<List<String>> notImportedCsvRows(CsvTable table, ImportPlan plan) => [
      [...table.headers, 'Reason'],
      for (final skip in plan.notImported)
        [
          for (var i = 0; i < table.headers.length; i++) i < skip.cells.length ? skip.cells[i] : '',
          skip.reason,
        ],
    ];
