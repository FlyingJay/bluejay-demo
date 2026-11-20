import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/user_app_entitlements.dart';

UserAppEntitlements _index({
  List<String> roles = const [],
  List<String> entitlements = const [],
  String status = 'ACTIVE',
  List<String> deniedScopes = const [],
}) =>
    UserAppEntitlements.fromAccessIndexData({
      'roles': roles,
      'entitlements': entitlements,
      'status': status,
      'denied_scopes': deniedScopes,
    });

void main() {
  group('UserAppEntitlements.hasAppTier', () {
    test('ranks read < edit < admin', () {
      final member = _index(entitlements: ['g1:app']);
      final editor = _index(entitlements: ['g1:app', 'g1:app:edit']);
      final admin = _index(entitlements: ['g1:app:admin']);

      expect(member.hasAppTier('g1', 'app'), isTrue);
      expect(member.hasAppTier('g1', 'app', EntitlementTier.edit), isFalse);
      expect(editor.hasAppTier('g1', 'app', EntitlementTier.edit), isTrue);
      expect(editor.hasAppTier('g1', 'app', EntitlementTier.admin), isFalse);
      expect(admin.hasAppTier('g1', 'app'), isTrue);
      expect(admin.hasAppTier('g1', 'app', EntitlementTier.admin), isTrue);
    });

    test('never matches another group, app, or a guest collection scope', () {
      final index = _index(entitlements: ['g1:app', 'g2:other:admin', 'g3:app:collection:x']);
      expect(index.hasAppTier('g2', 'app'), isFalse);
      expect(index.hasAppTier('g1', 'other'), isFalse);
      expect(index.hasAppTier('g3', 'app'), isFalse);
    });

    test('respects status and denied_scopes, with only the admin role overriding', () {
      expect(_index(status: 'SUSPENDED', entitlements: ['g1:app:admin']).hasAppTier('g1', 'app'), isFalse);
      expect(_index(deniedScopes: ['g1'], entitlements: ['g1:app']).hasAppTier('g1', 'app'), isFalse);
      expect(UserAppEntitlements.fromAccessIndexData(null).hasAppTier('g1', 'app'), isFalse);
      expect(_index(roles: ['admin'], status: 'INACTIVE').hasAppTier('g1', 'app', EntitlementTier.admin), isTrue);
      expect(_index(roles: ['developer']).hasAppTier('g1', 'app'), isFalse);
    });

    test('does not change canAccessApp, which still lets developers through', () {
      expect(_index(roles: ['developer']).canAccessApp('g1', 'app'), isTrue);
    });
  });
}
