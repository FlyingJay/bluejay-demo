// Renders the Projects screens as PNGs with the real bundled fonts, for
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
import 'package:projects/project_detail_screen.dart';
import 'package:projects/project_widgets.dart';
import 'package:projects/projects_dashboard_screen.dart';

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

/// Opens a sheet over a blank page so it renders the way users see it.
class _SheetHost extends StatefulWidget {
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  const _SheetHost({required this.title, required this.subtitle, required this.builder});

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showBjSheet<void>(context, title: widget.title, subtitle: widget.subtitle, builder: widget.builder),
    );
  }

  @override
  Widget build(BuildContext context) => const BjPage(title: 'Projects', body: SizedBox.shrink());
}

void main() {
  setUpAll(() async {
    if (_enabled) await _loadFonts();
  });

  final sizes = {'phone': const Size(390, 2000), 'desktop': const Size(1280, 1400)};
  final screens = <String, Widget Function()>{
    'dashboard': () => DashboardHarness(projects: sampleProjects),
    'dashboard_empty': () => const DashboardHarness(projects: []),
    'dashboard_loading': () => const BjPage(title: 'Projects', body: ProjectsDashboardSkeleton()),
    'locked': () => const BjPage(
          title: 'Projects',
          body: BjStateView.locked(
            title: 'You do not have access to Projects in this group.',
            message: 'Ask a group admin if you think you should.',
          ),
        ),
    'detail': () => DetailHarness(tasks: sampleTasks),
    'project_form': () => _SheetHost(
          title: 'Edit project',
          subtitle: 'Capture your plan quickly with clearer inputs.',
          builder: (_) => ProjectFormSheet(
            project: sampleProjects.first,
            availableGroupTags: sampleTags,
            appsFuture: Future.value(sampleApps),
            canListClientGroups: false,
          ),
        ),
    'task_form': () => _SheetHost(
          title: 'Edit blocker task',
          subtitle: 'Capture what is blocking progress and keep momentum.',
          builder: (_) => TaskFormSheet(
            task: sampleTasks[3],
            defaultParentTaskId: null,
            availableParents: sampleTasks,
            getDescendants: (_, __) => const {},
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

