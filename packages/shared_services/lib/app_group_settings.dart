import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'active_group_service.dart';
import 'bluejay_firestore.dart';

/// Per-group app settings: how one shared app behaves differently for the
/// groups that use it, without forking code or branching on a groupId.
///
/// Every setting is declared once, in `functions/app_group_settings.json`
/// (bundled as an app asset and also read by Cloud Functions), with its type
/// and **default**. Call sites never supply their own default — an unset or
/// invalid stored value always resolves to the registry default, exactly like
/// `resolveValues` in `functions/_app_group_settings.js`.
///
/// ```dart
/// StreamBuilder<AppGroupSettingsValues>(
///   stream: AppGroupSettings.watch('commercial-property'),
///   builder: (context, snapshot) {
///     final settings = snapshot.data;
///     if (settings == null) return const SizedBox.shrink();
///     if (settings.boolValue('showCrimeCoverage')) { ... }
///   },
/// );
/// ```
///
/// Values are written only by the `appGroupSettingsUpdate` callable (group
/// app admins, via the Groups app's "App settings" screen) — this class is
/// read-only.
class AppGroupSettings {
  AppGroupSettings._();

  static Future<AppGroupSettingsRegistry>? _registry;

  /// The bundled registry, loaded from [rootBundle] and parsed once per
  /// process. A failed load isn't cached, so the next caller retries.
  static Future<AppGroupSettingsRegistry> registry() {
    final cached = _registry;
    if (cached != null) return cached;
    final loading = AppGroupSettingsRegistry.load();
    _registry = loading;
    loading.then<void>((_) {}, onError: (Object _) {
      if (identical(_registry, loading)) _registry = null;
    });
    return loading;
  }

  /// Replaces the cached registry (tests, or callers that already parsed it).
  @visibleForTesting
  static void debugSetRegistry(AppGroupSettingsRegistry? registry) {
    _registry = registry == null ? null : Future.value(registry);
  }

  /// Settings for [appId] in the **active** group, re-subscribing whenever
  /// [ActiveGroupService.activeGroupId] changes. With no active group the
  /// stream emits pure defaults (`groupId == null`).
  static Stream<AppGroupSettingsValues> watch(String appId) {
    final active = ActiveGroupService.instance;
    return watchWith(
      appId: appId,
      registry: registry(),
      currentGroupId: () => active.activeGroupId,
      groupChanges: active,
      docData: (path) => _firestoreDocData(appId, path),
    );
  }

  /// Settings for [appId] in an explicit [groupId] (not the active group).
  static Stream<AppGroupSettingsValues> watchGroup(
    String appId,
    String groupId,
  ) {
    return watchWith(
      appId: appId,
      registry: registry(),
      currentGroupId: () => groupId,
      docData: (path) => _firestoreDocData(appId, path),
    );
  }

  /// One-shot read of [appId]'s settings in [groupId] (default: the active
  /// group).
  static Future<AppGroupSettingsValues> get(
    String appId, {
    String? groupId,
  }) async {
    final resolvedGroupId = groupId ?? ActiveGroupService.instance.activeGroupId;
    final reg = await registry();
    if (resolvedGroupId == null || resolvedGroupId.isEmpty) {
      return reg.values(appId, groupId: null, stored: const {});
    }
    final path = reg.docPath(appId, resolvedGroupId);
    final snap = await BluejayFirestore.forApp(appId)
        .collection(path.collection)
        .doc(path.docId)
        .get();
    return reg.values(
      appId,
      groupId: resolvedGroupId,
      stored: reg.storedValues(appId, snap.data()),
    );
  }

  /// [appId]'s settings doc at [path]; its reads are attributed to [appId].
  static Stream<Map<String, dynamic>?> _firestoreDocData(
    String appId,
    AppGroupSettingsDocPath path,
  ) {
    return BluejayFirestore.forApp(appId)
        .collection(path.collection)
        .doc(path.docId)
        .snapshots()
        .map((snap) => snap.data());
  }

  /// [watch] with every Firebase/singleton dependency injected, so the
  /// group-switching behavior is testable.
  ///
  /// Emits pure defaults while [currentGroupId] is null/empty, otherwise the
  /// resolved values of that group's settings doc (as emitted by [docData],
  /// read through [AppGroupSettingsRegistry.storedValues]); when
  /// [groupChanges] fires with a different group, the previous doc
  /// subscription is cancelled and the new group's doc is watched.
  @visibleForTesting
  static Stream<AppGroupSettingsValues> watchWith({
    required String appId,
    required Future<AppGroupSettingsRegistry> registry,
    required String? Function() currentGroupId,
    Listenable? groupChanges,
    required Stream<Map<String, dynamic>?> Function(AppGroupSettingsDocPath path)
        docData,
  }) {
    late StreamController<AppGroupSettingsValues> controller;
    AppGroupSettingsRegistry? reg;
    StreamSubscription<Map<String, dynamic>?>? docSub;
    String? subscribedGroupId;
    var started = false;
    var closed = false;

    void subscribeOrThrow() {
      final r = reg;
      if (r == null || closed) return;
      final raw = currentGroupId();
      final groupId = (raw == null || raw.isEmpty) ? null : raw;
      if (started && groupId == subscribedGroupId) return;
      started = true;
      subscribedGroupId = groupId;
      docSub?.cancel();
      docSub = null;
      if (groupId == null) {
        controller.add(r.values(appId, groupId: null, stored: const {}));
        return;
      }
      docSub = docData(r.docPath(appId, groupId)).listen(
        (data) => controller.add(r.values(
          appId,
          groupId: groupId,
          stored: r.storedValues(appId, data),
        )),
        onError: controller.addError,
      );
    }

    void subscribe() {
      try {
        subscribeOrThrow();
      } catch (error, stack) {
        // e.g. the debug-mode ArgumentError for an undeclared appId.
        if (!closed) controller.addError(error, stack);
      }
    }

    controller = StreamController<AppGroupSettingsValues>(
      onListen: () {
        groupChanges?.addListener(subscribe);
        registry.then((loaded) {
          reg = loaded;
          subscribe();
        }, onError: (Object error, StackTrace stack) {
          if (!closed) controller.addError(error, stack);
        });
      },
      onCancel: () async {
        closed = true;
        groupChanges?.removeListener(subscribe);
        await docSub?.cancel();
      },
    );
    return controller.stream;
  }
}

/// Where one app's per-group settings doc lives.
@immutable
class AppGroupSettingsDocPath {
  final String collection;
  final String docId;

  const AppGroupSettingsDocPath(this.collection, this.docId);

  @override
  bool operator ==(Object other) =>
      other is AppGroupSettingsDocPath &&
      other.collection == collection &&
      other.docId == docId;

  @override
  int get hashCode => Object.hash(collection, docId);

  @override
  String toString() => '$collection/$docId';
}

/// The parsed `functions/app_group_settings.json`.
class AppGroupSettingsRegistry {
  /// Asset key of the bundled registry (declared in the root pubspec).
  static const String assetPath = 'functions/app_group_settings.json';

  /// Collection for apps that don't name their own per-group config
  /// collection; doc id is `<groupId>__<appId>`.
  static const String defaultCollection = 'app_group_settings';

  static const List<String> settingTypes = [
    'boolean',
    'number',
    'string',
    'enum',
  ];

  /// Allowed `editRequires` values: the group's `:admin` tier for the app
  /// (`appAdmin`, the default) or `groups/{groupId}.adminIds` (`groupAdmin`).
  static const List<String> editRequirements = ['appAdmin', 'groupAdmin'];

  /// Allowed `settingsScreen.requires` values (the app tier needed to open it).
  static const List<String> screenTiers = ['read', 'edit', 'admin'];

  /// A setting's `field`: a dotted path of camelCase names.
  static final RegExp fieldPattern =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*)*$');

  static const AppGroupSettingsRegistry empty = AppGroupSettingsRegistry._({});

  final Map<String, AppGroupSettingsAppEntry> apps;

  const AppGroupSettingsRegistry._(this.apps);

  /// Parses the registry's JSON text.
  factory AppGroupSettingsRegistry.parse(String source) {
    final decoded = jsonDecode(source);
    return AppGroupSettingsRegistry.fromMap(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
  }

  factory AppGroupSettingsRegistry.fromMap(Map<String, dynamic> data) {
    final rawApps = data['apps'];
    final apps = <String, AppGroupSettingsAppEntry>{};
    if (rawApps is Map) {
      rawApps.forEach((appId, entry) {
        if (appId is String && entry is Map) {
          apps[appId] = AppGroupSettingsAppEntry.fromMap(
            appId,
            Map<String, dynamic>.from(entry),
          );
        }
      });
    }
    return AppGroupSettingsRegistry._(Map.unmodifiable(apps));
  }

  /// Loads the bundled registry from [bundle] (default: [rootBundle]).
  static Future<AppGroupSettingsRegistry> load({AssetBundle? bundle}) async {
    final source = await (bundle ?? rootBundle).loadString(assetPath);
    return AppGroupSettingsRegistry.parse(source);
  }

  AppGroupSettingsAppEntry? app(String appId) => apps[appId];

  /// Where [groupId]'s settings for [appId] live — mirrors `settingsDocPath`
  /// in `functions/_app_group_settings.js`.
  AppGroupSettingsDocPath docPath(String appId, String groupId) {
    final collection = apps[appId]?.collection;
    return collection != null
        ? AppGroupSettingsDocPath(collection, groupId)
        : AppGroupSettingsDocPath(defaultCollection, '${groupId}__$appId');
  }

  /// Stored values for [appId]'s declared settings, each read from its own
  /// location in a settings doc's [data] (its `field`, else
  /// `settings.<key>`) — mirrors `storedValues` in
  /// `functions/_app_group_settings.js`. Keys absent from the doc are left
  /// out, so they resolve to their defaults.
  Map<String, dynamic> storedValues(String appId, Map<String, dynamic>? data) {
    final stored = <String, dynamic>{};
    final settings = apps[appId]?.settings ?? const {};
    for (final def in settings.values) {
      final found = _readPath(data, def.fieldPath);
      if (found.present) stored[def.key] = found.value;
    }
    return stored;
  }

  static ({bool present, Object? value}) _readPath(
    Map<String, dynamic>? data,
    String path,
  ) {
    Object? current = data;
    for (final part in path.split('.')) {
      if (current is! Map || !current.containsKey(part)) {
        return (present: false, value: null);
      }
      current = current[part];
    }
    return (present: true, value: current);
  }

  /// Resolved values for [appId] from its stored values (keyed by setting
  /// key — see [storedValues]).
  AppGroupSettingsValues values(
    String appId, {
    required String? groupId,
    required Map<String, dynamic> stored,
  }) {
    final entry = apps[appId];
    assert(() {
      if (entry == null) {
        throw ArgumentError.value(
          appId,
          'appId',
          'is not declared in ${AppGroupSettingsRegistry.assetPath}',
        );
      }
      return true;
    }());
    return AppGroupSettingsValues(
      appId: appId,
      groupId: groupId,
      definitions: entry?.settings ?? const {},
      stored: stored,
    );
  }

  /// Problems with the registry itself (empty = valid) — mirrors
  /// `validateRegistry` in `functions/_app_group_settings.js`.
  List<String> validate() {
    final problems = <String>[];
    final keyPattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9]*$');
    for (final entry in apps.values) {
      if (entry.rawCollection != null &&
          (entry.rawCollection is! String ||
              (entry.rawCollection as String).isEmpty)) {
        problems.add('${entry.appId}: collection must be a non-empty string');
      }
      if (entry.hasEditRequires &&
          !editRequirements.contains(entry.rawEditRequires)) {
        problems.add(
          '${entry.appId}: editRequires must be one of '
          '${editRequirements.join(', ')}',
        );
      }
      if (entry.hasSettingsScreen) {
        final screen = entry.rawSettingsScreen;
        final label = screen is Map ? screen['label'] : null;
        if (label is! String || label.trim().isEmpty) {
          problems.add('${entry.appId}: settingsScreen needs a label');
        }
        final requires = screen is Map ? screen['requires'] : null;
        if (!screenTiers.contains(requires)) {
          problems.add(
            '${entry.appId}: settingsScreen.requires must be one of '
            '${screenTiers.join(', ')}',
          );
        }
      }
      for (final def in entry.settings.values) {
        final where = '${entry.appId}.${def.key}';
        if (!keyPattern.hasMatch(def.key)) {
          problems.add('$where: key must be camelCase alphanumeric');
        }
        if (!settingTypes.contains(def.type)) {
          problems.add('$where: unknown type "${def.type}"');
        }
        if (def.label.trim().isEmpty) problems.add('$where: needs a label');
        if (!def.hasDefault) problems.add('$where: needs a default');
        if (def.hasField &&
            (def.rawField is! String ||
                !fieldPattern.hasMatch(def.rawField as String))) {
          problems.add('$where: field must be a dotted path of camelCase names');
        }
        if (def.type == 'enum' && (def.options?.isEmpty ?? true)) {
          problems.add('$where: enum needs options');
        }
        if (def.hasDefault && settingTypes.contains(def.type)) {
          final error = def.valueError(def.defaultValue);
          if (error != null) problems.add('$where: default $error');
        }
      }
    }
    return problems;
  }
}

/// One app's entry in the registry.
class AppGroupSettingsAppEntry {
  final String appId;

  /// The app's own per-group config collection (doc id = groupId), or null
  /// to use [AppGroupSettingsRegistry.defaultCollection].
  final String? collection;

  /// The raw `collection` value, kept only for [AppGroupSettingsRegistry.validate].
  final Object? rawCollection;

  /// Declared settings, in registry order.
  final Map<String, AppGroupSettingDefinition> settings;

  /// Who may change this app's settings: `appAdmin` (the group's `:admin`
  /// tier for the app, the default) or `groupAdmin`
  /// (`groups/{groupId}.adminIds`, for apps whose own save path checks that).
  final String editRequires;

  /// Whether the entry declares `editRequires` at all, and its raw value —
  /// kept only for [AppGroupSettingsRegistry.validate].
  final bool hasEditRequires;
  final Object? rawEditRequires;

  /// The app's own settings screen, linked from the App settings screen for
  /// options too rich for a simple form; null when it declares none.
  final AppGroupSettingsScreenLink? settingsScreen;

  /// Whether the entry declares `settingsScreen` at all, and its raw value —
  /// kept only for [AppGroupSettingsRegistry.validate].
  final bool hasSettingsScreen;
  final Object? rawSettingsScreen;

  const AppGroupSettingsAppEntry({
    required this.appId,
    required this.collection,
    required this.settings,
    this.rawCollection,
    this.editRequires = 'appAdmin',
    this.hasEditRequires = false,
    this.rawEditRequires,
    this.settingsScreen,
    this.hasSettingsScreen = false,
    this.rawSettingsScreen,
  });

  factory AppGroupSettingsAppEntry.fromMap(
    String appId,
    Map<String, dynamic> data,
  ) {
    final rawCollection = data['collection'];
    final rawSettings = data['settings'];
    final rawEditRequires = data['editRequires'];
    final rawSettingsScreen = data['settingsScreen'];
    final settings = <String, AppGroupSettingDefinition>{};
    if (rawSettings is Map) {
      rawSettings.forEach((key, def) {
        if (key is String && def is Map) {
          settings[key] = AppGroupSettingDefinition.fromMap(
            key,
            Map<String, dynamic>.from(def),
          );
        }
      });
    }
    return AppGroupSettingsAppEntry(
      appId: appId,
      // Truthiness like the JS: an empty string means "no collection".
      collection: rawCollection is String && rawCollection.isNotEmpty
          ? rawCollection
          : null,
      rawCollection: rawCollection,
      settings: Map.unmodifiable(settings),
      editRequires: rawEditRequires == 'groupAdmin' ? 'groupAdmin' : 'appAdmin',
      hasEditRequires: data.containsKey('editRequires'),
      rawEditRequires: rawEditRequires,
      settingsScreen: rawSettingsScreen is Map
          ? AppGroupSettingsScreenLink.fromMap(
              Map<String, dynamic>.from(rawSettingsScreen),
            )
          : null,
      hasSettingsScreen: data.containsKey('settingsScreen'),
      rawSettingsScreen: rawSettingsScreen,
    );
  }
}

/// An app's `settingsScreen` registry entry: a link from the App settings
/// screen to the app's own settings screen.
@immutable
class AppGroupSettingsScreenLink {
  final String label;
  final String description;

  /// The app tier needed to open it: `read`, `edit` or `admin`.
  final String requires;

  const AppGroupSettingsScreenLink({
    required this.label,
    required this.description,
    required this.requires,
  });

  factory AppGroupSettingsScreenLink.fromMap(Map<String, dynamic> data) {
    final label = data['label'];
    final description = data['description'];
    final requires = data['requires'];
    return AppGroupSettingsScreenLink(
      label: label is String ? label : '',
      description: description is String ? description : '',
      requires: requires is String ? requires : '',
    );
  }
}

/// One declared setting — from the registry, or from an
/// `appGroupSettingsGet` response (which spreads the same fields).
@immutable
class AppGroupSettingDefinition {
  final String key;

  /// `boolean`, `number`, `string` or `enum`.
  final String type;
  final String label;
  final String? description;
  final bool hasDefault;
  final Object? defaultValue;
  final num? min;
  final num? max;
  final int? maxLength;
  final List<Object?>? options;

  /// Where the value lives in its settings doc when not `settings.<key>`: a
  /// top-level or dotted path the app already reads (e.g. `flowMode`).
  final String? field;

  /// Whether the definition declares `field` at all, and its raw value —
  /// kept only for [AppGroupSettingsRegistry.validate].
  final bool hasField;
  final Object? rawField;

  const AppGroupSettingDefinition({
    required this.key,
    required this.type,
    required this.label,
    this.description,
    this.hasDefault = true,
    required this.defaultValue,
    this.min,
    this.max,
    this.maxLength,
    this.options,
    this.field,
    this.hasField = false,
    this.rawField,
  });

  /// Where this setting's value lives in its doc: its own [field], else
  /// `settings.<key>` — mirrors `fieldPath` in
  /// `functions/_app_group_settings.js`.
  String get fieldPath => field ?? 'settings.$key';

  factory AppGroupSettingDefinition.fromMap(
    String key,
    Map<String, dynamic> data,
  ) {
    final description = data['description'];
    final maxLength = data['maxLength'];
    final options = data['options'];
    final field = data['field'];
    return AppGroupSettingDefinition(
      key: key,
      type: data['type'] is String ? data['type'] as String : '',
      label: data['label'] is String ? data['label'] as String : '',
      description: description is String && description.trim().isNotEmpty
          ? description
          : null,
      hasDefault: data.containsKey('default'),
      defaultValue: data['default'],
      min: data['min'] is num ? data['min'] as num : null,
      max: data['max'] is num ? data['max'] as num : null,
      maxLength: maxLength is num ? maxLength.toInt() : null,
      options: options is List ? List<Object?>.unmodifiable(options) : null,
      // Truthiness like the JS: an empty string means "settings.<key>".
      field: field is String && field.isNotEmpty ? field : null,
      hasField: data.containsKey('field'),
      rawField: field,
    );
  }

  /// Why [value] isn't valid for this setting, or null — the same messages
  /// as `valueError` in `functions/_app_group_settings.js`.
  String? valueError(Object? value) {
    switch (type) {
      case 'boolean':
        return value is bool ? null : 'must be true or false';
      case 'number':
        if (value is! num || !value.isFinite) return 'must be a number';
        if (min != null && value < min!) return 'must be at least ${_fmt(min!)}';
        if (max != null && value > max!) return 'must be at most ${_fmt(max!)}';
        return null;
      case 'string':
        if (value is! String) return 'must be text';
        if (maxLength != null && value.length > maxLength!) {
          return 'must be at most $maxLength characters';
        }
        return null;
      case 'enum':
        final opts = options ?? const [];
        return opts.contains(value)
            ? null
            : 'must be one of: ${opts.join(', ')}';
      default:
        return 'has unknown type "$type"';
    }
  }

  /// [stored] when it's a valid value, else [defaultValue].
  Object? resolve(Object? stored) =>
      stored != null && valueError(stored) == null ? stored : defaultValue;

  // JS renders 5.0 as "5"; keep messages identical to the server's.
  static String _fmt(num n) =>
      n is double && n == n.truncateToDouble() && n.isFinite
          ? n.toInt().toString()
          : n.toString();
}

/// Resolved settings for one app in one group.
///
/// Every accessor returns the stored value when valid, otherwise the
/// registry default. Asking for a key the app doesn't declare (or with the
/// wrong accessor for its type) throws an [ArgumentError] in debug builds so
/// typos surface during development; release builds fall back to `false` /
/// `0` / `''`.
class AppGroupSettingsValues {
  final String appId;

  /// The group these values belong to, or null when no group is active
  /// (all values are defaults).
  final String? groupId;

  final Map<String, AppGroupSettingDefinition> definitions;
  final Map<String, dynamic> _stored;

  AppGroupSettingsValues({
    required this.appId,
    required this.groupId,
    required this.definitions,
    required Map<String, dynamic> stored,
  }) : _stored = Map.unmodifiable(stored);

  /// The resolved value of [key] (any type); null for an undeclared key in
  /// release builds.
  Object? value(String key) {
    final def = _definition(key, null);
    return def?.resolve(_stored[key]);
  }

  /// Whether [key] is unset or invalid in this group (so reads its default).
  bool isDefault(String key) {
    final def = _definition(key, null);
    return def == null || def.valueError(_stored[key]) != null;
  }

  /// A `boolean` setting.
  bool boolValue(String key) {
    final value = _definition(key, const ['boolean'])?.resolve(_stored[key]);
    return value is bool ? value : false;
  }

  /// A `number` setting.
  num numValue(String key) {
    final value = _definition(key, const ['number'])?.resolve(_stored[key]);
    return value is num ? value : 0;
  }

  /// A `string` or `enum` setting.
  String stringValue(String key) {
    final value =
        _definition(key, const ['string', 'enum'])?.resolve(_stored[key]);
    return value is String ? value : (value?.toString() ?? '');
  }

  /// Every declared setting's resolved value.
  Map<String, Object?> toMap() => {
        for (final entry in definitions.entries)
          entry.key: entry.value.resolve(_stored[entry.key]),
      };

  AppGroupSettingDefinition? _definition(String key, List<String>? types) {
    final def = definitions[key];
    assert(() {
      if (def == null) {
        throw ArgumentError.value(
          key,
          'key',
          'is not a setting of $appId in ${AppGroupSettingsRegistry.assetPath}',
        );
      }
      if (types != null && !types.contains(def.type)) {
        throw ArgumentError.value(
          key,
          'key',
          'is a ${def.type} setting of $appId, not ${types.join('/')}',
        );
      }
      return true;
    }());
    if (def == null || (types != null && !types.contains(def.type))) {
      return null;
    }
    return def;
  }

  @override
  String toString() => 'AppGroupSettingsValues($appId, $groupId, ${toMap()})';
}
