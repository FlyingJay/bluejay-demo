import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/user_app_entitlements.dart';

void main() {
  group('UserAppEntitlements', () {
    test('canAccessApp is true when the scoped entitlement is present', () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'entitlements': ['group-1:notes'],
      });
      expect(access.canAccessApp('group-1', 'notes'), isTrue);
    });

    test('canAccessApp is false when segment-restricted (no entitlement)', () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'entitlements': ['group-1:notes'],
      });
      expect(access.canAccessApp('group-1', 'reports'), isFalse);
    });

    test('canAccessApp is false for an entitlement scoped to another group', () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'entitlements': ['group-2:notes'],
      });
      expect(access.canAccessApp('group-1', 'notes'), isFalse);
    });

    test('platform admin bypasses entitlement checks entirely', () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'roles': ['admin'],
        'entitlements': [],
      });
      expect(access.canAccessApp('group-1', 'notes'), isTrue);
    });

    test('platform developer bypasses entitlement checks entirely', () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'roles': ['developer'],
        'entitlements': [],
      });
      expect(access.canAccessApp('group-1', 'notes'), isTrue);
    });

    test('fromAccessIndexData tolerates null/missing data', () {
      final access = UserAppEntitlements.fromAccessIndexData(null);
      expect(access.canAccessApp('group-1', 'notes'), isFalse);
    });

    test('filterAccessibleAppIds preserves order and drops inaccessible ids',
        () {
      final access = UserAppEntitlements.fromAccessIndexData({
        'entitlements': ['group-1:notes', 'group-1:reports'],
      });
      expect(
        access.filterAccessibleAppIds(
            'group-1', ['polls', 'notes', 'billing', 'reports']),
        ['notes', 'reports'],
      );
    });
  });
}
