import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/automations_panel.dart';

const _catalog = {
  'canManageGroup': true,
  'apps': [
    {'appId': 'crm', 'name': 'CRM'},
  ],
  'events': [
    {'type': 'crm.deal.stage_changed', 'version': 1, 'appId': 'crm', 'label': 'A deal changes stage', 'fields': []},
  ],
  'actions': [
    {'type': 'notify', 'version': 1, 'label': 'Send a notification', 'params': []},
  ],
};

const _listing = {
  'rules': [
    {
      'id': 'r1',
      'appId': 'crm',
      'name': 'Tell me about stage changes',
      'enabled': true,
      'trigger': {'kind': 'event', 'type': 'crm.deal.stage_changed', 'version': 1},
      'actions': [
        {'type': 'notify', 'version': 1, 'params': {}},
      ],
    },
  ],
  'builtIns': [
    {
      'id': 'crm.follow_up',
      'appId': 'crm',
      'name': 'Follow-up reminders',
      'description': 'Reminds the owner on the follow-up date.',
      'enabled': false,
      'pausedReason': 'Its limit was reached',
      'trigger': {'kind': 'event', 'type': 'crm.deal.stage_changed', 'version': 1},
      'actions': [],
    },
  ],
};

class _FakeApi implements AutomationsApi {
  final Object? error;
  final bool canManage;
  final bool installed;
  final calls = <String>[];
  _FakeApi({this.error, this.canManage = true, this.installed = true});

  @override
  Future<AutomationsCatalog> catalog(String groupId) async {
    if (error != null) throw error!;
    return AutomationsCatalog.fromData({..._catalog, 'canManageGroup': canManage});
  }

  @override
  Future<AutomationsListing> list(String groupId, {String? appId}) async {
    calls.add('list:$appId');
    return AutomationsListing.fromData({..._listing, 'installed': installed});
  }

  @override
  Future<bool> setEnabled(String groupId, String ruleId, bool enabled) async {
    calls.add('setEnabled:$ruleId:$enabled');
    return enabled;
  }

  @override
  Future<BuiltInAutomation> setBuiltIn(String groupId, String builtInId, {bool? enabled, Map<String, dynamic>? adjust}) async {
    calls.add('setBuiltIn:$builtInId:$enabled');
    return BuiltInAutomation.fromData({'id': builtInId, 'enabled': enabled});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(Widget panel) => MaterialApp(
      theme: BluejayTheme.build(),
      home: BjPage(title: 'Settings', body: BjScrollBody(children: [panel])),
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {

  testWidgets('lists the app\'s rules and built-ins and switches them', (t) async {
    t.view.physicalSize = const Size(1000, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = _FakeApi();
    await t.pumpWidget(_host(AutomationsPanel(appId: 'crm', appName: 'CRM', groupId: 'acme', api: api)));
    await _settle(t);
    expect(api.calls, contains('list:crm'));
    expect(find.text('Tell me about stage changes'), findsOneWidget);
    expect(find.text('When a deal changes stage, send a notification.'), findsOneWidget);
    expect(find.text('Built in'), findsOneWidget);
    expect(find.textContaining('Paused: Its limit was reached'), findsOneWidget);
    await t.tap(find.byType(Switch).first);
    await _settle(t);
    await t.tap(find.byType(Switch).last);
    await _settle(t);
    expect(api.calls, containsAll(['setEnabled:r1:false', 'setBuiltIn:crm.follow_up:true']));
  });

  testWidgets('shows nothing to people who cannot manage automations', (t) async {
    await t.pumpWidget(_host(AutomationsPanel(
      appId: 'crm',
      groupId: 'acme',
      api: _FakeApi(error: const AutomationsException('permission-denied', 'no')),
    )));
    await _settle(t);
    expect(find.text('Automations'), findsNothing);

    await t.pumpWidget(_host(AutomationsPanel(appId: 'crm', groupId: 'acme', api: _FakeApi(canManage: false))));
    await _settle(t);
    expect(find.text('Automations'), findsNothing);
  });

  testWidgets('the settings page explains instead of hiding', (t) async {
    await t.pumpWidget(_host(AutomationsPanel(
      appId: 'crm',
      groupId: 'acme',
      hideWhenUnavailable: false,
      api: _FakeApi(error: const AutomationsException('permission-denied', 'no')),
    )));
    await _settle(t);
    expect(find.text('Automations are set up by admins'), findsOneWidget);
  });

  testWidgets('New automation opens the app on a new rule for this app', (t) async {
    t.view.physicalSize = const Size(1000, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final opened = <String>[];
    await t.pumpWidget(_host(AutomationsPanel(
      appId: 'crm',
      groupId: 'acme',
      api: _FakeApi(),
      openApp: (context, appId, args) {
        opened.add('$appId $args');
        return true;
      },
    )));
    await _settle(t);
    await t.tap(find.text('New automation'));
    await _settle(t);
    expect(opened, ['automations {app: crm, new: 1}']);
  });

  testWidgets('without the app installed it points to Add Apps', (t) async {
    t.view.physicalSize = const Size(1000, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final opened = <String>[];
    await t.pumpWidget(_host(AutomationsPanel(
      appId: 'crm',
      groupId: 'acme',
      api: _FakeApi(installed: false),
      openApp: (context, appId, args) {
        opened.add(appId);
        return true;
      },
    )));
    await _settle(t);
    await t.tap(find.text('Open Automations'));
    await _settle(t);
    expect(find.text('Automations isn\'t installed'), findsOneWidget);
    await t.tap(find.text('Open Add Apps'));
    await _settle(t);
    expect(opened, ['add-apps']);
  });

  testWidgets('the header button shows only when automationsList answers', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: const Scaffold(body: SizedBox()),
    ));
    await t.pumpWidget(MaterialApp(
      theme: BluejayTheme.build(),
      home: Scaffold(
        appBar: AppBar(actions: [
          AutomationsHeaderButton(appId: 'crm', appName: 'CRM', groupId: 'acme', api: _FakeApi()),
          AutomationsHeaderButton(
            appId: 'lists',
            appName: 'Lists',
            groupId: 'acme',
            api: _DeniedListApi(),
          ),
        ]),
      ),
    ));
    await _settle(t);
    expect(find.byTooltip('Automations'), findsOneWidget);
  });
}

class _DeniedListApi extends _FakeApi {
  @override
  Future<AutomationsListing> list(String groupId, {String? appId}) async =>
      throw const AutomationsException('permission-denied', 'no');
}
