/// Record history's sheet, timeline and loader: who changed what on a
/// record, from the audit trail, through the `recordHistory` callable
/// (functions/record_history.js), which returns only the events the viewer
/// oversees. It reaches data only through that callable, so an app whose
/// security tier depends on that (Group Admin) can show a record's history.
/// record_history.dart adds the entry points that decide from a
/// `ScopedCollection` and the cached access index whether to offer it.
library;

import 'dart:convert';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:shared_services/cloud_functions.dart';

import 'readable_selectable_text.dart';
import 'time_ago.dart';

/// Opens the history of [docId] in [collection] (a top-level collection, or
/// a subcollection key such as `bug_reports/comments` with [parentDocId]).
void showRecordHistory({
  required BuildContext context,
  required String collection,
  required String docId,
  String? parentDocId,
  Map<String, String> labels = const {},
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.md, BjSpace.sm, 0),
          child: Row(children: [
            Expanded(child: Text('History', style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Expanded(
          child: RecordHistoryTimeline(
            collection: collection,
            docId: docId,
            parentDocId: parentDocId,
            labels: labels,
            scrollController: scrollController,
          ),
        ),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Data
// ─────────────────────────────────────────────────────────────────────────────

/// One page from `recordHistory`.
class RecordHistoryPage {
  const RecordHistoryPage({
    required this.audited,
    required this.events,
    this.hiddenCount = 0,
    this.nextCursor,
  });

  /// False when the collection isn't on the audit trail (nothing is recorded).
  final bool audited;
  final List<RecordHistoryEvent> events;

  /// Events on this page the viewer doesn't oversee (another group's or app's).
  final int hiddenCount;
  final String? nextCursor;

  factory RecordHistoryPage.fromJson(Map<String, dynamic> json) => RecordHistoryPage(
        audited: json['audited'] != false,
        events: [
          for (final e in (json['events'] as List? ?? const []))
            if (e is Map) RecordHistoryEvent.fromJson(Map<String, dynamic>.from(e)),
        ],
        hiddenCount: (json['hiddenCount'] as num?)?.toInt() ?? 0,
        nextCursor: json['nextCursor'] as String?,
      );
}

/// Who made a change, as the callable names them.
enum RecordHistoryActorKind { member, staff, former, system, unattributed }

/// One recorded create, update or delete.
class RecordHistoryEvent {
  const RecordHistoryEvent({
    required this.id,
    required this.operation,
    required this.at,
    required this.actorName,
    required this.actorKind,
    this.actorUid,
    this.changedFields = const [],
    this.changes = const {},
    this.omittedFieldCount = 0,
  });

  final String id;

  /// `create`, `update` or `delete`.
  final String operation;
  final DateTime? at;
  final String actorName;
  final RecordHistoryActorKind actorKind;

  /// Returned to platform admins only.
  final String? actorUid;
  final List<String> changedFields;

  /// field → {before, after}, as display-safe JSON.
  final Map<String, Map<String, dynamic>> changes;
  final int omittedFieldCount;

  /// A trigger or scheduled job, rather than a person.
  bool get isSystem =>
      actorKind == RecordHistoryActorKind.system ||
      actorKind == RecordHistoryActorKind.unattributed;

  /// An update that cleared `deletedAt` (a soft-deleted record brought back).
  bool get isRestore {
    final c = changes['deletedAt'];
    return operation == 'update' && c != null && c['before'] != null && c['after'] == null;
  }

  /// An update that set `deletedAt` (a soft delete).
  bool get isSoftDelete {
    final c = changes['deletedAt'];
    return operation == 'update' && c != null && c['before'] == null && c['after'] != null;
  }

  /// What happened, as a verb phrase: "created", "changed 3 fields".
  String get verb {
    if (operation == 'create') return 'created';
    if (operation == 'delete' || isSoftDelete) return 'deleted';
    if (isRestore) return 'restored';
    final n = changedFields.length + omittedFieldCount;
    return n == 1 ? 'changed 1 field' : 'changed $n fields';
  }

  factory RecordHistoryEvent.fromJson(Map<String, dynamic> json) {
    final actor = json['actor'] is Map ? Map<String, dynamic>.from(json['actor'] as Map) : const <String, dynamic>{};
    final rawChanges = json['changes'] is Map ? json['changes'] as Map : const {};
    return RecordHistoryEvent(
      id: json['id'] as String? ?? '',
      operation: json['operation'] as String? ?? 'update',
      at: DateTime.tryParse(json['at'] as String? ?? '')?.toLocal(),
      actorName: actor['name'] as String? ?? 'System',
      actorKind: RecordHistoryActorKind.values.firstWhere(
        (k) => k.name == actor['kind'],
        orElse: () => RecordHistoryActorKind.unattributed,
      ),
      actorUid: actor['uid'] as String?,
      changedFields: [
        for (final f in (json['changedFields'] as List? ?? const []))
          if (f is String) f,
      ],
      changes: {
        for (final e in rawChanges.entries)
          if (e.key is String && e.value is Map) e.key as String: Map<String, dynamic>.from(e.value as Map),
      },
      omittedFieldCount: (json['omittedFieldCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Loads one page of a record's history.
typedef RecordHistoryLoader = Future<RecordHistoryPage> Function({
  required String collection,
  required String docId,
  String? parentDocId,
  String? cursor,
});

/// The callable-backed [RecordHistoryLoader].
Future<RecordHistoryPage> loadRecordHistory({
  required String collection,
  required String docId,
  String? parentDocId,
  String? cursor,
}) async {
  final data = await BluejayCallable.call('recordHistory', {
    'collection': collection,
    'docId': docId,
    if (parentDocId != null) 'parentDocId': parentDocId,
    if (cursor != null) 'cursor': cursor,
  });
  return RecordHistoryPage.fromJson(data is Map ? Map<String, dynamic>.from(data) : const {});
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting
// ─────────────────────────────────────────────────────────────────────────────

/// A field name as people read it: `amountCents` → "Amount",
/// `next_step_at` → "Next step at". [labels] wins when it names the field.
String recordHistoryFieldLabel(String field, [Map<String, String> labels = const {}]) {
  final given = labels[field];
  if (given != null) return given;
  final words = field
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ')
      .toLowerCase()
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.length > 1 && words.last == 'cents') words.removeLast();
  if (words.isEmpty) return field;
  final text = words.join(' ');
  return text[0].toUpperCase() + text.substring(1);
}

/// Formats a [DateTime] as "Nov 3, 2026, 2:15 PM" without a locale package.
String recordHistoryDate(DateTime at) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final local = at.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final ampm = local.hour < 12 ? 'AM' : 'PM';
  return '${months[local.month - 1]} ${local.day}, ${local.year}, $hour:$minute $ampm';
}

String _thousands(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// One recorded value as text. [field] decides money (`…Cents`) formatting.
String recordHistoryValue(Object? value, {String field = ''}) {
  if (value == null) return '(empty)';
  if (value is Map) {
    if (value['redacted'] == true) return '(hidden)';
    if (value['omitted'] == true) {
      final chars = (value['chars'] as num?)?.toInt();
      return chars == null ? 'too large to show' : 'too large to show (${_thousands(chars)} characters)';
    }
    final type = value['__type'];
    if (type == 'timestamp') {
      final at = DateTime.tryParse(value['value'] as String? ?? '');
      return at == null ? '(date)' : recordHistoryDate(at);
    }
    if (type == 'reference') return value['value']?.toString() ?? '(reference)';
    if (type == 'geopoint') {
      final v = value['value'];
      return v is Map ? '${v['latitude']}, ${v['longitude']}' : '(location)';
    }
    if (type == 'bytes') return '(${value['value']} bytes)';
  }
  if (value is num && field.endsWith('Cents')) {
    final cents = value.round();
    final dollars = _thousands(cents ~/ 100);
    return '\$$dollars.${(cents.abs() % 100).toString().padLeft(2, '0')}';
  }
  if (value is bool) return value ? 'Yes' : 'No';
  if (value is String) return value.isEmpty ? '(empty)' : value;
  if (value is num) return value.toString();
  final text = jsonEncode(value);
  return text.length > 200 ? '${text.substring(0, 199)}…' : text;
}

/// One changed field as a line: "Stage: Lead → Won", or for lists
/// "Tags: added vip; removed old".
String recordHistoryChangeLine(String field, Map<String, dynamic> change, [Map<String, String> labels = const {}]) {
  final label = recordHistoryFieldLabel(field, labels);
  final before = change['before'];
  final after = change['after'];
  if (before is List && after is List) {
    final b = before.map((v) => recordHistoryValue(v)).toList();
    final a = after.map((v) => recordHistoryValue(v)).toList();
    final added = a.where((v) => !b.contains(v)).toList();
    final removed = b.where((v) => !a.contains(v)).toList();
    final parts = [
      if (added.isNotEmpty) 'added ${added.join(', ')}',
      if (removed.isNotEmpty) 'removed ${removed.join(', ')}',
    ];
    if (parts.isNotEmpty) return '$label: ${parts.join('; ')}';
  }
  return '$label: ${recordHistoryValue(before, field: field)} → ${recordHistoryValue(after, field: field)}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Timeline
// ─────────────────────────────────────────────────────────────────────────────

/// A record's history, newest first, 50 events per page with "Load more".
/// System updates (trigger bookkeeping) are collapsed behind a toggle.
class RecordHistoryTimeline extends StatefulWidget {
  const RecordHistoryTimeline({
    super.key,
    required this.collection,
    required this.docId,
    this.parentDocId,
    this.labels = const {},
    this.scrollController,
    this.loader = loadRecordHistory,
  });

  final String collection;
  final String docId;
  final String? parentDocId;
  final Map<String, String> labels;
  final ScrollController? scrollController;
  final RecordHistoryLoader loader;

  @override
  State<RecordHistoryTimeline> createState() => _RecordHistoryTimelineState();
}

class _RecordHistoryTimelineState extends State<RecordHistoryTimeline> {
  final _events = <RecordHistoryEvent>[];
  bool _audited = true;
  int _hidden = 0;
  String? _cursor;
  bool _loading = false;
  bool _loadedOnce = false;
  Object? _error;
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RecordHistoryTimeline old) {
    super.didUpdateWidget(old);
    if (old.collection != widget.collection || old.docId != widget.docId || old.parentDocId != widget.parentDocId) {
      _events.clear();
      _hidden = 0;
      _cursor = null;
      _loadedOnce = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.loader(
        collection: widget.collection,
        docId: widget.docId,
        parentDocId: widget.parentDocId,
        cursor: _cursor,
      );
      if (!mounted) return;
      setState(() {
        _audited = page.audited;
        _events.addAll(page.events);
        _hidden += page.hiddenCount;
        _cursor = page.nextCursor;
        _loadedOnce = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loadedOnce) {
      if (_error != null) {
        return BjStateView.error(error: _error, title: 'Couldn\'t load history', onRetry: _load);
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (!_audited) {
      return const BjStateView.empty(
        icon: Icons.history_toggle_off_rounded,
        title: 'No history is recorded here',
        message: 'This kind of record isn\'t on the audit trail.',
      );
    }
    final systemCount = _events.where((e) => e.isSystem).length;
    final shown = _showSystem ? _events : _events.where((e) => !e.isSystem).toList();
    final text = Theme.of(context).textTheme;
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(BjSpace.lg, BjSpace.sm, BjSpace.lg, BjSpace.xl),
      children: [
        if (systemCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: Text('System updates ($systemCount)'),
              selected: _showSystem,
              onSelected: (v) => setState(() => _showSystem = v),
            ),
          ),
        if (shown.isEmpty && !_loading)
          Padding(
            padding: const EdgeInsets.only(top: BjSpace.xl),
            child: BjStateView.empty(
              icon: Icons.history_rounded,
              title: _events.isEmpty ? 'No changes recorded yet' : 'Only system updates so far',
              message: _hidden > 0 ? '$_hidden change${_hidden == 1 ? '' : 's'} from elsewhere aren\'t shown to you.' : null,
              compact: true,
            ),
          ),
        for (final event in shown) _EventTile(event: event, labels: widget.labels),
        if (_hidden > 0 && shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: BjSpace.sm),
            child: Text(
              '$_hidden change${_hidden == 1 ? '' : 's'} from other groups or apps aren\'t shown to you.',
              style: text.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: BjSpace.sm),
            child: Text('Couldn\'t load more. Please try again.', style: text.bodySmall),
          ),
        if (_cursor != null)
          Padding(
            padding: const EdgeInsets.only(top: BjSpace.md),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : OutlinedButton(onPressed: _load, child: const Text('Load more')),
            ),
          ),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.labels});

  final RecordHistoryEvent event;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final at = event.at;
    final lines = [
      for (final f in event.changedFields)
        if (event.changes[f] != null) recordHistoryChangeLine(f, event.changes[f]!, labels),
      if (event.omittedFieldCount > 0)
        '${event.omittedFieldCount} more field${event.omittedFieldCount == 1 ? '' : 's'} not recorded',
    ];
    final title = Text.rich(TextSpan(children: [
      TextSpan(text: event.actorName, style: const TextStyle(fontWeight: FontWeight.w600)),
      TextSpan(text: ' ${event.verb}'),
    ]));
    final time = at == null
        ? null
        : Tooltip(
            message: recordHistoryDate(at),
            triggerMode: TooltipTriggerMode.longPress,
            child: Text(formatTimeAgo(at), style: text.bodySmall),
          );
    final subtitle = event.actorUid == null ? null : Text(event.actorUid!, style: text.bodySmall);
    if (lines.isEmpty || event.operation == 'delete') {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(_iconOf(event)),
        title: title,
        subtitle: subtitle,
        trailing: time,
      );
    }
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 56, bottom: BjSpace.sm),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Icon(_iconOf(event)),
        title: title,
        subtitle: subtitle,
        trailing: time,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: BjSpace.xs),
              child: ReadableSelectableText(line, style: text.bodySmall),
            ),
        ],
      ),
    );
  }

  static IconData _iconOf(RecordHistoryEvent e) {
    if (e.operation == 'create') return Icons.add_circle_outline_rounded;
    if (e.operation == 'delete' || e.isSoftDelete) return Icons.delete_outline_rounded;
    if (e.isRestore) return Icons.restore_rounded;
    if (e.isSystem) return Icons.settings_suggest_outlined;
    return Icons.edit_outlined;
  }
}
