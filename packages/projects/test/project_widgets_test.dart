import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:projects/models.dart';
import 'package:projects/project_styles.dart';
import 'package:projects/project_widgets.dart';

import 'support/fixtures.dart';

Future<void> _setSize(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('status styles', () {
    test('every status has a style', () {
      for (final s in ProjectStatus.values) {
        expect(projectStatusStyles[s], isNotNull);
      }
      for (final s in BlockerStatus.values) {
        expect(blockerStatusStyles[s], isNotNull);
      }
      for (final s in ChangeRequestState.values) {
        expect(changeRequestStateStyles[s]!.label, changeRequestStateLabel(s));
      }
    });

    test('labels match the ones the app has always shown', () {
      expect(projectStatusStyle(ProjectStatus.onHold).label, 'On hold');
      expect(blockerStatusStyle(BlockerStatus.inProgress).label, 'In progress');
    });
  });

  group('filterAndSortProjects', () {
    test('open projects first, then by due date, undated last', () {
      final sorted = filterAndSortProjects(sampleProjects);
      expect(sorted.map((p) => p.id), ['p2', 'p1', 'p4', 'p3']);
    });

    test('status and every selected tag must match', () {
      expect(filterAndSortProjects(sampleProjects, status: ProjectStatus.completed).map((p) => p.id), ['p3']);
      expect(filterAndSortProjects(sampleProjects, tagKeys: {'launch', 'underwriting'}).map((p) => p.id), ['p1']);
      expect(filterAndSortProjects(sampleProjects, tagKeys: {'launch', 'urgent'}), isEmpty);
    });
  });

  group('dashboard body', () {
    testWidgets('shows projects with counts, pills and next action', (t) async {
      await _setSize(t, const Size(390, 2400));
      await t.pumpWidget(themed(DashboardHarness(projects: sampleProjects)));
      await t.pump(const Duration(milliseconds: 500));

      expect(find.text('All · 4'), findsOneWidget);
      expect(find.text('On hold · 1'), findsOneWidget);
      expect(find.byType(ProjectCard), findsNWidgets(4));
      expect(find.text('Rented Dwelling'), findsOneWidget);
      expect(find.text('Globex'), findsOneWidget);
      expect(find.textContaining('Rating engine signs off on landlord rates', findRichText: true), findsOneWidget);
      expect(find.text('No actionable blocker right now.'), findsNWidgets(2));
      expect(find.text('Overdue 2026-11-02'), findsOneWidget);
    });

    testWidgets('status filter narrows the list and can be cleared', (t) async {
      await _setSize(t, const Size(390, 2400));
      await t.pumpWidget(themed(DashboardHarness(projects: sampleProjects)));
      await t.pump(const Duration(milliseconds: 500));

      await t.ensureVisible(find.text('Completed · 1'));
      await t.tap(find.text('Completed · 1'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(ProjectCard), findsOneWidget);
      expect(find.text('Completed projects'), findsOneWidget);

      await t.ensureVisible(find.text('urgent'));
      await t.tap(find.text('urgent'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('No projects match these filters'), findsOneWidget);

      await t.tap(find.text('Clear filters').first);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(ProjectCard), findsNWidgets(4));
    });

    testWidgets('empty group offers to create a project', (t) async {
      await _setSize(t, const Size(390, 1200));
      await t.pumpWidget(themed(const DashboardHarness(projects: [])));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('No projects yet'), findsOneWidget);
      expect(find.text('Create project'), findsOneWidget);
    });

    testWidgets('desktop lays cards out two to a row', (t) async {
      await _setSize(t, const Size(1280, 1600));
      await t.pumpWidget(themed(DashboardHarness(projects: sampleProjects)));
      await t.pump(const Duration(milliseconds: 500));
      final cards = find.byType(ProjectCard);
      expect(t.getTopLeft(cards.at(0)).dy, t.getTopLeft(cards.at(1)).dy);
      expect(t.getSize(cards.at(0)).height, t.getSize(cards.at(1)).height);
      expect(t.getTopLeft(cards.at(2)).dy, greaterThan(t.getTopLeft(cards.at(0)).dy));
    });
  });

  group('detail body', () {
    testWidgets('summarises progress, next tasks and the nested tree', (t) async {
      await _setSize(t, const Size(390, 3000));
      await t.pumpWidget(themed(DetailHarness(tasks: sampleTasks)));
      await t.pump(const Duration(seconds: 1));

      expect(find.text('2 of 6 blocker tasks completed'), findsOneWidget);
      expect(find.text('33%'), findsOneWidget);
      // t2 and t6 are actionable (t1 and t4 wait on open children).
      expect(find.text('Actionable next tasks'), findsOneWidget);
      expect(find.byType(BlockerTaskCard), findsNWidgets(6));
      expect(find.text('In review'), findsOneWidget);
      expect(find.text('View pull request'), findsOneWidget);
      expect(find.text('Filed'), findsOneWidget);
      expect(find.text('1 open blocker'), findsNWidgets(2));
      // The untrusted attachment is hidden, with a note.
      expect(find.text('contract.pdf'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      expect(find.textContaining('Some attachments are hidden'), findsOneWidget);

      // Children render below and indented from their parent.
      final parent = t.getTopLeft(find.text('Rating engine signs off on landlord rates'));
      final child = t.getTopLeft(find.text('Collect rate table from actuarial').last);
      expect(child.dx, greaterThan(parent.dx));
      expect(child.dy, greaterThan(parent.dy));
    });

    testWidgets('hide completed removes done tasks', (t) async {
      await _setSize(t, const Size(390, 3000));
      await t.pumpWidget(themed(DetailHarness(tasks: sampleTasks)));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.text('Hide completed · 2'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(BlockerTaskCard), findsNWidgets(4));
    });

    testWidgets('all-done project with hide completed shows a way back', (t) async {
      await _setSize(t, const Size(390, 1600));
      await t.pumpWidget(themed(DetailHarness(tasks: [task('a', 'Only task', status: BlockerStatus.done)])));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.text('Hide completed · 1'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('All tasks are completed'), findsOneWidget);
      await t.tap(find.text('Show completed'));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(BlockerTaskCard), findsOneWidget);
    });

    testWidgets('no tasks shows the empty state', (t) async {
      await _setSize(t, const Size(390, 1600));
      await t.pumpWidget(themed(const DetailHarness(tasks: [])));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('No blockers yet'), findsOneWidget);
      expect(find.text('0 of 0 blocker tasks completed'), findsOneWidget);
    });

    testWidgets('task menu puts delete last; checkbox respects permissions', (t) async {
      await _setSize(t, const Size(390, 800));
      await t.pumpWidget(themed(Scaffold(
        body: BlockerTaskCard(
          task: task('a', 'Read-only task'),
          onToggleDone: null,
          actions: [
            BjMenuAction(label: 'Delete', icon: Icons.delete_outline, destructive: true, onSelected: () {}),
            BjMenuAction(label: 'Edit', icon: Icons.edit_outlined, onSelected: () {}),
          ],
        ),
      )));
      expect(t.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
      await t.tap(find.byTooltip('Task actions'));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('Edit')).dy, lessThan(t.getTopLeft(find.text('Delete')).dy));
    });
  });
}
