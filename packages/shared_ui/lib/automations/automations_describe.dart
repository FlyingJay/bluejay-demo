import 'package:bluejay_design/bluejay_design.dart';

import 'automations_models.dart';

/// Plain sentences for rules, built from the catalog, so a new event or
/// action reads well with no change here:
///
///   "When a deal changes stage, if Stage is Won, add a To do."
///   "30, 14 and 7 days before Cycle end date at 09:00, send a notification."

const recordCreated = 'record.created';
const recordUpdated = 'record.updated';
const recordDeleted = 'record.deleted';
const recordEventTypes = [recordCreated, recordUpdated, recordDeleted];

/// The fields a rule's [trigger] exposes to conditions and `{{field}}`
/// placeholders: the source's fields for a record event or a schedule, the
/// event's own for a semantic event.
List<CatalogField> fieldsForTrigger(Map<String, dynamic> trigger, AutomationsCatalog catalog) {
  if (trigger['kind'] == 'schedule') {
    final offset = trigger['dateOffset'];
    return catalog.source(offset is Map ? offset['collection'] as String? : null)?.fields ?? const [];
  }
  final type = trigger['type'] as String?;
  if (recordEventTypes.contains(type)) {
    return catalog.source(trigger['collection'] as String?)?.fields ?? const [];
  }
  final version = trigger['version'];
  return catalog.event(type, version is int ? version : null)?.fields ?? const [];
}

/// The app a trigger belongs to, from its source or event.
String triggerAppId(Map<String, dynamic> trigger, AutomationsCatalog catalog) {
  if (trigger['kind'] == 'schedule') {
    final offset = trigger['dateOffset'];
    return catalog.source(offset is Map ? offset['collection'] as String? : null)?.appId ?? '';
  }
  final type = trigger['type'] as String?;
  if (recordEventTypes.contains(type)) return catalog.source(trigger['collection'] as String?)?.appId ?? '';
  return catalog.event(type)?.appId ?? '';
}

String _lowerFirst(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
String _upperFirst(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// "a, b and c".
String joinAnd(List<String> parts, [String last = 'and']) {
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.single;
  return '${parts.sublist(0, parts.length - 1).join(', ')} $last ${parts.last}';
}

/// "30, 14 and 7 days before" / "1 day after" / "on", for one direction.
String _offsetPhrase(List<int> days, String direction, {bool business = false}) {
  final sorted = [...days]..sort((a, b) => b.compareTo(a));
  final unit = business ? 'business day' : 'day';
  final plural = sorted.length > 1 || sorted.first != 1;
  return '${joinAnd([for (final d in sorted) '$d'])} $unit${plural ? 's' : ''} $direction';
}

/// "30, 14 and 7 days before Cycle end date at 09:00".
String describeSchedule(Map<String, dynamic> dateOffset, AutomationsCatalog catalog) {
  final source = catalog.source(dateOffset['collection'] as String?);
  final fieldName = '${dateOffset['field'] ?? ''}';
  final field = source?.field(fieldName)?.display ?? humanizeFieldName(fieldName);
  final offsets = [for (final o in (dateOffset['offsetsDays'] is List ? dateOffset['offsetsDays'] as List : const [])) if (o is num) o.toInt()];
  final business = dateOffset['businessDays'] == true;
  final before = [for (final o in offsets) if (o < 0) -o];
  final after = [for (final o in offsets) if (o > 0) o];
  final on = offsets.contains(0);
  final parts = <String>[
    if (before.isNotEmpty) _offsetPhrase(before, 'before', business: business),
    if (on) 'on',
    if (after.isNotEmpty) _offsetPhrase(after, 'after', business: business),
  ];
  final at = dateOffset['at'];
  final when = parts.isEmpty ? 'On' : _upperFirst(joinAnd(parts));
  return '$when $field${at is String && at.isNotEmpty ? ' at $at' : ''}';
}

/// "When a deal changes stage" / "When a record is added to Deals".
String describeTrigger(Map<String, dynamic> trigger, AutomationsCatalog catalog) {
  if (trigger['kind'] == 'schedule') {
    final offset = trigger['dateOffset'];
    return offset is Map ? describeSchedule(Map<String, dynamic>.from(offset), catalog) : 'On a schedule';
  }
  final type = '${trigger['type'] ?? ''}';
  if (recordEventTypes.contains(type)) {
    final source = catalog.source(trigger['collection'] as String?);
    final label = source?.display ?? humanizeFieldName('${trigger['collection'] ?? 'a collection'}');
    return switch (type) {
      recordCreated => 'When a record is added to $label',
      recordUpdated => 'When a record in $label changes',
      _ => 'When a record is removed from $label',
    };
  }
  final version = trigger['version'];
  final event = catalog.event(type, version is int ? version : null);
  if (event == null) return type.isEmpty ? 'When something happens' : 'When $type happens';
  return 'When ${_lowerFirst(event.display)}';
}

String _fieldLabel(String field, List<CatalogField> fields) {
  final previous = field.startsWith('before.');
  final name = previous ? field.substring('before.'.length) : field;
  CatalogField? match;
  for (final f in fields) {
    if (f.name == name) match = f;
  }
  final label = match?.display ?? humanizeFieldName(name);
  return previous ? 'previous ${_lowerFirst(label)}' : label;
}

/// A condition value as people read it.
String describeValue(Object? value) {
  if (value is bool) return value ? 'yes' : 'no';
  if (value is List) return joinAnd([for (final v in value) describeValue(v)], 'or');
  if (value is Map) return '…';
  if (value == null) return 'nothing';
  return '$value';
}

/// "Stage is Won", "Province has a value", "Due date is within 7 days".
String describeLeaf(Map<String, dynamic> leaf, AutomationsCatalog catalog, List<CatalogField> fields) {
  final field = _fieldLabel('${leaf['field'] ?? ''}', fields);
  final op = '${leaf['op'] ?? ''}';
  final value = leaf['value'];
  if (op == 'is_empty') return value == false ? '$field has a value' : '$field is empty';
  final operator = catalog.operator(op);
  final label = _lowerFirst(operator?.display ?? humanizeFieldName(op));
  if (operator != null && !operator.needsValue) return '$field $label';
  if (!leaf.containsKey('value')) return '$field $label';
  return '$field $label ${describeValue(value)}';
}

/// The condition tree in words, or null when there is none.
String? describeCondition(Map<String, dynamic>? tree, AutomationsCatalog catalog, List<CatalogField> fields) {
  if (tree == null || tree.isEmpty) return null;
  String walk(Object? node, {bool nested = false}) {
    if (node is! Map) return '';
    final m = Map<String, dynamic>.from(node);
    if (m.containsKey('op')) return describeLeaf(m, catalog, fields);
    if (m.containsKey('not')) return 'not (${walk(m['not'], nested: true)})';
    final all = m['all'];
    final any = m['any'];
    final children = all is List ? all : (any is List ? any : const []);
    final parts = [for (final c in children) walk(c, nested: true)].where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    final joined = joinAnd(parts, all is List ? 'and' : 'or');
    return nested && parts.length > 1 ? '($joined)' : joined;
  }

  final text = walk(tree);
  return text.isEmpty ? null : text;
}

/// "add a To do", from the action's catalog label.
String describeAction(Map<String, dynamic> action, AutomationsCatalog catalog) {
  final version = action['version'];
  final def = catalog.action(action['type'] as String?, version is int ? version : null);
  return _lowerFirst(def?.display ?? '${action['type'] ?? 'do something'}');
}

/// One sentence for what [rule] does.
String describeRule(AutomationEntry rule, AutomationsCatalog catalog) =>
    describeRuleParts(rule.trigger, rule.condition, rule.actions, catalog);

/// [describeRule] for a rule's parts (the editor's preview of a draft).
String describeRuleParts(
  Map<String, dynamic> trigger,
  Map<String, dynamic>? condition,
  List<Map<String, dynamic>> actions,
  AutomationsCatalog catalog,
) {
  final when = trigger.isEmpty ? 'When something happens' : describeTrigger(trigger, catalog);
  final fields = fieldsForTrigger(trigger, catalog);
  final cond = describeCondition(condition, catalog, fields);
  final then = actions.isEmpty ? 'do nothing yet' : joinAnd([for (final a in actions) describeAction(a, catalog)]);
  return '$when${cond == null ? '' : ', if $cond'}, $then.';
}

// ─────────────────────────────────────────────────────────────────────────────
// Run status
// ─────────────────────────────────────────────────────────────────────────────

/// How a run's status reads and looks.
({String label, BjTone tone}) runStatusDisplay(String status) => switch (status) {
      'succeeded' => (label: 'Succeeded', tone: BjTone.success),
      'shadow' => (label: 'Preview only', tone: BjTone.info),
      'skipped' => (label: 'Skipped', tone: BjTone.neutral),
      'failed' => (label: 'Failed', tone: BjTone.danger),
      'retrying' => (label: 'Retrying', tone: BjTone.warning),
      'queued' => (label: 'Retry queued', tone: BjTone.warning),
      'running' => (label: 'Running', tone: BjTone.accent),
      _ => (label: status.isEmpty ? 'Unknown' : humanizeFieldName(status), tone: BjTone.neutral),
    };

/// Why a run was skipped, in plain words.
String skippedReasonText(String? reason) => switch (reason) {
      'condition' => 'Its conditions didn\'t match.',
      'self' => 'This automation caused the change, so it didn\'t run again.',
      'depth' => 'Too many automations in a row set each other off, so the chain stopped here.',
      'duplicate' => 'This change was already handled.',
      'in_progress' => 'Another run of it was already working on this change.',
      'exhausted' => 'It had already used all its attempts.',
      'invalid' => 'The automation has a problem that needs fixing before it can run.',
      'owner_access' => 'The person who set it up no longer has access to what it uses.',
      'rate_limited' => 'It reached its limit of runs for now.',
      'stale' => 'The record changed again before it ran.',
      'disabled' => 'It was turned off.',
      null || '' => 'It didn\'t need to run.',
      _ => humanizeFieldName(reason),
    };

/// "Sent", "Skipped" for one action's outcome.
String actionOutcomeText(String outcome) => switch (outcome) {
      'ok' || 'done' || 'succeeded' || 'sent' => 'Done',
      'shadow' || 'would' || 'would_run' => 'Would have run (preview only)',
      'skipped' => 'Skipped',
      'failed' || 'error' => 'Failed',
      '' => 'Not run',
      _ => humanizeFieldName(outcome),
    };
