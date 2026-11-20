import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/user_app_entitlements.dart';
import 'package:shared_ui/record_history.dart';

Map<String, dynamic> _event(String id, {String op = 'update', String kind = 'member', String name = 'Ann', Map<String, dynamic> changes = const {}, int omitted = 0}) => {
      'id': id,
      'operation': op,
      'at': '2026-11-03T14:05:00.000Z',
      'actor': {'kind': kind, 'name': name},
      'changedFields': changes.keys.toList(),
      'changes': changes,
      if (omitted > 0) 'omittedFieldCount': omitted,
    };

ScopedCollection _collection(String name, {required bool audited, List<String> apps = const ['crm']}) => ScopedCollection(
      collection: name,
      appId: apps.first,
      currentUid: () => 'u',
      policy: CollectionPolicy(apps: apps, auditTrail: audited),
    );

void main() {
  test('field labels drop Cents and split words; given labels win', () {
    expect(recordHistoryFieldLabel('amountCents'), 'Amount');
    expect(recordHistoryFieldLabel('next_step_at'), 'Next step at');
    expect(recordHistoryFieldLabel('stage'), 'Stage');
    expect(recordHistoryFieldLabel('stage', {'stage': 'Pipeline stage'}), 'Pipeline stage');
  });

  test('values: money, dates, markers and lists', () {
    expect(recordHistoryValue(123456, field: 'totalCents'), '\$1,234.56');
    expect(recordHistoryValue(null), '(empty)');
    expect(recordHistoryValue({'redacted': true}), '(hidden)');
    expect(recordHistoryValue({'omitted': true, 'chars': 12400}), 'too large to show (12,400 characters)');
    expect(recordHistoryValue({'__type': 'reference', 'value': 'contacts/c1'}), 'contacts/c1');
    expect(recordHistoryValue(true), 'Yes');
    expect(recordHistoryValue({'__type': 'timestamp', 'value': '2026-11-03T14:05:00.000Z'}), contains('2026'));
    expect(recordHistoryChangeLine('stage', {'before': 'lead', 'after': 'won'}), 'Stage: lead → won');
    expect(recordHistoryChangeLine('tags', {'before': ['a', 'b'], 'after': ['b', 'c']}), 'Tags: added c; removed a');
  });

  test('events read their verb from the operation and deletedAt', () {
    RecordHistoryEvent e(Map<String, dynamic> json) => RecordHistoryEvent.fromJson(json);
    expect(e(_event('1', op: 'create')).verb, 'created');
    expect(e(_event('2', changes: {'a': {'before': 1, 'after': 2}})).verb, 'changed 1 field');
    expect(e(_event('3', changes: {'a': {'before': 1, 'after': 2}}, omitted: 2)).verb, 'changed 3 fields');
    expect(e(_event('4', changes: {'deletedAt': {'before': null, 'after': 'x'}})).verb, 'deleted');
    expect(e(_event('5', changes: {'deletedAt': {'before': 'x', 'after': null}})).verb, 'restored');
    expect(e(_event('6', kind: 'unattributed')).isSystem, isTrue);
  });

  test('canSeeRecordHistory: audited collections, for admins of their apps and platform admins', () {
    final deals = _collection('crm_deals', audited: true);
    const admin = UserAppEntitlements(entitlements: {'g1:crm', 'g1:crm:admin'});
    const editor = UserAppEntitlements(entitlements: {'g1:crm', 'g1:crm:edit'});
    const boss = UserAppEntitlements(roles: {'admin'});
    const inactiveBoss = UserAppEntitlements(roles: {'admin'}, status: 'SUSPENDED');
    expect(canSeeRecordHistory(deals, groupId: 'g1', entitlements: admin), isTrue);
    expect(canSeeRecordHistory(deals, groupId: 'g2', entitlements: admin), isFalse);
    expect(canSeeRecordHistory(deals, groupId: 'g1', entitlements: editor), isFalse);
    expect(canSeeRecordHistory(deals, groupId: 'g1', entitlements: boss), isTrue);
    expect(canSeeRecordHistory(deals, groupId: 'g1', entitlements: inactiveBoss), isFalse);
    expect(canSeeRecordHistory(_collection('notes', audited: false), groupId: 'g1', entitlements: boss), isFalse);
  });

  Future<void> pump(WidgetTester tester, RecordHistoryLoader loader) => tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RecordHistoryTimeline(collection: 'crm_deals', docId: 'd1', loader: loader)),
      ));

  testWidgets('the timeline lists people\'s changes, hides system updates behind a toggle, and pages', (tester) async {
    final cursors = <String?>[];
    await pump(tester, ({required collection, required docId, parentDocId, cursor}) async {
      cursors.add(cursor);
      if (cursor == null) {
        return RecordHistoryPage(audited: true, nextCursor: 'e2', hiddenCount: 1, events: [
          RecordHistoryEvent.fromJson(_event('e1', changes: {'stage': {'before': 'lead', 'after': 'won'}})),
          RecordHistoryEvent.fromJson(_event('e2', kind: 'unattributed', name: 'System', changes: {'votes': {'before': 1, 'after': 2}})),
        ]);
      }
      return RecordHistoryPage(audited: true, events: [RecordHistoryEvent.fromJson(_event('e0', op: 'create', name: 'Bob'))]);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('changed 1 field'), findsOneWidget);
    expect(find.text('System updates (1)'), findsOneWidget);
    expect(find.textContaining('aren\'t shown to you'), findsOneWidget);
    expect(find.textContaining('System'), findsOneWidget, reason: 'only the toggle; the system event is hidden');

    await tester.tap(find.textContaining('changed 1 field'));
    await tester.pumpAndSettle();
    expect(find.text('Stage: lead → won'), findsOneWidget);

    await tester.tap(find.text('System updates (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('changed 1 field'), findsNWidgets(2));

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(cursors, [null, 'e2']);
    expect(find.textContaining('created'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('an unaudited collection, an empty history and an error each say so', (tester) async {
    await pump(tester, ({required collection, required docId, parentDocId, cursor}) async =>
        const RecordHistoryPage(audited: false, events: []));
    await tester.pumpAndSettle();
    expect(find.text('No history is recorded here'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pump(tester, ({required collection, required docId, parentDocId, cursor}) async =>
        const RecordHistoryPage(audited: true, events: []));
    await tester.pumpAndSettle();
    expect(find.text('No changes recorded yet'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pump(tester, ({required collection, required docId, parentDocId, cursor}) async => throw Exception('boom'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load history'), findsOneWidget);
  });
}
