import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/notification_service.dart';

/// What `NotificationService` sends to the `notificationsSend` callable
/// (functions/_notification_send.js), which rejects unknown fields: only the
/// sender-controlled fields pass through, the server-owned ones callers used
/// to write themselves are dropped, and group/app/recipients come from the
/// service, never from the data map.
void main() {
  group('NotificationService.requestPayload', () {
    test('keeps sender fields and drops the server-owned ones', () {
      final payload = NotificationService.requestPayload(
        {
          'recipientId': 'someone-else',
          'title': 'Your turn',
          'body': 'It is your move.',
          'appName': 'Chess',
          'isRead': true,
          'createdAt': Timestamp.now(),
          'groupId': 'other-group',
          'appId': 'other-app',
          'createdBy': 'forged',
          'context': {'gameId': 'g1'},
          'actionUrl': 'https://bluejay.gg/acme/chess',
        },
        groupId: 'acme',
        appId: 'chess',
        recipientIds: ['u2', 'u3'],
      );

      expect(payload, {
        'title': 'Your turn',
        'body': 'It is your move.',
        'appName': 'Chess',
        'context': {'gameId': 'g1'},
        'actionUrl': 'https://bluejay.gg/acme/chess',
        'groupId': 'acme',
        'appId': 'chess',
        'recipientIds': ['u2', 'u3'],
      });
    });

    test('adds the coalescing fields when asked', () {
      final payload = NotificationService.requestPayload(
        {'title': 'Tap!'},
        groupId: 'acme',
        appId: 'tap-war',
        recipientIds: ['u2'],
        coalesceKey: 'game:1',
      );

      expect(payload['coalesceKey'], 'game:1');
      expect(payload['coalesceWindowSeconds'],
          NotificationService.defaultCoalesceWindow.inSeconds);
    });

    test('omits null optional fields', () {
      final payload = NotificationService.requestPayload(
        {'title': 'Hi', 'body': null},
        groupId: 'acme',
        appId: 'notes',
        recipientIds: ['u2'],
      );

      expect(payload.containsKey('body'), isFalse);
    });
  });
}
