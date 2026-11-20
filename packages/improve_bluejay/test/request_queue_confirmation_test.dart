import 'package:dev_queue/dev_queue.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:improve_bluejay/new_request_sheet.dart';
import 'package:improve_bluejay/request_queue_confirmation.dart';

const _lines = {
  'S': 'Often ready within a few days once it starts',
  'M': 'Takes a little longer than a small change',
  'L': 'Takes longer than a medium change',
};

DevQueueItem item(String key, String state, {double rank = 1, bool managed = false, String? size}) =>
    DevQueueItem.fromMap(key, {
      'state': state,
      'rank': rank,
      'managed': managed,
      'size': size,
      if (size != null) 'estimate': {'size': size, 'short': size, 'line': _lines[size]},
      'status': {'code': 'up_next', 'label': 'Up next'},
    });

void main() {
  const fallback = "Thanks! Your request for Notes is in — we'll let you know when it's live.";

  group('requestConfirmationFor', () {
    final active = [
      item('feature__building', 'building', rank: 1),
      item('bug__managed', 'queued', rank: 2, managed: true),
      item('bug__earlier', 'queued', rank: 3),
      item('bug__new', 'queued', rank: 4),
    ];

    test('the position counts every active, non-managed item before it', () {
      final c = requestConfirmationFor(active, 'bug__new', fallbackMessage: fallback)!;
      expect(c.message, 'Added to your queue: #3.');
      expect(c.itemKey, 'bug__new');
    });

    test("the estimate's line follows the position", () {
      for (final entry in {
        'S': 'Added to your queue: #1. Often ready within a few days once it starts.',
        'M': 'Added to your queue: #1. Takes a little longer than a small change.',
        'L': 'Added to your queue: #1. Takes longer than a medium change.',
      }.entries) {
        final c = requestConfirmationFor([item('bug__x', 'queued', size: entry.key)], 'bug__x', fallbackMessage: fallback)!;
        expect(c.message, entry.value, reason: entry.key);
      }
    });

    test('a managed item gets the usual message and no View', () {
      final c = requestConfirmationFor(active, 'bug__managed', fallbackMessage: fallback)!;
      expect(c.message, fallback);
      expect(c.itemKey, isNull);
    });

    test('null until the item exists', () {
      expect(requestConfirmationFor(active, 'bug__later', fallbackMessage: fallback), isNull);
    });
  });

  group('resolveRequestConfirmation', () {
    test('waits for intake to create the item', () async {
      final db = FakeFirebaseFirestore();
      final service = DevQueueService(firestore: db, call: (n, d) async => null);
      final pending = resolveRequestConfirmation(
        service: service,
        uid: 'u1',
        itemKey: 'bug__b1',
        fallbackMessage: fallback,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await db.collection('dev_queue_items').doc('bug__b1').set({
        'ownerId': 'u1',
        'active': true,
        'managed': false,
        'state': 'queued',
        'rank': 5,
        'size': 'S',
        'estimate': {'size': 'S', 'short': 'Small', 'line': _lines['S']},
      });
      final result = await pending;
      expect(result.message, 'Added to your queue: #1. Often ready within a few days once it starts.');
      expect(result.itemKey, 'bug__b1');
    });

    test('falls back after the timeout', () async {
      final service = DevQueueService(firestore: FakeFirebaseFirestore(), call: (n, d) async => null);
      final result = await resolveRequestConfirmation(
        service: service,
        uid: 'u1',
        itemKey: 'bug__never',
        fallbackMessage: fallback,
        timeout: const Duration(milliseconds: 50),
      );
      expect(result.message, fallback);
      expect(result.itemKey, isNull);
    });
  });

  testWidgets('the new-request chooser offers all three kinds', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    NewRequestKind? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              picked = await showModalBottomSheet<NewRequestKind>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const NewRequestChooser(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.text('Suggest an improvement'), findsOneWidget);
    expect(find.text('Ask for a new app'), findsOneWidget);
    await tester.tap(find.text('Ask for a new app'));
    await tester.pumpAndSettle();
    expect(picked, NewRequestKind.newApp);
  });
}
