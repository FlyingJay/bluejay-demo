import 'package:bluejay_design/bluejay_design.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/csv_export.dart';
import 'package:shared_services/file_pick.dart';
import 'package:shared_services/group_member_directory.dart';
import 'package:shared_services/record_import_store.dart';
import 'package:shared_services/scoped_collection.dart' show collectionPolicyFor;
import 'package:shared_services/user_app_entitlements.dart';

export 'package:shared_services/record_import_store.dart';

/// The shared spreadsheet import screen (plans/spreadsheet-import §4): an
/// app hands it an [ImportSpec] and it does the rest in five steps (choose
/// a file, match columns, preview, write, result), with Recent imports and
/// undo.
///
/// Adopting it is one line where the list's other actions are:
///
/// ```dart
/// BjOverflowMenu(actions: [
///   ...recordImportActions(context, spec: inventoryItemImport, label: 'Import items'),
///   BjMenuAction(label: 'Export stock (CSV)', ...),
/// ])
/// ```
///
/// or [RecordImportButton] where Export (or Add) is a button.

/// Whether the signed-in person may import into [spec]'s collection: they
/// can create records there (the `:edit` tier where the table says
/// `writeTier: edit`, any member otherwise). The rules still decide each
/// write.
bool canImportInto(ImportSpec spec, {UserAppEntitlements? entitlements, String? groupId}) {
  final e = entitlements ?? UserAppEntitlements.current(_signedInUid());
  final group = groupId ?? ActiveGroupService.instance.activeGroupId ?? '';
  if (e == null || group.isEmpty) return false;
  final policy = collectionPolicyFor(spec.collection);
  final appId = policy.apps.length == 1 ? policy.apps.single : spec.appId;
  return e.hasAppTier(group, appId, policy.editTierWrites ? EntitlementTier.edit : EntitlementTier.read);
}

/// The signed-in uid, or '' where Firebase isn't set up (widget tests).
String _signedInUid() {
  try {
    return fire_auth.FirebaseAuth.instance.currentUser?.uid ?? '';
  } catch (_) {
    return '';
  }
}

/// Opens the import screen for [spec] (or a choice of [specs], such as
/// Contacts' shared and personal lists). [data] is what the spec's hooks
/// read from [ImportContext.data] (settings, related records); [parentId]
/// is the parent record for a subcollection spec.
Future<void> openRecordImport(
  BuildContext context, {
  required ImportSpec spec,
  List<ImportSpec> specs = const [],
  Map<String, Object?> data = const {},
  String? parentId,
  RecordImportStore? store,
}) {
  final all = specs.isEmpty ? [spec] : specs;
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => RecordImportScreen(
      specs: all,
      initial: spec,
      data: data,
      parentId: parentId,
      store: store ?? RecordImportStore.instance,
    ),
  ));
}

/// The Import entry for a list's `⋮` menu, or nothing when the viewer can't
/// create records there ([canImport] overrides the check, for collections
/// whose rules go by the parent record).
List<BjMenuAction> recordImportActions(
  BuildContext context, {
  required ImportSpec spec,
  List<ImportSpec> specs = const [],
  String? label,
  Map<String, Object?> data = const {},
  String? parentId,
  bool? canImport,
}) {
  if (!(canImport ?? canImportInto(spec))) return const [];
  return [
    BjMenuAction(
      label: label ?? 'Import',
      icon: Icons.upload_file,
      onSelected: () => openRecordImport(context, spec: spec, specs: specs, data: data, parentId: parentId),
    ),
  ];
}

enum RecordImportButtonStyle { text, outlined, filled, icon }

/// The Import entry as a button, matching the Export or Add button beside
/// it. Hidden when the viewer can't create records there.
class RecordImportButton extends StatelessWidget {
  const RecordImportButton({
    super.key,
    required this.spec,
    this.specs = const [],
    this.label = 'Import',
    this.style = RecordImportButtonStyle.text,
    this.data = const {},
    this.parentId,
    this.canImport,
  });

  final ImportSpec spec;
  final List<ImportSpec> specs;
  final String label;
  final RecordImportButtonStyle style;
  final Map<String, Object?> data;
  final String? parentId;
  final bool? canImport;

  @override
  Widget build(BuildContext context) {
    if (!(canImport ?? canImportInto(spec))) return const SizedBox.shrink();
    void open() => openRecordImport(context, spec: spec, specs: specs, data: data, parentId: parentId);
    const icon = Icon(Icons.upload_file);
    return switch (style) {
      RecordImportButtonStyle.text => TextButton.icon(onPressed: open, icon: icon, label: Text(label)),
      RecordImportButtonStyle.outlined => OutlinedButton.icon(onPressed: open, icon: icon, label: Text(label)),
      RecordImportButtonStyle.filled => FilledButton.icon(onPressed: open, icon: icon, label: Text(label)),
      RecordImportButtonStyle.icon => IconButton(tooltip: label, onPressed: open, icon: icon),
    };
  }
}

enum _Step { file, match, preview, writing, result }

/// What the preview table shows.
enum ImportRowGroup {
  all('All'),
  added('New'),
  matching('Matching'),
  problems('With problems');

  const ImportRowGroup(this.label);

  final String label;
}

class RecordImportScreen extends StatefulWidget {
  const RecordImportScreen({
    super.key,
    required this.specs,
    required this.initial,
    required this.store,
    this.data = const {},
    this.parentId,
    this.readers = kImportReaders,
    this.matcher = const AliasColumnMatcher(),
    this.members,
    this.uid,
    this.pickFile,
  });

  /// The record types the person can import into here; usually one.
  final List<ImportSpec> specs;
  final ImportSpec initial;
  final RecordImportStore store;
  final Map<String, Object?> data;
  final String? parentId;
  final List<ImportFileReader> readers;
  final ImportColumnMatcher matcher;

  /// The group's members; loaded when null and a spec needs them.
  final List<GroupMember>? members;

  /// The signed-in person; defaults to FirebaseAuth's.
  final String? uid;

  /// Picks the file; defaults to [pickFilesWithBytes] with the readers'
  /// extensions. Null from it means cancelled.
  final Future<PickedFileData?> Function(List<String> extensions)? pickFile;

  @override
  State<RecordImportScreen> createState() => _RecordImportScreenState();
}

class _RecordImportScreenState extends State<RecordImportScreen> {
  late ImportSpec _spec = widget.initial;

  @override
  void initState() {
    super.initState();
    widget.specs.forEach(registerImportSpec);
  }

  _Step _step = _Step.file;
  String _fileName = '';
  CsvTable? _table;
  Map<String, int?> _mapping = const {};
  ImportSettings _settings = const ImportSettings();
  final Map<String, Map<String, Object?>> _options = {};
  final Map<String, List<ImportExisting>> _existing = {};
  Map<String, String> _memberEmails = const {};
  String? _problem;
  bool _loading = false;
  ImportRowGroup _group = ImportRowGroup.all;
  ImportJob? _job;
  int _progress = 0;
  String? _writeError;

  Map<String, Object?> _optionsOf(ImportSpec spec) =>
      _options.putIfAbsent(spec.id, () => {for (final o in spec.options) o.key: o.initial});

  ImportContext get _ctx => ImportContext(
        existing: _existing[_spec.id] ?? const [],
        memberEmails: _memberEmails,
        options: _optionsOf(_spec),
        data: widget.data,
        parentId: widget.parentId,
        uid: widget.uid ?? _signedInUid(),
      );

  ImportPlan? _plan;
  Object? _planInputs;

  /// Plans the file again when anything it depends on changed.
  void _replan() {
    final table = _table;
    final inputs = (
      table,
      _spec.id,
      _mapping.toString(),
      _settings.duplicates,
      _settings.replaceExisting,
      _optionsOf(_spec).toString(),
      _existing[_spec.id]?.length,
    );
    if (inputs == _planInputs && _plan != null) return;
    _planInputs = inputs;
    _plan = table == null ? null : planImport(_spec, table, _mapping, ctx: _ctx, settings: _settings);
  }

  Future<void> _loadFor(ImportSpec spec) async {
    if (_existing.containsKey(spec.id)) return;
    final existing = await widget.store.loadExisting(spec, parentId: widget.parentId);
    _existing[spec.id] = existing;
    if (spec.usesMembers && _memberEmails.isEmpty) {
      final members = widget.members ?? await GroupMemberDirectory.instance.group();
      _memberEmails = {
        for (final m in members)
          if (m.email.isNotEmpty && !m.isGuest) m.email.toLowerCase(): m.uid,
      };
    }
  }

  Future<void> _pick() async {
    final extensions = [for (final r in widget.readers) ...r.extensions];
    final PickedFileData? picked;
    if (widget.pickFile != null) {
      picked = await widget.pickFile!(extensions);
    } else {
      final files = await pickFilesWithBytes(allowedExtensions: extensions);
      picked = files == null || files.isEmpty ? null : files.first;
    }
    if (picked == null || !mounted) return;
    final file = picked;
    if (!file.isReadable) {
      setState(() => _problem = file.readProblem);
      return;
    }
    if (file.size > kMaxImportBytes) {
      setState(() => _problem = 'That file is over 5 MB. Split it into smaller files and import each one.');
      return;
    }
    final reader = widget.readers.where((r) => r.accepts(file.name)).firstOrNull ?? widget.readers.first;
    final table = reader.read(file.bytes!);
    final problem = table.error ?? (table.rows.isEmpty ? 'The file has column names but no rows.' : null);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      await _loadFor(_spec);
      final mapping = await widget.matcher.match(table, _spec);
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _table = table;
        _mapping = mapping;
        _step = _Step.match;
      });
    } catch (_) {
      if (mounted) setState(() => _problem = 'Couldn\'t load your ${_spec.label.toLowerCase()} to check for duplicates. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _switchSpec(ImportSpec spec) async {
    setState(() => _loading = true);
    try {
      await _loadFor(spec);
      final table = _table;
      final mapping = table == null ? _mapping : await widget.matcher.match(table, spec);
      if (mounted) {
        setState(() {
          _spec = spec;
          _mapping = mapping;
        });
      }
    } catch (_) {
      if (mounted) BjSnack.error(context, 'Couldn\'t load that list. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _write() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _step = _Step.writing;
      _writeError = null;
    });
    try {
      final job = _job ??= await widget.store.start(
        _spec,
        plan,
        fileName: _fileName,
        settings: _settings,
        parentId: widget.parentId,
      );
      await widget.store.write(job, onProgress: (done, _) {
        if (mounted) setState(() => _progress = done);
      });
      if (mounted) setState(() => _step = _Step.result);
    } catch (_) {
      if (mounted) {
        setState(() => _writeError = 'The import stopped partway. Try again to continue where it stopped, '
            'or undo what was written so far.');
      }
    }
  }

  Future<void> _undoCurrent() async {
    final job = _job;
    if (job == null) return;
    final batch = await widget.store.getBatch(_spec, job.batchId);
    if (batch == null || !mounted) return;
    final undone = await showImportUndoDialog(context, store: widget.store, spec: _spec, batch: batch);
    if (undone && mounted) Navigator.of(context).maybePop();
  }

  void _back() => setState(() {
        switch (_step) {
          case _Step.match:
            _step = _Step.file;
            _table = null;
          case _Step.preview:
            _step = _Step.match;
          default:
            break;
        }
      });

  @override
  Widget build(BuildContext context) {
    final body = switch (_step) {
      _Step.file => _fileStep(context),
      _Step.match => _matchStep(context, _table!),
      _Step.preview => _previewStep(context, _table!),
      _Step.writing => _writingStep(context),
      _Step.result => _resultStep(context),
    };
    return BjBackStep(
      active: _step == _Step.match || _step == _Step.preview,
      onBack: _back,
      child: BjPage(
        title: 'Import ${_spec.label.toLowerCase()}',
        subtitle: _fileName.isEmpty ? null : _fileName,
        maxWidth: BjBreakpoint.pageWidth,
        body: body,
      ),
    );
  }

  // Step 1 --------------------------------------------------------------

  Widget _fileStep(BuildContext context) {
    final formats = widget.readers.map((r) => r.formatLabel).join(' or ');
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        if (widget.specs.length > 1) _specChooser(),
        BjStateView(
          icon: Icons.upload_file,
          title: 'Bring in ${_spec.label.toLowerCase()} from a spreadsheet',
          message: 'Save your sheet as a $formats file with column names in the first row. '
              'Up to ${NumberFormat.decimalPattern().format(kMaxImportRows)} rows and 5 MB. '
              'You\'ll match the columns and check every row before anything is added.',
          action: BjBusyButton(
            label: 'Choose file',
            icon: Icons.folder_open,
            busy: _loading,
            onPressed: _loading ? null : _pick,
          ),
        ),
        if (_problem != null) BjInlineNote(_problem!, icon: Icons.error_outline, tone: BjTone.danger),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: BjSpace.sm,
          children: [
            Builder(
              builder: (buttonContext) => TextButton.icon(
                onPressed: () => downloadCsv(buttonContext, '${_spec.label.toLowerCase()}-template', _spec.templateRows()),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download a template'),
              ),
            ),
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RecentImportsScreen(spec: _spec, store: widget.store, parentId: widget.parentId),
              )),
              icon: const Icon(Icons.history_rounded),
              label: const Text('Recent imports'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _specChooser() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const BjFieldLabel('Import into'),
          BjOptionCards<ImportSpec>(
            axis: Axis.vertical,
            value: _spec,
            options: [for (final s in widget.specs) BjOption(value: s, title: s.label)],
            onChanged: _loading ? (_) {} : _switchSpec,
          ),
        ],
      );

  // Step 2 --------------------------------------------------------------

  List<ImportField> get _missingRequired => [
        for (final f in _spec.fields)
          if (f.required && _mapping[f.key] == null) f,
      ];

  bool get _identifies => _spec.requiresOneOf.isEmpty || _spec.requiresOneOf.any((k) => _mapping[k] != null);

  Widget _matchStep(BuildContext context, CsvTable table) {
    final used = _mapping.values.whereType<int>().toSet();
    final unused = [
      for (var i = 0; i < table.headers.length; i++)
        if (!used.contains(i)) table.headers[i].isEmpty ? 'Column ${i + 1}' : table.headers[i],
    ];
    final missing = _missingRequired;
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        if (widget.specs.length > 1) _specChooser(),
        BjFormSection(
          title: 'Match your columns',
          description: '${table.rows.length} ${table.rows.length == 1 ? 'row' : 'rows'} in $_fileName. '
              'Pick the column each field comes from, or leave it out.',
          icon: Icons.view_column_outlined,
          children: [
            for (final field in _spec.fields)
              ImportColumnField(
                field: field,
                table: table,
                value: _mapping[field.key],
                onChanged: (v) => setState(() => _mapping = {..._mapping, field.key: v}),
              ),
          ],
        ),
        if (unused.isNotEmpty)
          BjInlineNote('Not imported: ${unused.join(', ')}', icon: Icons.visibility_off_outlined),
        if (missing.isNotEmpty)
          BjInlineNote('Match a column to ${missing.map((f) => f.label).join(', ')} to continue.',
              icon: Icons.info_outline, tone: BjTone.warning),
        if (missing.isEmpty && !_identifies)
          BjInlineNote(
            'Match at least one of: ${_spec.requiresOneOf.map((k) => _spec.field(k)?.label ?? k).join(', ')}.',
            icon: Icons.info_outline,
            tone: BjTone.warning,
          ),
        Row(children: [
          TextButton(onPressed: _back, child: const Text('Choose another file')),
          const Spacer(),
          FilledButton.icon(
            onPressed: missing.isEmpty && _identifies
                ? () => setState(() {
                      _replan();
                      _step = _Step.preview;
                    })
                : null,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Next'),
          ),
        ]),
      ],
    );
  }

  // Step 3 --------------------------------------------------------------

  Widget _previewStep(BuildContext context, CsvTable table) {
    _replan();
    final plan = _plan!;
    final matching = plan.updates.length + plan.duplicates.where((d) => d.isDuplicate).length + plan.unchanged;
    return BjScrollBody(
      children: [
        BjResponsiveGrid(
          minTileWidth: 150,
          maxColumns: 4,
          children: [
            BjStatTile(label: 'New', value: '${plan.createCount}', icon: Icons.add_circle_outline, tone: BjTone.success),
            BjStatTile(label: 'Matching existing', value: '$matching', icon: Icons.content_copy, tone: BjTone.info),
            BjStatTile(
                label: 'With problems', value: '${plan.problems.length}', icon: Icons.error_outline, tone: BjTone.danger),
          ],
        ),
        _optionsSection(plan),
        if (plan.rowsOverLimit > 0)
          BjInlineNote(
            'Only the first ${NumberFormat.decimalPattern().format(kMaxImportRows)} rows are read. '
            'Import the other ${plan.rowsOverLimit} from a second file.',
            icon: Icons.warning_amber_rounded,
            tone: BjTone.warning,
          ),
        if (plan.extras.isNotEmpty)
          BjInlineNote(
            '${plan.extras.length} of the new ${plan.extras.length == 1 ? 'records is' : 'records are'} '
            'added for rows that refer to ${plan.extras.length == 1 ? 'it' : 'them'}: '
            '${plan.extras.take(5).map((e) => _spec.describeRecord(e.data)).join(', ')}${plan.extras.length > 5 ? '…' : ''}',
            icon: Icons.add_link_rounded,
          ),
        if (plan.flags.isNotEmpty)
          BjInlineNote(
            '${plan.flags.length} ${plan.flags.length == 1 ? 'value' : 'values'} couldn\'t be read and will be left blank. '
            'The rows are still imported.',
            icon: Icons.info_outline,
            tone: BjTone.warning,
          ),
        BjSectionHeader(
          title: 'Rows',
          icon: Icons.table_rows_outlined,
          trailing: plan.notImported.isEmpty
              ? null
              : Builder(
                  builder: (buttonContext) => TextButton.icon(
                    onPressed: () => downloadCsv(buttonContext, '${_spec.label.toLowerCase()}-not-imported',
                        notImportedCsvRows(table, plan)),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Rows not imported'),
                  ),
                ),
        ),
        Wrap(spacing: BjSpace.sm, children: [
          for (final g in ImportRowGroup.values)
            ChoiceChip(label: Text(g.label), selected: _group == g, onSelected: (_) => setState(() => _group = g)),
        ]),
        ImportPreviewTable(spec: _spec, table: table, mapping: _mapping, plan: plan, group: _group),
        Row(children: [
          TextButton(onPressed: _back, child: const Text('Back')),
          const Spacer(),
          FilledButton.icon(
            onPressed: plan.hasWork ? _write : null,
            icon: const Icon(Icons.download_done),
            label: Text(importButtonLabel(_spec, plan)),
          ),
        ]),
      ],
    );
  }

  Widget _optionsSection(ImportPlan plan) {
    final options = _optionsOf(_spec);
    final hasKeys = _spec.duplicateKeys.isNotEmpty;
    if (!hasKeys && _spec.options.isEmpty) return const SizedBox.shrink();
    final keyNames = _spec.duplicateKeys.map((k) => k.label ?? k.fields.map((f) => _spec.field(f)?.label.toLowerCase() ?? f).join(' and ')).join(' or ');
    return BjFormSection(
      title: 'Options',
      icon: Icons.tune,
      children: [
        for (final o in _spec.options)
          if (o.isToggle)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: options[o.key] == true,
              title: Text(o.label),
              subtitle: o.help == null ? null : Text(o.help!),
              onChanged: (v) => setState(() => options[o.key] = v),
            )
          else
            DropdownButtonFormField<String?>(
              initialValue: options[o.key] as String?,
              decoration: InputDecoration(labelText: o.label, helperText: o.help),
              items: [
                for (final c in o.choices!) DropdownMenuItem<String?>(value: c.value.isEmpty ? null : c.value, child: Text(c.label)),
              ],
              onChanged: (v) => setState(() => options[o.key] = v),
            ),
        if (hasKeys) ...[
          BjFieldLabel('When a row has the same $keyNames as one of ${_spec.messageListName}'),
          BjOptionCards<ImportDuplicates>(
            axis: Axis.vertical,
            value: _settings.duplicates,
            options: [
              BjOption(
                value: ImportDuplicates.skip,
                title: 'Skip the row',
                description: 'The existing ${_spec.singular} stays exactly as it is.',
                icon: Icons.block,
              ),
              BjOption(
                value: ImportDuplicates.update,
                title: 'Update',
                description: _spec.allowReplace
                    ? 'Fill in its blank fields from the file.'
                    : 'Fill in its blank fields from the file. Nothing filled in is overwritten.',
                icon: Icons.merge_type,
              ),
              if (_spec.allowAddAnyway)
                BjOption(
                  value: ImportDuplicates.addAnyway,
                  title: 'Add anyway',
                  description: 'Add the row as a new ${_spec.singular}, even though it may be a duplicate.',
                  icon: Icons.add_circle_outline,
                ),
            ],
            onChanged: (d) => setState(() => _settings = ImportSettings(duplicates: d, replaceExisting: _settings.replaceExisting)),
          ),
          if (_settings.duplicates == ImportDuplicates.update && _spec.allowReplace)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _settings.replaceExisting,
              title: const Text('Replace existing values'),
              subtitle: const Text('Values in the file overwrite what\'s filled in now.'),
              onChanged: (v) => setState(
                  () => _settings = ImportSettings(duplicates: _settings.duplicates, replaceExisting: v == true)),
            ),
        ],
      ],
    );
  }

  // Steps 4 and 5 -------------------------------------------------------

  Widget _writingStep(BuildContext context) {
    final job = _job;
    final total = job?.total ?? 0;
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        BjStateView(
          icon: _writeError == null ? Icons.upload_rounded : Icons.error_outline,
          tone: _writeError == null ? null : BjTone.danger,
          title: _writeError == null ? 'Importing…' : 'The import stopped',
          message: _writeError ?? '$_progress of $total written. Keep this screen open until it finishes.',
          action: _writeError == null
              ? null
              : Wrap(spacing: BjSpace.sm, children: [
                  if (job != null && job.written > 0)
                    OutlinedButton(onPressed: _undoCurrent, child: const Text('Undo what was written')),
                  FilledButton(onPressed: _write, child: const Text('Try again')),
                ]),
        ),
        BjProgressBar(value: total == 0 ? 0 : _progress / total),
      ],
    );
  }

  Widget _resultStep(BuildContext context) {
    final job = _job!;
    final plan = _plan!;
    final lines = [
      '${job.created} ${job.created == 1 ? _spec.singular : _spec.label.toLowerCase()} added',
      if (job.updated > 0) '${job.updated} updated',
      if (job.skipped > 0) '${job.skipped} skipped',
      if (plan.problems.isNotEmpty) '${plan.problems.length} with problems not imported',
      if (job.failed > 0) '${job.failed} not updated: you can only change ${_spec.label.toLowerCase()} you added, '
          'so ask an editor to import those',
    ];
    return BjScrollBody(
      maxWidth: BjBreakpoint.formWidth,
      children: [
        BjStateView(
          icon: Icons.check_circle_outline,
          tone: job.failed > 0 ? BjTone.warning : BjTone.success,
          title: 'Import finished',
          message: '${lines.join('. ')}. You can undo this import for ${kImportUndoWindow.inDays} days from Recent imports.',
          action: Wrap(spacing: BjSpace.sm, children: [
            OutlinedButton.icon(onPressed: _undoCurrent, icon: const Icon(Icons.undo_rounded), label: const Text('Undo import')),
            FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
          ]),
        ),
      ],
    );
  }
}

/// "Import 212 items, update 14".
String importButtonLabel(ImportSpec spec, ImportPlan plan) {
  if (!plan.hasWork) return 'Nothing to import';
  final n = plan.createCount;
  final parts = [
    if (n > 0) 'Import $n ${n == 1 ? spec.singular : spec.label.toLowerCase()}',
    if (plan.updates.isNotEmpty) '${n > 0 ? 'update' : 'Update'} ${plan.updates.length}',
  ];
  return parts.join(', ');
}

/// One field's column picker, with the first three values of the chosen
/// column as a sample.
class ImportColumnField extends StatelessWidget {
  const ImportColumnField({
    super.key,
    required this.field,
    required this.table,
    required this.value,
    required this.onChanged,
  });

  final ImportField field;
  final CsvTable table;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final samples = value == null
        ? const <String>[]
        : table.rows.map((r) => r.cell(value)).where((c) => c.isNotEmpty).take(3).toList();
    return DropdownButtonFormField<int?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: field.required ? '${field.label} (required)' : field.label,
        helperText: samples.isEmpty ? field.help : 'For example: ${samples.join(' · ')}',
        helperMaxLines: 1,
      ),
      items: [
        DropdownMenuItem<int?>(value: null, child: Text(field.required ? 'Choose a column' : 'Leave out')),
        for (var i = 0; i < table.headers.length; i++)
          DropdownMenuItem<int?>(
            value: i,
            child: Text(table.headers[i].isEmpty ? 'Column ${i + 1}' : table.headers[i], overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// The first 50 rows of [group]: the line number, what happens to the row,
/// and each matched field's cell, with the reason where a value couldn't be
/// read.
class ImportPreviewTable extends StatelessWidget {
  const ImportPreviewTable({
    super.key,
    required this.spec,
    required this.table,
    required this.mapping,
    required this.plan,
    this.group = ImportRowGroup.all,
  });

  static const int maxRows = 50;

  final ImportSpec spec;
  final CsvTable table;
  final Map<String, int?> mapping;
  final ImportPlan plan;
  final ImportRowGroup group;

  @override
  Widget build(BuildContext context) {
    final created = {for (final c in [...plan.extras, ...plan.creates]) if (c.extraKey == null) c.line};
    final updated = {for (final u in plan.updates) u.line};
    final skipped = {for (final s in plan.notImported) s.line: s};
    final flags = <int, Map<String, String>>{};
    for (final f in plan.flags) {
      (flags[f.line] ??= {})[f.field] = f.reason;
    }
    (ImportRowGroup, String, BjTone) statusOf(int line) {
      final skip = skipped[line];
      if (skip != null) {
        return skip.isDuplicate
            ? (ImportRowGroup.matching, 'Skipped: ${skip.reason}', BjTone.neutral)
            : (ImportRowGroup.problems, skip.reason, BjTone.danger);
      }
      if (updated.contains(line)) return (ImportRowGroup.matching, 'Update', BjTone.info);
      if (created.contains(line)) {
        return flags.containsKey(line)
            ? (ImportRowGroup.added, 'New, some values left blank', BjTone.warning)
            : (ImportRowGroup.added, 'New', BjTone.success);
      }
      return (ImportRowGroup.matching, 'Nothing new', BjTone.neutral);
    }

    final fields = [for (final f in spec.fields) if (mapping[f.key] != null) f];
    final rows = [
      for (final r in table.rows.take(plan.rowCount))
        if (group == ImportRowGroup.all || statusOf(r.line).$1 == group) r,
    ];
    if (rows.isEmpty) {
      return const BjInlineNote('No rows here.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              const DataColumn(label: Text('Line')),
              const DataColumn(label: Text('Result')),
              for (final f in fields) DataColumn(label: Text(f.label)),
            ],
            rows: [
              for (final r in rows.take(maxRows))
                DataRow(cells: [
                  DataCell(Text('${r.line}')),
                  DataCell(() {
                    final (_, label, tone) = statusOf(r.line);
                    return BjStatusPill(label: label, tone: tone);
                  }()),
                  for (final f in fields)
                    DataCell(() {
                      final reason = flags[r.line]?[f.key];
                      final text = Text(r.cell(mapping[f.key]), overflow: TextOverflow.ellipsis);
                      if (reason == null) return text;
                      return Tooltip(
                        message: reason,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.error_outline, size: 16, color: context.bj.tone(BjTone.warning).foreground),
                          const SizedBox(width: BjSpace.xs),
                          text,
                        ]),
                      );
                    }()),
                ]),
            ],
          ),
        ),
        if (rows.length > maxRows) BjInlineNote('Showing the first $maxRows of ${rows.length} rows.'),
      ],
    );
  }
}

/// The signed-in person's imports of [spec] (everyone's for the app's
/// admins): counts, who ran it, when, and Undo while it's open.
class RecentImportsScreen extends StatelessWidget {
  const RecentImportsScreen({super.key, required this.spec, required this.store, this.parentId});

  final ImportSpec spec;
  final RecordImportStore store;
  final String? parentId;

  @override
  Widget build(BuildContext context) {
    final uid = _signedInUid();
    final group = ActiveGroupService.instance.activeGroupId ?? '';
    final isAdmin = UserAppEntitlements.current(uid)?.hasAppTier(group, spec.appId, EntitlementTier.admin) ?? false;
    final date = DateFormat.yMMMd().add_jm();
    return BjPage(
      title: 'Recent imports',
      subtitle: spec.label,
      body: StreamBuilder<List<ImportBatch>>(
        stream: store.watchBatches(spec, all: isAdmin, parentId: parentId),
        builder: (context, snap) => BjSnapshotView<List<ImportBatch>>(
          snapshot: snap,
          isEmpty: (b) => b.isEmpty,
          empty: BjStateView.empty(icon: Icons.history_rounded, title: 'No imports of ${spec.label.toLowerCase()} yet'),
          builder: (batches) => BjScrollBody(
            spacing: BjSpace.sm,
            children: [
              for (final b in batches)
                BjListRow(
                  title: b.fileName.isEmpty ? 'Import' : b.fileName,
                  subtitle: [
                    if (b.startedAt != null) date.format(b.startedAt!),
                    if (b.creatorId != uid) 'by another member',
                  ].join(' · '),
                  meta: [
                    BjStatusPill(label: _statusLabel(b), tone: _statusTone(b)),
                    Text('${b.count('created')} added, ${b.count('updated')} updated, ${b.count('skipped')} skipped'),
                  ],
                  trailing: b.canUndo(uid: uid, isAppAdmin: isAdmin, now: DateTime.now())
                      ? TextButton(
                          onPressed: () => showImportUndoDialog(context, store: store, spec: spec, batch: b),
                          child: const Text('Undo'),
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _statusLabel(ImportBatch b) => switch (b.status) {
        ImportBatchStatus.writing => 'Didn\'t finish',
        ImportBatchStatus.done => 'Imported',
        ImportBatchStatus.failed => 'Stopped partway',
        ImportBatchStatus.undone => 'Undone',
      };

  static BjTone _statusTone(ImportBatch b) => switch (b.status) {
        ImportBatchStatus.done => BjTone.success,
        ImportBatchStatus.undone => BjTone.neutral,
        _ => BjTone.warning,
      };
}

/// Works out what undoing [batch] would do, asks, and undoes it. Records
/// changed since the import are kept unless the person ticks the box.
/// True when it was undone.
Future<bool> showImportUndoDialog(
  BuildContext context, {
  required RecordImportStore store,
  required ImportSpec spec,
  required ImportBatch batch,
}) async {
  final ImportUndoPreview preview;
  try {
    preview = await store.previewUndo(spec, batch);
  } catch (_) {
    if (context.mounted) BjSnack.error(context, 'Couldn\'t check this import. Try again.');
    return false;
  }
  if (!context.mounted) return false;
  final includeChanged = await showDialog<bool>(
    context: context,
    builder: (context) => _UndoDialog(spec: spec, preview: preview),
  );
  if (includeChanged == null || !context.mounted) return false;
  try {
    final result = await store.undo(spec, preview, includeChanged: includeChanged);
    if (context.mounted) {
      BjSnack.success(
        context,
        [
          'Import undone',
          if (result.kept > 0) '${result.kept} ${result.kept == 1 ? 'record was' : 'records were'} changed after the import and kept',
        ].join('. '),
      );
    }
    return true;
  } catch (_) {
    if (context.mounted) BjSnack.error(context, 'Couldn\'t undo all of the import. Try again.');
    return false;
  }
}

class _UndoDialog extends StatefulWidget {
  const _UndoDialog({required this.spec, required this.preview});

  final ImportSpec spec;
  final ImportUndoPreview preview;

  @override
  State<_UndoDialog> createState() => _UndoDialogState();
}

class _UndoDialogState extends State<_UndoDialog> {
  bool _includeChanged = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final changed = p.changed.length;
    final remove = p.remove.length + (_includeChanged ? p.changed.where((c) => c.wasCreated).length : 0);
    final restore = p.restore.length + (_includeChanged ? p.changed.where((c) => !c.wasCreated).length : 0);
    final removeVerb = switch (widget.spec.remove.mode) {
      ImportRemoveMode.delete => 'deleted',
      ImportRemoveMode.softDelete => 'deleted',
      ImportRemoveMode.archive => 'archived',
    };
    return AlertDialog(
      title: const Text('Undo this import?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text([
            '$remove added ${remove == 1 ? widget.spec.singular : widget.spec.label.toLowerCase()} will be $removeVerb',
            if (restore > 0) '$restore updated ${restore == 1 ? 'one gets' : 'ones get'} their earlier values back',
          ].join('. ')),
          if (changed > 0) ...[
            const SizedBox(height: BjSpace.md),
            Text('$changed ${changed == 1 ? 'record was' : 'records were'} changed after the import and will be kept.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _includeChanged,
              title: const Text('Undo those too'),
              onChanged: (v) => setState(() => _includeChanged = v == true),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: remove + restore == 0 ? null : () => Navigator.of(context).pop(_includeChanged),
          child: const Text('Undo import'),
        ),
      ],
    );
  }
}
