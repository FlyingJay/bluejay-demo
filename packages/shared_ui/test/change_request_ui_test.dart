import 'package:bluejay_design/bluejay_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/change_request_list_scope.dart';
import 'package:shared_ui/change_request_ui.dart';

Widget _host(Widget child) =>
    MaterialApp(theme: BluejayTheme.build(), home: Scaffold(body: child));

void main() {
  Widget switcherFor({
    required bool hasStewardedApps,
    required bool isPlatformAdmin,
    ValueChanged<ChangeRequestListScope>? onChanged,
  }) {
    return _host(ChangeRequestScopeSwitcher(
      scopes: availableChangeRequestScopes(
        hasStewardedApps: hasStewardedApps,
        isPlatformAdmin: isPlatformAdmin,
      ),
      selected: ChangeRequestListScope.activeGroup,
      onChanged: onChanged ?? (_) {},
    ));
  }

  testWidgets('scope switcher reports the tapped scope', (tester) async {
    final changes = <ChangeRequestListScope>[];
    await tester.pumpWidget(switcherFor(
      hasStewardedApps: true,
      isPlatformAdmin: true,
      onChanged: changes.add,
    ));

    expect(find.text('This group'), findsOneWidget);
    await tester.tap(find.text('Apps I manage'));
    await tester.tap(find.text('All groups'));
    expect(changes, [
      ChangeRequestListScope.managedApps,
      ChangeRequestListScope.allGroups,
    ]);
  });

  testWidgets('steward who is not a platform admin never sees All groups',
      (tester) async {
    await tester.pumpWidget(switcherFor(
      hasStewardedApps: true,
      isPlatformAdmin: false,
    ));

    expect(find.text('This group'), findsOneWidget);
    expect(find.text('Apps I manage'), findsOneWidget);
    expect(find.text('All groups'), findsNothing);
  });

  testWidgets('platform admin without stewardship sees All groups only',
      (tester) async {
    await tester.pumpWidget(switcherFor(
      hasStewardedApps: false,
      isPlatformAdmin: true,
    ));

    expect(find.text('This group'), findsOneWidget);
    expect(find.text('Apps I manage'), findsNothing);
    expect(find.text('All groups'), findsOneWidget);
  });

  testWidgets('switcher is hidden when there is only one scope',
      (tester) async {
    await tester.pumpWidget(switcherFor(
      hasStewardedApps: false,
      isPlatformAdmin: false,
    ));

    expect(find.byType(SegmentedButton<ChangeRequestListScope>), findsNothing);
    expect(find.text('This group'), findsNothing);
    expect(find.text('All groups'), findsNothing);
  });

  testWidgets('vote column without callbacks is read-only', (tester) async {
    await tester.pumpWidget(_host(const ChangeRequestVoteColumn(
      voteCount: 3,
      hasUpvoted: false,
      hasDownvoted: false,
      onUpvote: null,
      onDownvote: null,
    )));

    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope chip ellipsizes long labels in a bounded width',
      (tester) async {
    await tester.pumpWidget(_host(SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChangeRequestScopeChip(
            label: 'A very long client group name · Rented Dwelling',
          ),
        ],
      ),
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked related-app field shows the app read-only',
      (tester) async {
    await tester.pumpWidget(_host(
      const LockedRelatedAppField(appName: 'Habit Tracker'),
    ));

    expect(find.text('Habit Tracker'), findsOneWidget);
    expect(find.text('Related app'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String?>), findsNothing);
  });

  testWidgets('vote column reports taps', (tester) async {
    var up = 0, down = 0;
    await tester.pumpWidget(_host(ChangeRequestVoteColumn(
      voteCount: 7,
      hasUpvoted: true,
      hasDownvoted: false,
      onUpvote: () => up++,
      onDownvote: () => down++,
    )));
    await tester.tap(find.bySemanticsLabel('Upvote'));
    await tester.tap(find.bySemanticsLabel('Downvote'));
    expect((up, down), (1, 1));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('action chip and points badge render their labels',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(Row(children: [
      ChangeRequestActionChip(
        icon: Icons.check_rounded,
        label: 'Mark fixed',
        tone: BjTone.success,
        onTap: () => taps++,
      ),
      const ChangeRequestPointsBadge(points: 5),
    ])));
    await tester.tap(find.text('Mark fixed'));
    expect(taps, 1);
    expect(find.text('5 pts'), findsOneWidget);
  });

  test('formatTimeAgo picks the largest whole unit', () {
    final now = DateTime(2026, 11, 10, 12);
    expect(formatTimeAgo(now.subtract(const Duration(seconds: 5)), now: now), '5s ago');
    expect(formatTimeAgo(now.subtract(const Duration(minutes: 3)), now: now), '3m ago');
    expect(formatTimeAgo(now.subtract(const Duration(hours: 5)), now: now), '5h ago');
    expect(formatTimeAgo(now.subtract(const Duration(days: 15)), now: now), '2w ago');
    expect(formatTimeAgo(now.subtract(const Duration(days: 400)), now: now), '1y ago');
  });

  test('card tone: done is success, closed is neutral, open is plain', () {
    expect(changeRequestCardTone(isCompleted: true), BjTone.success);
    expect(changeRequestCardTone(isClosed: true), BjTone.neutral);
    expect(changeRequestCardTone(), isNull);
  });
}
