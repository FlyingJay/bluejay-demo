/// The data the Automations callables return (functions/automations.js),
/// parsed default-safe: a missing or malformed field becomes an empty value
/// rather than an exception, so a newer server never breaks an older client.
///
/// Rules stay close to their stored JSON (trigger, condition and actions are
/// plain maps) because the editor rebuilds them from the catalog; nothing in
/// the client names a particular event or action type.
library;

String _s(Object? v) => v is String ? v : (v == null ? '' : '$v');
String? _sn(Object? v) => v is String && v.isNotEmpty ? v : null;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : fallback;
int _i(Object? v, [int fallback = 0]) => v is int ? v : (v is num ? v.toInt() : fallback);
List<Object?> _l(Object? v) => v is List ? v : const [];
List<String> _strings(Object? v) => [for (final x in _l(v)) if (x is String) x];
Map<String, dynamic> _m(Object? v) =>
    v is Map ? {for (final e in v.entries) '${e.key}': e.value} : <String, dynamic>{};
DateTime? _date(Object? v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toLocal();
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  return null;
}

/// A deep copy of a JSON-ish value, so editing a draft never changes the
/// rule it came from.
Object? deepCopyJson(Object? v) {
  if (v is Map) return {for (final e in v.entries) '${e.key}': deepCopyJson(e.value)};
  if (v is List) return [for (final x in v) deepCopyJson(x)];
  return v;
}

Map<String, dynamic> _copyMap(Object? v) => deepCopyJson(_m(v)) as Map<String, dynamic>;

// ─────────────────────────────────────────────────────────────────────────────
// Catalog
// ─────────────────────────────────────────────────────────────────────────────

/// Field types the registries use.
abstract final class FieldTypes {
  static const string = 'string';
  static const number = 'number';
  static const boolean = 'boolean';
  static const date = 'date';
  static const list = 'list';
  static const map = 'map';
  static const uid = 'uid';
}

class CatalogApp {
  final String appId;
  final String name;
  const CatalogApp({required this.appId, required this.name});
  factory CatalogApp.fromData(Object? data) {
    final m = _m(data);
    return CatalogApp(appId: _s(m['appId']), name: _s(m['name']));
  }
}

/// A record field an event or source exposes, typed so the editor can
/// pick the right input.
class CatalogField {
  final String name;
  final String type;
  final String label;
  final List<String> enumValues;
  const CatalogField({required this.name, this.type = FieldTypes.string, this.label = '', this.enumValues = const []});
  factory CatalogField.fromData(Object? data) {
    final m = _m(data);
    return CatalogField(
      name: _s(m['name']),
      type: _sn(m['type']) ?? FieldTypes.string,
      label: _s(m['label']),
      enumValues: [for (final x in _l(m['enum'])) if (x != null) '$x'],
    );
  }

  /// What people see: the label, or the name made readable.
  String get display => label.isNotEmpty ? label : humanizeFieldName(name);
}

/// A collection that opts in to automations: its record events, the fields
/// rules may read, and the date fields schedules may use.
class CatalogSource {
  final String collection;
  final String appId;
  final String label;
  final List<String> events;
  final List<CatalogField> fields;
  final List<String> dateFields;

  /// The fields a record.update action may set (the server leaves out
  /// locked, identity and server-owned fields).
  final List<String> writableFields;
  const CatalogSource({
    required this.collection,
    required this.appId,
    this.label = '',
    this.events = const [],
    this.fields = const [],
    this.dateFields = const [],
    this.writableFields = const [],
  });
  factory CatalogSource.fromData(Object? data) {
    final m = _m(data);
    return CatalogSource(
      collection: _s(m['collection']),
      appId: _s(m['appId']),
      label: _s(m['label']),
      events: _strings(m['events']),
      fields: [for (final f in _l(m['fields'])) CatalogField.fromData(f)],
      dateFields: _strings(m['dateFields']),
      writableFields: _strings(m['writableFields']),
    );
  }

  String get display => label.isNotEmpty ? label : humanizeFieldName(collection);

  CatalogField? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }
}

/// A semantic event an app registers ("a deal moves to a new stage").
class CatalogEvent {
  final String type;
  final int version;
  final String appId;
  final String collection;
  final String label;
  final List<CatalogField> fields;
  const CatalogEvent({
    required this.type,
    this.version = 1,
    this.appId = '',
    this.collection = '',
    this.label = '',
    this.fields = const [],
  });
  factory CatalogEvent.fromData(Object? data) {
    final m = _m(data);
    return CatalogEvent(
      type: _s(m['type']),
      version: _i(m['version'], 1),
      appId: _s(m['appId']),
      collection: _s(m['collection']),
      label: _s(m['label']),
      fields: [for (final f in _l(m['fields'])) CatalogField.fromData(f)],
    );
  }

  String get display => label.isNotEmpty ? label : type;
}

class CatalogOperator {
  final String op;

  /// '*' for every field type, otherwise the field types it works on.
  final List<String> appliesTo;
  final bool appliesToAll;
  final String label;
  final bool needsValue;

  /// The value's type when it differs from the field's ('number' for
  /// `within_days`, 'list' for `in`).
  final String? valueType;
  const CatalogOperator({
    required this.op,
    this.appliesTo = const [],
    this.appliesToAll = true,
    this.label = '',
    this.needsValue = true,
    this.valueType,
  });
  factory CatalogOperator.fromData(Object? data) {
    final m = _m(data);
    final applies = m['appliesTo'];
    return CatalogOperator(
      op: _s(m['op']),
      appliesToAll: applies == null || applies == '*',
      appliesTo: _strings(applies),
      label: _s(m['label']),
      needsValue: _b(m['needsValue'], true),
      valueType: _sn(m['valueType']),
    );
  }

  bool appliesToType(String type) => appliesToAll || appliesTo.contains(type);
  String get display => label.isNotEmpty ? label : humanizeFieldName(op);
}

class CatalogParam {
  final String name;
  final String type;
  final String label;
  final bool required;
  final List<String> enumValues;
  final String help;
  const CatalogParam({
    required this.name,
    this.type = FieldTypes.string,
    this.label = '',
    this.required = false,
    this.enumValues = const [],
    this.help = '',
  });
  factory CatalogParam.fromData(Object? data) {
    final m = _m(data);
    return CatalogParam(
      name: _s(m['name']),
      type: _sn(m['type']) ?? FieldTypes.string,
      label: _s(m['label']),
      required: _b(m['required']),
      enumValues: [for (final x in _l(m['enum'])) if (x != null) '$x'],
      help: _s(m['help']),
    );
  }

  String get display => label.isNotEmpty ? label : humanizeFieldName(name);
}

class CatalogAction {
  final String type;
  final int version;
  final String label;
  final String description;
  final String scope;
  final List<CatalogParam> params;
  const CatalogAction({
    required this.type,
    this.version = 1,
    this.label = '',
    this.description = '',
    this.scope = 'group',
    this.params = const [],
  });
  factory CatalogAction.fromData(Object? data) {
    final m = _m(data);
    return CatalogAction(
      type: _s(m['type']),
      version: _i(m['version'], 1),
      label: _s(m['label']),
      description: _s(m['description']),
      scope: _sn(m['scope']) ?? 'group',
      params: [for (final p in _l(m['params'])) CatalogParam.fromData(p)],
    );
  }

  String get display => label.isNotEmpty ? label : type;

  CatalogParam? param(String name) {
    for (final p in params) {
      if (p.name == name) return p;
    }
    return null;
  }
}

class CatalogTemplate {
  final String id;
  final String appId;
  final String name;
  final String description;
  final Map<String, dynamic> rule;
  const CatalogTemplate({
    required this.id,
    this.appId = '',
    this.name = '',
    this.description = '',
    this.rule = const {},
  });
  factory CatalogTemplate.fromData(Object? data) {
    final m = _m(data);
    return CatalogTemplate(
      id: _s(m['id']),
      appId: _s(m['appId']),
      name: _s(m['name']),
      description: _s(m['description']),
      rule: _copyMap(m['rule']),
    );
  }
}

/// Everything the editor is built from (`automationsCatalog`).
class AutomationsCatalog {
  final bool canManageGroup;
  final List<String> manageableAppIds;
  final List<CatalogApp> apps;
  final List<CatalogSource> sources;
  final List<CatalogEvent> events;
  final List<CatalogOperator> operators;
  final List<CatalogAction> actions;
  final List<CatalogTemplate> templates;

  const AutomationsCatalog({
    this.canManageGroup = false,
    this.manageableAppIds = const [],
    this.apps = const [],
    this.sources = const [],
    this.events = const [],
    this.operators = const [],
    this.actions = const [],
    this.templates = const [],
  });

  factory AutomationsCatalog.fromData(Object? data) {
    final m = _m(data);
    return AutomationsCatalog(
      canManageGroup: _b(m['canManageGroup']),
      manageableAppIds: _strings(m['manageableAppIds']),
      apps: [for (final a in _l(m['apps'])) CatalogApp.fromData(a)],
      sources: [for (final s in _l(m['sources'])) CatalogSource.fromData(s)],
      events: [for (final e in _l(m['events'])) CatalogEvent.fromData(e)],
      operators: [for (final o in _l(m['operators'])) CatalogOperator.fromData(o)],
      actions: [for (final a in _l(m['actions'])) CatalogAction.fromData(a)],
      templates: [for (final t in _l(m['templates'])) CatalogTemplate.fromData(t)],
    );
  }

  /// Whether the caller can set up automations at all here.
  bool get canManage => canManageGroup || manageableAppIds.isNotEmpty;

  /// Whether the caller can manage rules for [appId] (null: group-wide rules).
  bool canManageApp(String? appId) =>
      canManageGroup || (appId != null && appId.isNotEmpty && manageableAppIds.contains(appId));

  String appName(String appId) {
    for (final a in apps) {
      if (a.appId == appId) return a.name.isNotEmpty ? a.name : appId;
    }
    return appId.isEmpty ? 'Any app' : humanizeFieldName(appId);
  }

  CatalogSource? source(String? collection) {
    if (collection == null) return null;
    for (final s in sources) {
      if (s.collection == collection) return s;
    }
    return null;
  }

  /// The semantic event [type], at [version] when it's registered there.
  CatalogEvent? event(String? type, [int? version]) {
    CatalogEvent? any;
    for (final e in events) {
      if (e.type != type) continue;
      if (version == null || e.version == version) return e;
      any ??= e;
    }
    return any;
  }

  CatalogOperator? operator(String? op) {
    for (final o in operators) {
      if (o.op == op) return o;
    }
    return null;
  }

  CatalogAction? action(String? type, [int? version]) {
    CatalogAction? any;
    for (final a in actions) {
      if (a.type != type) continue;
      if (version == null || a.version == version) return a;
      any ??= a;
    }
    return any;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rules
// ─────────────────────────────────────────────────────────────────────────────

/// What a group rule and a built-in have in common, for lists and summaries.
abstract class AutomationEntry {
  String get id;
  String get appId;
  String get name;
  bool get enabled;
  String? get pausedReason;
  Map<String, dynamic> get trigger;
  Map<String, dynamic>? get condition;
  List<Map<String, dynamic>> get actions;
  bool get isBuiltIn;
}

List<Map<String, dynamic>> _actionsOf(Object? v) => [for (final a in _l(v)) if (a is Map) _copyMap(a)];
Map<String, dynamic>? _conditionOf(Object? v) => v is Map && v.isNotEmpty ? _copyMap(v) : null;

/// A rule a group set up (`automations/{id}`).
class AutomationRule implements AutomationEntry {
  @override
  final String id;
  final String groupId;
  @override
  final String appId;
  @override
  final String name;
  @override
  final bool enabled;
  @override
  final String? pausedReason;
  final String ownerUid;
  final String ownerName;
  @override
  final Map<String, dynamic> trigger;
  @override
  final Map<String, dynamic>? condition;
  @override
  final List<Map<String, dynamic>> actions;
  final Map<String, dynamic> limits;
  final DateTime? createdAt;
  final DateTime? lastModifiedAt;
  final DateTime? lastRunAt;
  final String? lastRunStatus;

  const AutomationRule({
    required this.id,
    this.groupId = '',
    this.appId = '',
    this.name = '',
    this.enabled = false,
    this.pausedReason,
    this.ownerUid = '',
    this.ownerName = '',
    this.trigger = const {},
    this.condition,
    this.actions = const [],
    this.limits = const {},
    this.createdAt,
    this.lastModifiedAt,
    this.lastRunAt,
    this.lastRunStatus,
  });

  factory AutomationRule.fromData(Object? data) {
    final m = _m(data);
    final owner = _m(m['owner']);
    return AutomationRule(
      id: _s(m['id']),
      groupId: _s(m['groupId']),
      appId: _s(m['appId']),
      name: _s(m['name']),
      enabled: _b(m['enabled']),
      pausedReason: _sn(m['pausedReason']),
      ownerUid: _s(owner['uid']),
      ownerName: _s(owner['name']),
      trigger: _copyMap(m['trigger']),
      condition: _conditionOf(m['condition']),
      actions: _actionsOf(m['actions']),
      limits: _copyMap(m['limits']),
      createdAt: _date(m['createdAt']),
      lastModifiedAt: _date(m['lastModifiedAt']),
      lastRunAt: _date(m['lastRunAt']),
      lastRunStatus: _sn(m['lastRunStatus']),
    );
  }

  @override
  bool get isBuiltIn => false;

  /// The rule as `automationsSave` takes it.
  Map<String, dynamic> toSaveMap() => {
        'name': name,
        if (appId.isNotEmpty) 'appId': appId,
        'enabled': enabled,
        'trigger': deepCopyJson(trigger),
        if (condition != null) 'condition': deepCopyJson(condition),
        'actions': deepCopyJson(actions),
        if (limits.isNotEmpty) 'limits': deepCopyJson(limits),
      };

  AutomationRule copyWith({bool? enabled, String? pausedReason, bool clearPausedReason = false}) => AutomationRule(
        id: id,
        groupId: groupId,
        appId: appId,
        name: name,
        enabled: enabled ?? this.enabled,
        pausedReason: clearPausedReason ? null : (pausedReason ?? this.pausedReason),
        ownerUid: ownerUid,
        ownerName: ownerName,
        trigger: trigger,
        condition: condition,
        actions: actions,
        limits: limits,
        createdAt: createdAt,
        lastModifiedAt: lastModifiedAt,
        lastRunAt: lastRunAt,
        lastRunStatus: lastRunStatus,
      );
}

/// An automation an app ships in code, as it runs in this group.
class BuiltInAutomation implements AutomationEntry {
  @override
  final String id;
  @override
  final String appId;
  @override
  final String name;
  final String description;
  @override
  final bool enabled;
  @override
  final String? pausedReason;

  /// 'live', or 'shadow' while it only records what it would do.
  final String mode;
  @override
  final Map<String, dynamic> trigger;
  @override
  final Map<String, dynamic>? condition;
  @override
  final List<Map<String, dynamic>> actions;

  /// The fields a group may change: offsetsDays, at, businessDays, limits.
  final List<String> adjustable;

  /// The group's current changes to those fields.
  final Map<String, dynamic> adjust;
  final List<String> adjustProblems;
  final Map<String, dynamic> limits;

  const BuiltInAutomation({
    required this.id,
    this.appId = '',
    this.name = '',
    this.description = '',
    this.enabled = false,
    this.pausedReason,
    this.mode = 'live',
    this.trigger = const {},
    this.condition,
    this.actions = const [],
    this.adjustable = const [],
    this.adjust = const {},
    this.adjustProblems = const [],
    this.limits = const {},
  });

  factory BuiltInAutomation.fromData(Object? data) {
    final m = _m(data);
    return BuiltInAutomation(
      id: _s(m['id']),
      appId: _s(m['appId']),
      name: _s(m['name']),
      description: _s(m['description']),
      enabled: _b(m['enabled']),
      pausedReason: _sn(m['pausedReason']),
      mode: _sn(m['mode']) ?? 'live',
      trigger: _copyMap(m['trigger']),
      condition: _conditionOf(m['condition']),
      actions: _actionsOf(m['actions']),
      adjustable: _strings(m['adjustable']),
      adjust: _copyMap(m['adjust']),
      adjustProblems: _strings(m['adjustProblems']),
      limits: _copyMap(m['limits']),
    );
  }

  @override
  bool get isBuiltIn => true;

  bool get isPreviewOnly => mode == 'shadow';

  BuiltInAutomation copyWith({bool? enabled}) => BuiltInAutomation(
        id: id,
        appId: appId,
        name: name,
        description: description,
        enabled: enabled ?? this.enabled,
        pausedReason: pausedReason,
        mode: mode,
        trigger: trigger,
        condition: condition,
        actions: actions,
        adjustable: adjustable,
        adjust: adjust,
        adjustProblems: adjustProblems,
        limits: limits,
      );
}

/// `automationsList`: the group's rules and its built-ins.
class AutomationsListing {
  final List<AutomationRule> rules;
  final List<BuiltInAutomation> builtIns;

  /// Whether the group has the Automations app installed (built-ins run
  /// either way). Missing from older servers, so it defaults to true.
  final bool installed;
  const AutomationsListing({this.rules = const [], this.builtIns = const [], this.installed = true});
  factory AutomationsListing.fromData(Object? data) {
    final m = _m(data);
    return AutomationsListing(
      installed: _b(m['installed'], true),
      rules: [for (final r in _l(m['rules'])) AutomationRule.fromData(r)],
      builtIns: [for (final b in _l(m['builtIns'])) BuiltInAutomation.fromData(b)],
    );
  }

  bool get isEmpty => rules.isEmpty && builtIns.isEmpty;

  /// Every rule then every built-in, for one list.
  List<AutomationEntry> get all => [...rules, ...builtIns];
}

/// A group member a step can be aimed at (`automationsMembers`).
class AutomationMember {
  final String uid;
  final String name;
  final String email;
  const AutomationMember({required this.uid, this.name = '', this.email = ''});
  factory AutomationMember.fromData(Object? data) {
    final m = _m(data);
    return AutomationMember(uid: _s(m['uid']), name: _s(m['name']), email: _s(m['email']));
  }

  String get display => name.isNotEmpty ? name : (email.isNotEmpty ? email : uid);
}

// ─────────────────────────────────────────────────────────────────────────────
// Runs
// ─────────────────────────────────────────────────────────────────────────────

class RunRecordRef {
  final String appId;
  final String collection;
  final String id;
  final String? parentId;
  const RunRecordRef({this.appId = '', this.collection = '', this.id = '', this.parentId});
  factory RunRecordRef.fromData(Object? data) {
    final m = _m(data);
    return RunRecordRef(
      appId: _s(m['appId']),
      collection: _s(m['collection']),
      id: _s(m['id']),
      parentId: _sn(m['parentId']),
    );
  }
}

class RunActionOutcome {
  final String type;
  final String outcome;
  final Object? detail;
  const RunActionOutcome({required this.type, this.outcome = '', this.detail});
  factory RunActionOutcome.fromData(Object? data) {
    final m = _m(data);
    return RunActionOutcome(type: _s(m['type']), outcome: _s(m['outcome']), detail: deepCopyJson(m['detail']));
  }
}

/// One run of a rule for one event (`automation_runs/{id}`).
class AutomationRun {
  final String id;
  final String ruleId;
  final String ruleName;
  final bool builtIn;
  final String appId;
  final String eventType;
  final RunRecordRef record;

  /// running | succeeded | shadow | skipped | failed | retrying
  final String status;
  final String? reason;
  final String mode;
  final int attempts;
  final String? error;
  final List<RunActionOutcome> actions;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  const AutomationRun({
    required this.id,
    this.ruleId = '',
    this.ruleName = '',
    this.builtIn = false,
    this.appId = '',
    this.eventType = '',
    this.record = const RunRecordRef(),
    this.status = '',
    this.reason,
    this.mode = 'live',
    this.attempts = 0,
    this.error,
    this.actions = const [],
    this.startedAt,
    this.finishedAt,
  });

  factory AutomationRun.fromData(Object? data) {
    final m = _m(data);
    return AutomationRun(
      id: _s(m['id']),
      ruleId: _s(m['ruleId']),
      ruleName: _s(m['ruleName']),
      builtIn: _b(m['builtIn']),
      appId: _s(m['appId']),
      eventType: _s(m['eventType']),
      record: RunRecordRef.fromData(m['record']),
      status: _s(m['status']),
      reason: _sn(m['reason']),
      mode: _sn(m['mode']) ?? 'live',
      attempts: _i(m['attempts']),
      error: _sn(m['error']),
      actions: [for (final a in _l(m['actions'])) RunActionOutcome.fromData(a)],
      startedAt: _date(m['startedAt']),
      finishedAt: _date(m['finishedAt']),
    );
  }

  bool get canRetry => status == 'failed';
}

class AutomationRunsPage {
  final List<AutomationRun> runs;
  final String? nextStartAfter;
  const AutomationRunsPage({this.runs = const [], this.nextStartAfter});
  factory AutomationRunsPage.fromData(Object? data) {
    final m = _m(data);
    return AutomationRunsPage(
      runs: [for (final r in _l(m['runs'])) AutomationRun.fromData(r)],
      nextStartAfter: _sn(m['nextStartAfter']),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// `cycleEndDate` → "Cycle end date"; `assigned_to` → "Assigned to";
/// `$actor.kind` → "Actor kind".
String humanizeFieldName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[$]'), '').replaceAll(RegExp(r'[._\-]+'), ' ');
  final spaced = cleaned.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  final words = spaced.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return name;
  final lower = [for (final w in words) w.length > 1 && w == w.toUpperCase() ? w : w.toLowerCase()];
  final first = lower.first;
  lower[0] = first[0].toUpperCase() + first.substring(1);
  return lower.join(' ');
}
