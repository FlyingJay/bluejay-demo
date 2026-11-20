import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/notification_service.dart';

/// NotificationService.sendInBackground: the pattern senders use so the UI
/// never waits on the `notificationsSend` round trip, and a failure is
/// logged without surfacing as an unhandled async error.
void main() {
  group('NotificationService.sendInBackground', () {
    late List<String> logged;
    late DebugPrintCallback originalDebugPrint;

    setUp(() {
      logged = [];
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logged.add(message);
      };
    });

    tearDown(() => debugPrint = originalDebugPrint);

    test('returns before the send completes', () async {
      final gate = Completer<void>();
      var finished = false;
      final done = NotificationService.sendInBackground(() async {
        await gate.future;
        finished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      gate.complete();
      await done;
      expect(finished, isTrue);
      expect(logged, isEmpty);
    });

    test('logs an async failure instead of throwing it', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        await NotificationService.sendInBackground(
          () async => throw StateError('permission-denied'),
          label: 'chat notifications',
        );
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect(logged.single, contains('chat notifications'));
      expect(logged.single, contains('permission-denied'));
    });

    test('logs a synchronous throw from the send callback too', () async {
      await NotificationService.sendInBackground(
        () => throw ArgumentError('bad recipient'),
      );
      expect(logged.single, contains('bad recipient'));
    });
  });
}
