import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:improve_bluejay/improve_apps_widgets.dart';
import 'package:improve_bluejay/request_change.dart';
import 'package:shared_services/active_group_pending.dart';

import 'support/fixtures.dart';

Future<void> _pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1000, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: BluejayTheme.build(), home: home));
  await t.pumpAndSettle();
}

void main() {
  group('ImproveAppsShell', () {
    testWidgets('the FAB files an idea on Ideas and a bug on Bugs', (t) async {
      final log = <String>[];
      await _pump(t, shellHarness(log: log));
      expect(find.text('New idea'), findsOneWidget);
      await t.tap(find.text('New idea'));
      expect(log, ['idea']);

      await t.tap(find.text('Bugs'));
      await t.pumpAndSettle();
      expect(find.text('Report a bug'), findsOneWidget);
      await t.tap(find.text('Report a bug'));
      expect(log, ['idea', 'bug']);
    });

    testWidgets('opens on the Bugs tab when asked', (t) async {
      await _pump(t, shellHarness(initialTab: ImproveAppsTab.bugs));
      expect(find.text('Report a bug'), findsOneWidget);
      expect(find.text('Upload stalls at 99%'), findsOneWidget);
    });

    testWidgets('the bell opens notification settings', (t) async {
      final log = <String>[];
      await _pump(t, shellHarness(log: log));
      await t.tap(find.byTooltip('Notification settings'));
      expect(log, ['settings']);
    });
  });

  group('NotificationSettingsView', () {
    testWidgets('toggles report their new value', (t) async {
      final changes = <String>[];
      await _pump(
        t,
        settingsPage(NotificationSettingsView(
          status: NotificationSettingsStatus.ready,
          preferences: const NotificationPreferences(bugs: true),
          stewardedAppNames: sampleStewardedApps,
          onBugsChanged: (v) => changes.add('bugs $v'),
          onIdeasChanged: (v) => changes.add('ideas $v'),
          onStewardedAppsChanged: (v) => changes.add('stewarded $v'),
        )),
      );
      await t.tap(find.text('Bug reports'));
      await t.tap(find.text('New ideas'));
      await t.tap(find.text('Requests from any group'));
      expect(changes, ['bugs false', 'ideas true', 'stewarded false']);
      expect(find.textContaining('Lists, Notes'), findsOneWidget);
    });

    testWidgets('hides the stewarded toggle without stewarded apps', (t) async {
      await _pump(
        t,
        settingsPage(const NotificationSettingsView(
            status: NotificationSettingsStatus.ready)),
      );
      expect(find.text('Requests from any group'), findsNothing);
      expect(find.byType(Switch), findsNWidgets(2));
    });

    testWidgets('null callbacks disable the toggles', (t) async {
      await _pump(
        t,
        settingsPage(const NotificationSettingsView(
            status: NotificationSettingsStatus.ready)),
      );
      for (final s in t.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
        expect(s.onChanged, isNull);
      }
    });

    testWidgets('loading, signed-out, no-group and error states', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: settingsPage(const NotificationSettingsView(
            status: NotificationSettingsStatus.loading)),
      ));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(BjSkeleton), findsWidgets);

      await _pump(
        t,
        settingsPage(const NotificationSettingsView(
            status: NotificationSettingsStatus.signedOut)),
      );
      expect(find.text('Sign in to manage notifications'), findsOneWidget);

      await _pump(
        t,
        settingsPage(const NotificationSettingsView(
            status: NotificationSettingsStatus.noGroup)),
      );
      expect(find.byType(ActiveGroupPending), findsOneWidget);

      var retried = 0;
      await _pump(
        t,
        settingsPage(NotificationSettingsView(
          status: NotificationSettingsStatus.error,
          onRetry: () => retried++,
        )),
      );
      expect(find.text("Couldn't load your notification settings"), findsOneWidget);
      await t.tap(find.text('Try again'));
      expect(retried, 1);
    });
  });

  group('choosers', () {
    Future<Object?> pick(WidgetTester t, Widget chooser, String option) async {
      Object? picked;
      await _pump(
        t,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await showBjSheet<Object>(
                  context,
                  title: 'Request a change',
                  builder: (_) => chooser,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text(option));
      await t.pumpAndSettle();
      return picked;
    }

    testWidgets('the in-app chooser offers a problem or an improvement', (t) async {
      expect(await pick(t, const RequestChangeChooser(), 'Report a problem'),
          AppTabAction.reportProblem);
      expect(await pick(t, const RequestChangeChooser(), 'Suggest an improvement'),
          AppTabAction.suggestImprovement);
      expect(find.text('Ask for a new app'), findsNothing);
      expect(find.textContaining('works'), findsNothing);
    });

    testWidgets('with a guide, the in-app chooser offers it first', (t) async {
      const chooser = RequestChangeChooser(guideAppName: 'Notes');
      expect(await pick(t, chooser, 'How Notes works'), AppTabAction.readGuide);
      expect(await pick(t, chooser, 'Report a problem'), AppTabAction.reportProblem);
    });

    testWidgets('with Help Desk, the chooser offers to contact the group', (t) async {
      const chooser = RequestChangeChooser(guideAppName: 'Notes', contactName: 'Corner Shop');
      expect(await pick(t, chooser, 'Contact Corner Shop'), AppTabAction.contactSupport);
      expect(await pick(t, chooser, 'Report a problem'), AppTabAction.reportProblem);
    });

    testWidgets('a guest\'s chooser offers the guide and Contact, never change requests', (t) async {
      const chooser = RequestChangeChooser(guideAppName: 'Notes', contactName: 'Corner Shop', offerRequests: false);
      expect(await pick(t, chooser, 'Contact Corner Shop'), AppTabAction.contactSupport);
      expect(find.text('Report a problem'), findsNothing);
      expect(find.text('Suggest an improvement'), findsNothing);
    });

    testWidgets('the new-request chooser returns each kind', (t) async {
      expect(await pick(t, const NewRequestChooser(), 'Report a problem'),
          NewRequestKind.problem);
      expect(await pick(t, const NewRequestChooser(), 'Suggest an improvement'),
          NewRequestKind.improvement);
    });
  });

  testWidgets('the success snack shows the message and its action', (t) async {
    var viewed = 0;
    await _pump(t, const Scaffold(body: SizedBox.shrink()));
    final messenger = t.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
    showRequestSuccessSnackBar(
      messenger,
      'Added to your queue: #2.',
      action: SnackBarAction(label: 'View', onPressed: () => viewed++),
    );
    await t.pumpAndSettle();
    expect(find.text('Added to your queue: #2.'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await t.tap(find.text('View'));
    expect(viewed, 1);
  });
}
