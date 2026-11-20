import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/notification_service.dart';

/// The fields `NotificationService.add()` injects when a caller opts a
/// notification into coalescing. Enforcement lives in the
/// `onNotificationCreated` Cloud Function
/// (`functions/_notification_coalescing.js`); what is testable here — and
/// what a caller can get wrong — is the opt-in itself: the field names the
/// backend reads, the blank-key fallback to "always deliver", and the clamp.
void main() {
  group('NotificationService.coalescingFields', () {
    test('omits the fields entirely when no key is given', () {
      expect(NotificationService.coalescingFields(), isEmpty);
      expect(NotificationService.coalescingFields(key: null), isEmpty);
      expect(NotificationService.coalescingFields(key: ''), isEmpty);
      expect(NotificationService.coalescingFields(key: '   '), isEmpty);
      // A window without a key must not opt in on its own: a notification
      // with no thread identity has nothing to coalesce against, and
      // delivering it is the safe fallback.
      expect(
        NotificationService.coalescingFields(window: const Duration(minutes: 1)),
        isEmpty,
      );
    });

    test('uses the shared default window when none is requested', () {
      expect(
        NotificationService.coalescingFields(key: 'game:g1'),
        {
          'coalesceKey': 'game:g1',
          'coalesceWindowSeconds':
              NotificationService.defaultCoalesceWindow.inSeconds,
        },
      );
    });

    test('passes a requested window through in seconds, and trims the key', () {
      expect(
        NotificationService.coalescingFields(
          key: '  game:g1  ',
          window: const Duration(minutes: 2),
        ),
        {'coalesceKey': 'game:g1', 'coalesceWindowSeconds': 120},
      );
    });

    test('clamps to the window the backend will honour', () {
      expect(
        NotificationService.coalescingFields(
          key: 'game:g1',
          window: const Duration(days: 7),
        )['coalesceWindowSeconds'],
        NotificationService.maxCoalesceWindow.inSeconds,
      );
      // Sub-second windows would coalesce nothing; a floor of one second
      // keeps the value one the backend accepts rather than rejects.
      expect(
        NotificationService.coalescingFields(
          key: 'game:g1',
          window: Duration.zero,
        )['coalesceWindowSeconds'],
        1,
      );
      expect(
        NotificationService.coalescingFields(
          key: 'game:g1',
          window: const Duration(minutes: -5),
        )['coalesceWindowSeconds'],
        1,
      );
    });
  });
}
