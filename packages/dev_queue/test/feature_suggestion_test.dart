import 'dart:async';

import 'package:bluejay_design/bluejay_design.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:dev_queue/dev_queue.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final _now = DateTime(2026, 11, 13, 12);

Map<String, Object?> _offerData({
  Object? showAfter,
  Object? expiresAt,
  String groupId = 'g1',
}) =>
    {
      'offerId': 'o1',
      'appId': 'notes',
      'appName': 'Notes',
      'groupId': groupId,
      'title': 'Pin notes to the top',
      'pitch': 'Keep the notes you use most at the top of your list.',
      'showAfter': showAfter ?? Timestamp.fromDate(_now.subtract(const Duration(hours: 1))),
      'expiresAt': expiresAt ?? Timestamp.fromDate(_now.add(const Duration(days: 3))),
    };

FeatureSuggestionOffer _offer({Object? showAfter, Object? expiresAt, String groupId = 'g1'}) =>
    FeatureSuggestionOffer.fromData(_offerData(showAfter: showAfter, expiresAt: expiresAt, groupId: groupId))!;

bool _eligible(
  FeatureSuggestionOffer? offer, {
  DateTime? now,
  String? groupId = 'g1',
  bool isGuest = false,
  bool enabled = true,
}) =>
    shouldShowFeatureSuggestion(
      offer: offer,
      now: now ?? _now,
      activeGroupId: groupId,
      isGuest: isGuest,
      suggestionsEnabled: enabled,
    );

class _Harness {
  final firestore = FakeFirebaseFirestore();
  final calls = <RecordedCall>[];
  Object? Function(RecordedCall call) respond = (_) => {'ok': true};

  late final FeatureSuggestionService service = FeatureSuggestionService(
    firestore: firestore,
    call: (name, data) async {
      final call = RecordedCall(name, data);
      calls.add(call);
      return respond(call);
    },
  );
}

Future<void> _pumpLauncher(WidgetTester tester, Future<void> Function(BuildContext) onTap) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: BluejayTheme.build(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => onTap(context), child: const Text('open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('FeatureSuggestionOffer.fromData', () {
    test('reads every field', () {
      final offer = _offer();
      expect(offer.offerId, 'o1');
      expect(offer.appId, 'notes');
      expect(offer.appName, 'Notes');
      expect(offer.groupId, 'g1');
      expect(offer.title, 'Pin notes to the top');
      expect(offer.pitch, startsWith('Keep the notes'));
      expect(offer.showAfter, _now.subtract(const Duration(hours: 1)));
      expect(offer.expiresAt, _now.add(const Duration(days: 3)));
    });

    test('null, a non-map or a missing id, group or title is no offer', () {
      expect(FeatureSuggestionOffer.fromData(null), isNull);
      expect(FeatureSuggestionOffer.fromData('x'), isNull);
      for (final field in ['offerId', 'groupId', 'title']) {
        expect(FeatureSuggestionOffer.fromData({..._offerData(), field: '  '}), isNull, reason: field);
      }
      expect(FeatureSuggestionOffer.fromDocData({'offer': null}), isNull);
      expect(FeatureSuggestionOffer.fromDocData(null), isNull);
    });

    test('missing app name falls back to the app id; missing times are null', () {
      final data = _offerData()
        ..remove('appName')
        ..remove('pitch')
        ..remove('showAfter')
        ..remove('expiresAt');
      final offer = FeatureSuggestionOffer.fromData(data)!;
      expect(offer.appName, 'notes');
      expect(offer.pitch, '');
      expect(offer.showAfter, isNull);
      expect(offer.expiresAt, isNull);
    });

    test('times come as Timestamps, ISO strings or callable maps', () {
      final iso = FeatureSuggestionOffer.fromData(
          _offerData(showAfter: '2026-11-13T10:00:00Z', expiresAt: {'_seconds': 1800000000}))!;
      expect(iso.showAfter!.isAtSameMomentAs(DateTime.utc(2026, 11, 13, 10)), isTrue);
      expect(iso.expiresAt!.isAtSameMomentAs(DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000)), isTrue);
    });
  });

  group('shouldShowFeatureSuggestion', () {
    test('a due offer for the active group shows', () {
      expect(_eligible(_offer()), isTrue);
    });

    test('no offer, a guest, or suggestions off never shows', () {
      expect(_eligible(null), isFalse);
      expect(_eligible(_offer(), isGuest: true), isFalse);
      expect(_eligible(_offer(), enabled: false), isFalse);
    });

    test('another group, or no active group, does not show', () {
      expect(_eligible(_offer(), groupId: 'g2'), isFalse);
      expect(_eligible(_offer(), groupId: null), isFalse);
      expect(_eligible(_offer(), groupId: ''), isFalse);
    });

    test('shows from showAfter until just before expiresAt', () {
      final offer = _offer(showAfter: Timestamp.fromDate(_now), expiresAt: Timestamp.fromDate(_now.add(const Duration(hours: 1))));
      expect(_eligible(offer, now: _now.subtract(const Duration(seconds: 1))), isFalse);
      expect(_eligible(offer, now: _now), isTrue);
      expect(_eligible(offer, now: _now.add(const Duration(minutes: 59))), isTrue);
      expect(_eligible(offer, now: _now.add(const Duration(hours: 1))), isFalse);
    });

    test('no showAfter shows now; no expiresAt never shows', () {
      final noShowAfter = FeatureSuggestionOffer.fromData(_offerData()..remove('showAfter'))!;
      expect(_eligible(noShowAfter), isTrue);
      final noExpiry = FeatureSuggestionOffer.fromData(_offerData()..remove('expiresAt'))!;
      expect(_eligible(noExpiry), isFalse);
    });

    test('featureSuggestionsEnabled is on unless exactly false', () {
      expect(featureSuggestionsEnabled(null), isTrue);
      expect(featureSuggestionsEnabled(<String, Object?>{}), isTrue);
      expect(featureSuggestionsEnabled({'featureSuggestions': true}), isTrue);
      expect(featureSuggestionsEnabled({'featureSuggestions': 'no'}), isTrue);
      expect(featureSuggestionsEnabled({'featureSuggestions': false}), isFalse);
    });
  });

  group('FeatureSuggestionService', () {
    test('reads the offer and the setting', () async {
      final h = _Harness();
      await h.firestore.collection('feature_suggestions').doc('u1').set({'offer': _offerData()});
      await h.firestore.collection('users').doc('u1').set({
        'notificationSettings': {'featureSuggestions': false},
      });
      expect((await h.service.readOffer('u1'))?.offerId, 'o1');
      expect(await h.service.readEnabled('u1'), isFalse);
      expect(await h.service.readOffer('nobody'), isNull);
      expect(await h.service.readEnabled('nobody'), isTrue);
    });

    test('respond sends the offer and action and reads the result', () async {
      final h = _Harness()..respond = (_) => {'ok': true, 'requestId': 'f1', 'queuePosition': 2};
      final result = await h.service.respond('o1', FeatureSuggestionAction.accept);
      expect(h.calls.single.name, 'featureSuggestionRespond');
      expect(h.calls.single.data, {'offerId': 'o1', 'action': 'accept'});
      expect(result.requestId, 'f1');
      expect(result.queuePosition, 2);
    });

    test('a refusal carries the server message', () async {
      final h = _Harness()
        ..respond = (_) => throw FirebaseFunctionsException(
            code: 'failed-precondition', message: 'This suggestion has expired.');
      await expectLater(
        h.service.respond('o1', FeatureSuggestionAction.accept),
        throwsA(isA<FeatureSuggestionException>()
            .having((e) => e.code, 'code', 'failed-precondition')
            .having((e) => e.message, 'message', 'This suggestion has expired.')),
      );
    });
  });

  group('FeatureSuggestionDialog', () {
    Future<_Harness> open(WidgetTester tester, {_Harness? harness}) async {
      final h = harness ?? _Harness();
      await _pumpLauncher(tester, (context) => showFeatureSuggestionDialog(context, _offer(), service: h.service));
      return h;
    }

    testWidgets('shows the plain copy', (tester) async {
      await open(tester);
      expect(find.text('You use Notes a lot'), findsOneWidget);
      expect(find.text('Would this help you?'), findsOneWidget);
      expect(find.text('Pin notes to the top'), findsOneWidget);
      expect(find.textContaining('Keep the notes you use most'), findsOneWidget);
      expect(find.text("Say yes and we'll build it for you. We'll let you know when it's ready."), findsOneWidget);
      expect(find.text('Yes, add it'), findsOneWidget);
      expect(find.text('Not this one'), findsOneWidget);
      expect(find.text("Don't ask me again"), findsOneWidget);
    });

    final buttons = {
      'Yes, add it': 'accept',
      'Not this one': 'decline',
      "Don't ask me again": 'stop',
    };
    for (final entry in buttons.entries) {
      testWidgets('"${entry.key}" sends ${entry.value} and closes', (tester) async {
        final h = await open(tester);
        await tester.tap(find.text(entry.key));
        await tester.pumpAndSettle();
        expect(h.calls.map((c) => c.data['action']), [entry.value]);
        expect(find.text('You use Notes a lot'), findsNothing);
        if (entry.value == 'accept') expect(find.text(featureSuggestionAddedMessage), findsOneWidget);
        if (entry.value == 'stop') expect(find.text(featureSuggestionStoppedMessage), findsOneWidget);
      });
    }

    testWidgets('tapping outside sends later', (tester) async {
      final h = await open(tester);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('You use Notes a lot'), findsNothing);
      expect(h.calls.map((c) => c.data['action']), ['later']);
    });

    testWidgets('the close button sends later', (tester) async {
      final h = await open(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(h.calls.map((c) => c.data['action']), ['later']);
    });

    testWidgets('a refusal closes the prompt and shows its message', (tester) async {
      final h = _Harness()
        ..respond = (_) =>
            throw FirebaseFunctionsException(code: 'failed-precondition', message: 'This suggestion has expired.');
      await open(tester, harness: h);
      await tester.tap(find.text('Yes, add it'));
      await tester.pumpAndSettle();
      expect(h.calls.length, 1);
      expect(find.text('This suggestion has expired.'), findsOneWidget);
      expect(find.text('You use Notes a lot'), findsNothing);
    });

    testWidgets('buttons and dismissal are off while sending', (tester) async {
      final h = _Harness();
      final reply = Completer<Object?>();
      h.respond = (_) => reply.future;
      await open(tester, harness: h);
      await tester.tap(find.text('Yes, add it'));
      await tester.pump();
      await tester.tap(find.text('Not this one'), warnIfMissed: false);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.text('You use Notes a lot'), findsOneWidget);
      reply.complete({'ok': true});
      await tester.pumpAndSettle();
      expect(h.calls.map((c) => c.data['action']), ['accept']);
      expect(find.text('You use Notes a lot'), findsNothing);
    });
  });

  group('maybeShowFeatureSuggestion', () {
    Future<bool?> run(WidgetTester tester, _Harness h, {String groupId = 'g1', bool Function()? canShow}) async {
      bool? shown;
      await _pumpLauncher(tester, (context) async {
        shown = await maybeShowFeatureSuggestion(
          context,
          uid: 'u1',
          groupId: groupId,
          canShow: canShow,
          service: h.service,
          now: () => _now,
        );
      });
      return shown;
    }

    testWidgets('shows a due offer for the group', (tester) async {
      final h = _Harness();
      await h.firestore.collection('feature_suggestions').doc('u1').set({'offer': _offerData()});
      await run(tester, h);
      expect(find.text('You use Notes a lot'), findsOneWidget);
    });

    testWidgets('stays quiet for another group, when turned off, or when canShow says no', (tester) async {
      final h = _Harness();
      await h.firestore.collection('feature_suggestions').doc('u1').set({'offer': _offerData()});
      expect(await run(tester, h, groupId: 'g2'), isFalse);
      expect(await run(tester, h, canShow: () => false), isFalse);
      await h.firestore.collection('users').doc('u1').set({
        'notificationSettings': {'featureSuggestions': false},
      });
      expect(await run(tester, h), isFalse);
      expect(find.text('You use Notes a lot'), findsNothing);
      expect(h.calls, isEmpty);
    });
  });
}
