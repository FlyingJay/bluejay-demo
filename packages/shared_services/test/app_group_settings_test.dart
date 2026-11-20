import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/app_group_settings.dart';

const _testRegistryJson = '''
{
  "apps": {
    "with-collection": {
      "collection": "with_collection_config",
      "settings": {
        "showBanner": {"type": "boolean", "default": false, "label": "Show banner"},
        "maxItems": {"type": "number", "default": 5, "min": 1, "max": 10.0, "label": "Max items"},
        "greeting": {"type": "string", "default": "Hi", "maxLength": 5, "label": "Greeting", "description": "Shown on top"},
        "tier": {"type": "enum", "default": "basic", "options": ["basic", "pro"], "label": "Tier"},
        "flowMode": {"type": "enum", "default": "a", "options": ["a", "b"], "label": "Flow", "field": "flowMode"},
        "nested": {"type": "boolean", "default": false, "label": "Nested", "field": "display.nested"}
      }
    },
    "no-collection": {
      "settings": {
        "enabled": {"type": "boolean", "default": true, "label": "Enabled"}
      }
    },
    "empty-collection": {"collection": "", "settings": {}}
  }
}
''';

class _GroupNotifier extends ChangeNotifier {
  String? groupId;
  _GroupNotifier(this.groupId);
  bool get listening => hasListeners;
  void setGroup(String? value) {
    groupId = value;
    notifyListeners();
  }
}

void main() {
  final registry = AppGroupSettingsRegistry.parse(_testRegistryJson);

  group('real functions/app_group_settings.json', () {
    // flutter test runs with the package directory as the cwd.
    final file = File('../../functions/app_group_settings.json');

    test('parses and validates with no problems', () {
      final real = AppGroupSettingsRegistry.parse(file.readAsStringSync());
      expect(real.apps, isNotEmpty);
      expect(real.validate(), isEmpty);
    });

    test('every app resolves to a doc path and full default values', () {
      final real = AppGroupSettingsRegistry.parse(file.readAsStringSync());
      for (final entry in real.apps.values) {
        final path = real.docPath(entry.appId, 'g1');
        expect(path.collection, isNotEmpty);
        final values = real.values(entry.appId, groupId: 'g1', stored: {});
        for (final def in entry.settings.values) {
          expect(values.value(def.key), def.defaultValue);
          expect(values.isDefault(def.key), isTrue);
        }
      }
    });

    test('reads field-mapped settings from their own location', () {
      final real = AppGroupSettingsRegistry.parse(file.readAsStringSync());
      for (final appId in ['rented-dwelling', 'course-of-construction']) {
        final entry = real.app(appId)!;
        expect(entry.editRequires, 'groupAdmin');
        expect(entry.settings['flowMode']!.fieldPath, 'flowMode');
        expect(entry.settingsScreen?.requires, 'admin');
        final values = real.values(
          appId,
          groupId: 'g1',
          stored: real.storedValues(appId, {
            'flowMode': 'quote_only',
            'settings': {'flowMode': 'quote_or_payment'},
          }),
        );
        expect(values.stringValue('flowMode'), 'quote_only');
        expect(values.isDefault('flowMode'), isFalse);
      }
    });

    test('apps with only a settings screen parse with no settings', () {
      final real = AppGroupSettingsRegistry.parse(file.readAsStringSync());
      final entry = real.app('warehouse-tables')!;
      expect(entry.settings, isEmpty);
      expect(entry.editRequires, 'appAdmin');
      expect(entry.settingsScreen?.label, 'Warehouse settings');
      expect(entry.settingsScreen?.requires, 'read');
    });
  });

  group('docPath (mirrors settingsDocPath)', () {
    test('uses the app collection with groupId as doc id', () {
      expect(
        registry.docPath('with-collection', 'acme'),
        const AppGroupSettingsDocPath('with_collection_config', 'acme'),
      );
    });

    test('falls back to app_group_settings/<groupId>__<appId>', () {
      expect(
        registry.docPath('no-collection', 'acme'),
        const AppGroupSettingsDocPath('app_group_settings', 'acme__no-collection'),
      );
      expect(
        registry.docPath('empty-collection', 'acme'),
        const AppGroupSettingsDocPath(
            'app_group_settings', 'acme__empty-collection'),
      );
      expect(
        registry.docPath('unregistered', 'acme'),
        const AppGroupSettingsDocPath('app_group_settings', 'acme__unregistered'),
      );
    });
  });

  group('valueError (mirrors _app_group_settings.js)', () {
    final defs = registry.app('with-collection')!.settings;

    test('boolean', () {
      expect(defs['showBanner']!.valueError(true), isNull);
      expect(defs['showBanner']!.valueError('true'), 'must be true or false');
    });

    test('number', () {
      final def = defs['maxItems']!;
      expect(def.valueError(3), isNull);
      expect(def.valueError(2.5), isNull);
      expect(def.valueError('3'), 'must be a number');
      expect(def.valueError(double.nan), 'must be a number');
      expect(def.valueError(double.infinity), 'must be a number');
      expect(def.valueError(0), 'must be at least 1');
      expect(def.valueError(11), 'must be at most 10');
    });

    test('string', () {
      final def = defs['greeting']!;
      expect(def.valueError('Hello'), isNull);
      expect(def.valueError(5), 'must be text');
      expect(def.valueError('Hello!'), 'must be at most 5 characters');
    });

    test('enum', () {
      final def = defs['tier']!;
      expect(def.valueError('pro'), isNull);
      expect(def.valueError('gold'), 'must be one of: basic, pro');
    });

    test('unknown type', () {
      const def = AppGroupSettingDefinition(
          key: 'x', type: 'date', label: 'X', defaultValue: null);
      expect(def.valueError('2020'), 'has unknown type "date"');
    });
  });

  group('AppGroupSettingsValues', () {
    test('valid stored values win over registry defaults', () {
      final values = registry.values('with-collection', groupId: 'g', stored: {
        'showBanner': true,
        'maxItems': 7,
        'greeting': 'Yo',
        'tier': 'pro',
      });
      expect(values.boolValue('showBanner'), isTrue);
      expect(values.numValue('maxItems'), 7);
      expect(values.stringValue('greeting'), 'Yo');
      expect(values.stringValue('tier'), 'pro');
      expect(values.isDefault('tier'), isFalse);
    });

    test('unset, null and invalid stored values resolve to the default', () {
      final values = registry.values('with-collection', groupId: 'g', stored: {
        'showBanner': 'yes',
        'maxItems': 99,
        'greeting': null,
      });
      expect(values.boolValue('showBanner'), isFalse);
      expect(values.numValue('maxItems'), 5);
      expect(values.stringValue('greeting'), 'Hi');
      expect(values.stringValue('tier'), 'basic');
      expect(values.isDefault('maxItems'), isTrue);
      expect(values.toMap(), {
        'showBanner': false,
        'maxItems': 5,
        'greeting': 'Hi',
        'tier': 'basic',
        'flowMode': 'a',
        'nested': false,
      });
    });

    test('unknown key throws in debug (asserts enabled in tests)', () {
      final values = registry.values('with-collection', groupId: 'g', stored: {});
      expect(() => values.boolValue('showBaner'), throwsArgumentError);
      expect(() => values.value('nope'), throwsArgumentError);
    });

    test('wrong accessor for the type throws in debug', () {
      final values = registry.values('with-collection', groupId: 'g', stored: {});
      expect(() => values.boolValue('maxItems'), throwsArgumentError);
      expect(() => values.numValue('tier'), throwsArgumentError);
    });

    test('undeclared app throws in debug', () {
      expect(
        () => registry.values('unregistered', groupId: 'g', stored: {}),
        throwsArgumentError,
      );
    });
  });

  group('validate (mirrors validateRegistry)', () {
    test('reports bad entries', () {
      final bad = AppGroupSettingsRegistry.fromMap({
        'apps': {
          'a': {
            'collection': 5,
            'editRequires': 'owner',
            'settingsScreen': {'label': ' ', 'requires': 'write'},
            'settings': {
              'badField': {
                'type': 'boolean',
                'default': false,
                'label': 'L',
                'field': 'settings..x'
              },
              'okField': {
                'type': 'boolean',
                'default': false,
                'label': 'L',
                'field': 'display.flag'
              },
              'bad-key': {'type': 'boolean', 'default': false, 'label': 'L'},
              'noType': {'type': 'date', 'default': 1, 'label': 'L'},
              'noLabel': {'type': 'boolean', 'default': true, 'label': ' '},
              'noDefault': {'type': 'boolean', 'label': 'L'},
              'noOptions': {'type': 'enum', 'default': 'x', 'label': 'L'},
              'badDefault': {
                'type': 'number',
                'default': 20,
                'max': 10,
                'label': 'L'
              },
            },
          },
        },
      });
      expect(bad.validate(), containsAll([
        'a: collection must be a non-empty string',
        'a: editRequires must be one of appAdmin, groupAdmin',
        'a: settingsScreen needs a label',
        'a: settingsScreen.requires must be one of read, edit, admin',
        'a.badField: field must be a dotted path of camelCase names',
        'a.bad-key: key must be camelCase alphanumeric',
        'a.noType: unknown type "date"',
        'a.noLabel: needs a label',
        'a.noDefault: needs a default',
        'a.noOptions: enum needs options',
        'a.badDefault: default must be at most 10',
      ]));
      expect(bad.validate(), isNot(contains(startsWith('a.okField'))));
      expect(
        AppGroupSettingsRegistry.fromMap({
          'apps': {
            'b': {'settingsScreen': null, 'editRequires': null},
          },
        }).validate(),
        [
          'b: editRequires must be one of appAdmin, groupAdmin',
          'b: settingsScreen needs a label',
          'b: settingsScreen.requires must be one of read, edit, admin',
        ],
      );
      // Like the JS, an empty collection string is flagged (and ignored by
      // docPath).
      expect(registry.validate(),
          ['empty-collection: collection must be a non-empty string']);
    });
  });

  group('watchWith', () {
    test('emits defaults with no group, then re-subscribes on group change',
        () async {
      final groups = _GroupNotifier(null);
      final docs = <String, StreamController<Map<String, dynamic>?>>{};
      final cancelled = <String>[];
      final stream = AppGroupSettings.watchWith(
        appId: 'with-collection',
        registry: Future.value(registry),
        currentGroupId: () => groups.groupId,
        groupChanges: groups,
        docData: (path) {
          final key = path.toString();
          final controller = StreamController<Map<String, dynamic>?>(
            onCancel: () => cancelled.add(key),
          );
          docs[key] = controller;
          return controller.stream;
        },
      );

      final emitted = <AppGroupSettingsValues>[];
      final sub = stream.listen(emitted.add);
      await pumpEventQueue();
      expect(emitted.single.groupId, isNull);
      expect(emitted.single.numValue('maxItems'), 5);

      groups.setGroup('acme');
      await pumpEventQueue();
      docs['with_collection_config/acme']!.add({
        'settings': {'maxItems': 8},
        'flowMode': 'b',
      });
      await pumpEventQueue();
      expect(emitted.last.groupId, 'acme');
      expect(emitted.last.numValue('maxItems'), 8);
      expect(emitted.last.stringValue('flowMode'), 'b');

      // Same group again: no resubscribe.
      groups.setGroup('acme');
      await pumpEventQueue();
      expect(docs.length, 1);

      groups.setGroup('other');
      await pumpEventQueue();
      expect(cancelled, ['with_collection_config/acme']);
      // A doc that doesn't exist yet emits null data.
      docs['with_collection_config/other']!.add(null);
      await pumpEventQueue();
      expect(emitted.last.groupId, 'other');
      expect(emitted.last.numValue('maxItems'), 5);

      await sub.cancel();
      expect(cancelled, contains('with_collection_config/other'));
      expect(groups.listening, isFalse);
    });
  });

  group('storedValues (mirrors storedValues)', () {
    test('reads settings.<key> by default and `field` when declared', () {
      expect(registry.storedValues('with-collection', null), isEmpty);
      expect(
          registry.storedValues('with-collection', {'settings': 'x'}), isEmpty);
      expect(
        registry.storedValues('with-collection', {
          'settings': {'maxItems': 7, 'flowMode': 'a', 'undeclared': 1},
          'flowMode': 'b',
          'display': {'nested': true},
          'groupId': 'g',
        }),
        {'maxItems': 7, 'flowMode': 'b', 'nested': true},
      );
    });

    test('a path through a non-map is absent', () {
      expect(
        registry.storedValues('with-collection', {'display': 'flat'}),
        isEmpty,
      );
    });

    test('fieldPath defaults to settings.<key>', () {
      final defs = registry.app('with-collection')!.settings;
      expect(defs['maxItems']!.fieldPath, 'settings.maxItems');
      expect(defs['nested']!.fieldPath, 'display.nested');
    });
  });
}
