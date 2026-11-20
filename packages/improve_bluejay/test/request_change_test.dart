import 'package:flutter_test/flutter_test.dart';
import 'package:improve_bluejay/request_change_availability.dart';
import 'package:shared_services/user_app_entitlements.dart';

void main() {
  const member = UserAppEntitlements(
    entitlements: {'g1:improve-apps', 'g1:notes'},
    status: 'ACTIVE',
  );

  group('isRequestChangeCandidate', () {
    test('true for an ordinary app and a signed-in member', () {
      expect(
        isRequestChangeCandidate(appId: 'notes', isSignedInMember: true),
        isTrue,
      );
    });

    test('false for guests / signed-out users', () {
      expect(
        isRequestChangeCandidate(appId: 'notes', isSignedInMember: false),
        isFalse,
      );
    });

    test('false for a blank appId', () {
      expect(
        isRequestChangeCandidate(appId: '  ', isSignedInMember: true),
        isFalse,
      );
    });
  });

  group('canOfferRequestChange', () {
    test('false when the app has opted out (apps/{id}.allowChangeRequests)', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: false,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g1',
          entitlements: member,
        ),
        isFalse,
      );
    });

    test('true when the active group grants Improve Apps', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g1',
          entitlements: member,
        ),
        isTrue,
      );
    });

    test('false when Improve Apps is only granted in another group', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g2',
          entitlements: const UserAppEntitlements(
            entitlements: {'g1:improve-apps', 'g2:notes'},
            status: 'ACTIVE',
          ),
        ),
        isFalse,
      );
    });

    test('false without an active group', () {
      for (final groupId in [null, '']) {
        expect(
          canOfferRequestChange(
            allowChangeRequests: true,
            appId: 'notes',
            isSignedInMember: true,
            activeGroupId: groupId,
            entitlements: member,
          ),
          isFalse,
        );
      }
    });

    test('false when the account is suspended or the group frozen', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g1',
          entitlements: const UserAppEntitlements(
            entitlements: {'g1:improve-apps'},
            status: 'SUSPENDED',
          ),
        ),
        isFalse,
      );
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g1',
          entitlements: const UserAppEntitlements(
            entitlements: {'g1:improve-apps'},
            status: 'ACTIVE',
            deniedScopes: {'g1'},
          ),
        ),
        isFalse,
      );
    });

    test('false for an unreadable access index', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: true,
          activeGroupId: 'g1',
          entitlements: UserAppEntitlements.none,
        ),
        isFalse,
      );
    });

    test('false for guests even with the entitlement', () {
      expect(
        canOfferRequestChange(
          allowChangeRequests: true,
          appId: 'notes',
          isSignedInMember: false,
          activeGroupId: 'g1',
          entitlements: member,
        ),
        isFalse,
      );
    });
  });

  group('fallbackAppDisplayName', () {
    test('title-cases slug words', () {
      expect(fallbackAppDisplayName('habit-tracker'), 'Habit Tracker');
      expect(fallbackAppDisplayName('task_list'), 'Task List');
      expect(fallbackAppDisplayName('notes'), 'Notes');
    });

    test('has a generic fallback for a blank id', () {
      expect(fallbackAppDisplayName(''), 'this app');
    });
  });

  test('requestChangeSuccessMessage names the app and sets expectations', () {
    final message = requestChangeSuccessMessage('Notes');
    expect(message, contains('Notes'));
    expect(message, contains("we'll let you know when it's live"));
  });
}
