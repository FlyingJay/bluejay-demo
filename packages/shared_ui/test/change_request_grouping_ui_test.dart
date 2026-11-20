import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/change_request_grouping.dart';
import 'package:shared_ui/change_request_grouping_ui.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

ChangeRequestSummary _summary(String id, {String itemType = 'bug'}) =>
    ChangeRequestSummary(
      itemType: itemType,
      itemId: id,
      title: 'Request $id',
      relatedAppId: 'rented-dwelling',
      groupLabel: 'Acme',
    );

void main() {
  group('ChangeRequestGroupingChips', () {
    testWidgets('shows the parent and combined-count chips', (tester) async {
      await tester.pumpWidget(_host(ChangeRequestGroupingChips.fromData({
        'parentRequest': {
          'itemId': 'p1',
          'title': 'Faster exports',
          'state': 'merged',
        },
        'linkedRecords': [
          {'collection': 'bug_reports', 'id': 'b1'},
          {'collection': 'feature_requests', 'id': 'f1'},
        ],
      })));
      expect(find.text('Part of: Faster exports · Deploying'), findsOneWidget);
      expect(find.text('Combines 2 requests'), findsOneWidget);
    });

    testWidgets('renders nothing for an ungrouped request', (tester) async {
      await tester.pumpWidget(
          _host(ChangeRequestGroupingChips.fromData(const {})));
      expect(find.textContaining('Part of'), findsNothing);
      expect(find.textContaining('Combines'), findsNothing);
    });

    testWidgets('long titles ellipsize in a bounded width', (tester) async {
      await tester.pumpWidget(_host(SizedBox(
        width: 140,
        child: ChangeRequestGroupingChips(
          parentRequest: const ParentRequestRef(
            itemType: 'feature',
            itemId: 'p1',
            title: 'A very long combined request title that will not fit',
          ),
        ),
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('ChangeRequestSelectionBar', () {
    testWidgets('idle shows a select action', (tester) async {
      var started = false;
      await tester.pumpWidget(_host(ChangeRequestSelectionBar(
        selecting: false,
        selectedCount: 0,
        onStart: () => started = true,
        onCancel: () {},
        onCombine: () {},
      )));
      await tester.tap(find.text('Select to combine'));
      expect(started, isTrue);
    });

    testWidgets('combine is disabled until something is selected',
        (tester) async {
      var combined = 0;
      Widget bar(int count) => _host(ChangeRequestSelectionBar(
            selecting: true,
            selectedCount: count,
            appLabel: 'Rented Dwelling',
            onStart: () {},
            onCancel: () {},
            onCombine: () => combined++,
          ));
      await tester.pumpWidget(bar(0));
      await tester.tap(find.text('Combine…'));
      expect(combined, 0);

      await tester.pumpWidget(bar(2));
      expect(find.text('2 selected · Rented Dwelling'), findsOneWidget);
      await tester.tap(find.text('Combine…'));
      expect(combined, 1);
    });
  });

  group('ChangeRequestSelectableCard', () {
    testWidgets('a disabled card cannot be checked', (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(_host(ChangeRequestSelectableCard(
        selected: false,
        disabledReason: 'Already part of another request',
        onChanged: changes.add,
        child: const Text('card'),
      )));
      await tester.tap(find.byType(Checkbox));
      expect(changes, isEmpty);
    });

    testWidgets('an eligible card toggles', (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(_host(ChangeRequestSelectableCard(
        selected: false,
        disabledReason: null,
        onChanged: changes.add,
        child: const Text('card'),
      )));
      await tester.tap(find.byType(Checkbox));
      expect(changes, [true]);
    });
  });

  group('CombineRequestsDialog', () {
    Future<void> open(
      WidgetTester tester, {
      List<ChangeRequestSummary> candidates = const [],
      List<ChangeRequestSummary>? selected,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showCombineRequestsDialog(
                  context,
                  selected: selected ?? [_summary('b1'), _summary('b2')],
                  groupName: 'Steward Co',
                  canCreateNew: true,
                  parentCandidates: Future.value(candidates),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('requires a title, then returns a new parent',
        (tester) async {
      CombineRequestsChoice? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showCombineRequestsDialog(
                  context,
                  selected: [_summary('b1'), _summary('b2')],
                  groupName: 'Steward Co',
                  canCreateNew: true,
                  parentCandidates: Future.value(const []),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Create in: Steward Co'), findsOneWidget);
      expect(find.textContaining('created as an idea'), findsOneWidget);
      expect(find.text('Request b1 (Acme)'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Combine'));
      await tester.pumpAndSettle();
      expect(find.text('Give the combined request a title'), findsOneWidget);
      expect(result, isNull);

      await tester.enterText(
          find.widgetWithText(TextField, 'Title'), 'Rebuild exports');
      await tester.tap(find.widgetWithText(FilledButton, 'Combine'));
      await tester.pumpAndSettle();
      expect(result?.existingParent, isNull);
      expect(result?.title, 'Rebuild exports');
    });

    testWidgets('add to existing is unavailable without candidates',
        (tester) async {
      await open(tester);
      expect(find.text('Add to existing (0)'), findsOneWidget);
      await tester.tap(find.text('Add to existing (0)'));
      await tester.pumpAndSettle();
      // Still on the new-request form.
      expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
    });

    testWidgets('picks an existing parent', (tester) async {
      CombineRequestsChoice? result;
      final parent = ChangeRequestSummary(
        itemType: 'feature',
        itemId: 'p1',
        title: 'Existing parent',
        relatedAppId: 'rented-dwelling',
        combinedCount: 2,
      );
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showCombineRequestsDialog(
                  context,
                  selected: [_summary('f1', itemType: 'feature')],
                  groupName: 'Steward Co',
                  canCreateNew: true,
                  parentCandidates: Future.value([parent]),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('created as an idea'), findsNothing);
      await tester.tap(find.text('Add to existing (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Existing parent'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(result?.existingParent?.itemId, 'p1');
    });
  });
}
