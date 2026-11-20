import 'package:bluejay_design/bluejay_design.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'support/fixtures.dart';

Widget _app(Widget child) => MaterialApp(theme: BluejayTheme.build(), home: Scaffold(body: Center(child: child)));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('status tones', () {
    test('every code has a style', () {
      for (final code in DevStatusCode.values) {
        expect(devStatusStyles.containsKey(code), isTrue, reason: '$code');
      }
    });

    test('needs-you codes take the accent, Live success, finished neutral', () {
      for (final code in DevStatusCode.values) {
        final tone = devStatusTone(code);
        if (code.needsYou) {
          expect(tone, BjTone.accent);
        } else if (code == DevStatusCode.live) {
          expect(tone, BjTone.success);
        } else if (const {DevStatusCode.declined, DevStatusCode.closed, DevStatusCode.unknown}.contains(code)) {
          expect(tone, BjTone.neutral);
        } else {
          expect(tone, BjTone.info);
        }
      }
    });

    testWidgets('the pill draws its label in the tone colour', (tester) async {
      for (final status in sampleStatuses()) {
        await tester.pumpWidget(_app(DevStatusPill(status)));
        final label = tester.widget<Text>(find.text(status.label));
        final ctx = tester.element(find.byType(DevStatusPill));
        expect(label.style?.color, ctx.bj.tone(devStatusTone(status.code)).foreground, reason: status.label);
      }
    });

    testWidgets('a needs-you pill shows a dot, others their icon', (tester) async {
      await tester.pumpWidget(_app(const DevStatusPill(DevStatus(code: DevStatusCode.live, label: 'Live'))));
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      await tester.pumpWidget(_app(const DevStatusPill(DevStatus(code: DevStatusCode.readyToTry, label: 'Ready to try'))));
      expect(find.byIcon(devStatusStyle(DevStatusCode.readyToTry).icon), findsNothing);
    });

    test('chip tone follows its copy', () {
      expect(DevQueueChipView.toneFor(sampleChipCopies[0]), BjTone.accent);
      expect(DevQueueChipView.toneFor(sampleChipCopies[1]), BjTone.info);
      expect(DevQueueChipView.toneFor(sampleChipCopies[2]), BjTone.neutral);
    });
  });

  group('queue screen states', () {
    testWidgets('first load shows skeletons, not spinners', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: FakeUser(), service: PendingQueueService(FakeQueue())),
      ));
      await _settle(tester);
      expect(find.byType(BjSkeleton), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a failed load is an error state with a retry', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: FakeUser(), service: FailingQueueService(FakeQueue())),
      ));
      await _settle(tester);
      expect(find.byType(BjStateView), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
    });

    testWidgets('wide screens lay the queue out in two columns', (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final q = await seededQueue();
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: FakeUser(), service: q.service, now: fixtureNow),
      ));
      await _settle(tester);
      final now = tester.getTopLeft(find.text('Now'));
      final upNext = tester.getTopLeft(find.text('Up next').first);
      expect(upNext.dx, greaterThan(now.dx + 300));
      expect((upNext.dy - now.dy).abs(), lessThan(4));
    });

    testWidgets('Up next rows offer their actions in an overflow menu, Withdraw last', (tester) async {
      final q = await seededQueue();
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: DevQueueScreen(currentUser: FakeUser(), service: q.service, now: fixtureNow),
      ));
      await _settle(tester);
      final menu = find.descendant(
        of: find.ancestor(of: find.text('Weekly digest of new tasks'), matching: find.byType(BjCard)),
        matching: find.byType(BjOverflowMenu),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final labels = tester
          .widgetList<PopupMenuItem<BjMenuAction>>(find.byType(PopupMenuItem<BjMenuAction>))
          .map((i) => i.value!.label)
          .toList();
      expect(labels, ['Move to top', 'Move up', 'Move down', 'Edit', 'Withdraw']);
      expect(tester.widget<PopupMenuItem<BjMenuAction>>(find.byType(PopupMenuItem<BjMenuAction>).last).value!.destructive,
          isTrue);
    });
  });

  group('withdraw confirm', () {
    testWidgets('lists what is lost', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: BluejayTheme.build(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmDevQueueWithdraw(context, started: true),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text("The change won't go live"), findsOneWidget);
      expect(find.text('Stop and withdraw'), findsOneWidget);
    });
  });
}
