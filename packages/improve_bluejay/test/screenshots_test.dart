// Renders the Improve Apps screens as PNGs with the real bundled fonts, for
// design review. Off by default (pixels depend on the host's font
// rendering). Run with:
//
//   BJ_DESIGN_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
//
// Output: test/screenshots/out/*.png (git-ignored).

import 'dart:io';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:bluejay_design/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:improve_bluejay/improve_apps_widgets.dart';
import 'package:improve_bluejay/request_change.dart';

import 'support/fixtures.dart';

final _enabled = Platform.environment['BJ_DESIGN_SCREENSHOTS'] == '1';

Future<void> _loadFonts() async {
  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  const fonts = '../../assets/fonts';
  await loadBjFonts(fonts);
  final root = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await (FontLoader('MaterialIcons')
        ..addFont(file('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')))
      .load();
}

/// Runs [onReady] over the Improve Apps shell once it's laid out, so sheets
/// and snacks render the way users see them.
class _Host extends StatefulWidget {
  final void Function(BuildContext context) onReady;

  const _Host({required this.onReady});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady(context));
  }

  @override
  Widget build(BuildContext context) => shellHarness();
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {'phone': const Size(390, 844), 'desktop': const Size(1280, 860)};
  final screens = <String, Widget Function()>{
    'shell_ideas': () => shellHarness(),
    'shell_bugs': () => shellHarness(initialTab: ImproveAppsTab.bugs),
    'notifications': () => settingsPage(NotificationSettingsView(
          status: NotificationSettingsStatus.ready,
          preferences: const NotificationPreferences(bugs: true),
          stewardedAppNames: sampleStewardedApps,
          onBugsChanged: (_) {},
          onIdeasChanged: (_) {},
          onStewardedAppsChanged: (_) {},
        )),
    'notifications_loading': () =>
        settingsPage(const NotificationSettingsView(status: NotificationSettingsStatus.loading)),
    'notifications_error': () =>
        settingsPage(NotificationSettingsView(status: NotificationSettingsStatus.error, onRetry: () {})),
    'new_request_sheet': () => _Host(
          onReady: (context) => showBjSheet<void>(
            context,
            title: 'Request a change',
            subtitle: 'Ask for what would save you time. It joins your queue and you can follow it here.',
            builder: (_) => const NewRequestChooser(),
          ),
        ),
    'request_change_sheet': () => _Host(
          onReady: (context) => showBjSheet<void>(
            context,
            title: 'Request a change to Lists',
            subtitle: 'Tell us what would make it better. Your request goes straight to the people who build it.',
            builder: (_) => const RequestChangeChooser(),
          ),
        ),
    'help_sheet': () => _Host(
          onReady: (context) => showBjSheet<void>(
            context,
            title: 'Help with Lists',
            subtitle: 'Read how it works, or tell the people who build it what would make it better.',
            builder: (_) => const RequestChangeChooser(guideAppName: 'Lists'),
          ),
        ),
    'queue_confirmation': () => _Host(
          onReady: (context) => showRequestSuccessSnackBar(
            ScaffoldMessenger.of(context),
            'Added to your queue: #2. Takes a little longer than a small change.',
            action: SnackBarAction(label: 'View', onPressed: () {}),
          ),
        ),
  };

  for (final size in sizes.entries) {
    for (final screen in screens.entries) {
      testWidgets('${screen.key} ${size.key}', (t) async {
        t.view.physicalSize = size.value * 2;
        t.view.devicePixelRatio = 2;
        FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BluejayTheme.build(),
          home: screen.value(),
        ));
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('screenshots/out/${screen.key}_${size.key}.png'),
        );
        t.view.reset();
      }, skip: !_enabled);
    }
  }
}
