import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/change_request_list_scope.dart';
import 'package:shared_services/user_app_entitlements.dart';

void main() {
  const activeGroup = ChangeRequestListScope.activeGroup;
  const managedApps = ChangeRequestListScope.managedApps;
  const allGroups = ChangeRequestListScope.allGroups;

  group('isActivePlatformAdmin', () {
    UserAppEntitlements index(List<String> roles, String status) =>
        UserAppEntitlements.fromAccessIndexData({
          'roles': roles,
          'status': status,
        });

    test('requires the admin role on an ACTIVE account', () {
      expect(index(['admin'], 'ACTIVE').isActivePlatformAdmin, isTrue);
      expect(index(['admin'], 'active').isActivePlatformAdmin, isTrue);
      expect(index(['admin'], 'SUSPENDED').isActivePlatformAdmin, isFalse);
      expect(
        UserAppEntitlements.fromAccessIndexData({
          'roles': ['admin']
        }).isActivePlatformAdmin,
        isFalse,
        reason: 'a missing status fails closed, like the rules',
      );
    });

    test('developers, moderators and stewards are not platform admins', () {
      expect(index(['developer'], 'ACTIVE').isActivePlatformAdmin, isFalse);
      expect(index(['moderator'], 'ACTIVE').isActivePlatformAdmin, isFalse);
      expect(
        UserAppEntitlements.fromAccessIndexData({
          'roles': <String>[],
          'status': 'ACTIVE',
          'entitlements': ['app:notes:steward'],
        }).isActivePlatformAdmin,
        isFalse,
      );
      expect(UserAppEntitlements.none.isActivePlatformAdmin, isFalse);
    });
  });

  group('availableChangeRequestScopes', () {
    test('everyone gets only the active group by default', () {
      expect(
        availableChangeRequestScopes(
          hasStewardedApps: false,
          isPlatformAdmin: false,
        ),
        [activeGroup],
      );
    });

    test('All groups is offered to platform admins only', () {
      expect(
        availableChangeRequestScopes(
          hasStewardedApps: true,
          isPlatformAdmin: false,
        ),
        [activeGroup, managedApps],
      );
      expect(
        availableChangeRequestScopes(
          hasStewardedApps: false,
          isPlatformAdmin: true,
        ),
        [activeGroup, allGroups],
      );
      expect(
        availableChangeRequestScopes(
          hasStewardedApps: true,
          isPlatformAdmin: true,
        ),
        [activeGroup, managedApps, allGroups],
      );
    });
  });

  test('effectiveChangeRequestScope falls back when access is revoked', () {
    expect(
      effectiveChangeRequestScope(allGroups, [activeGroup, allGroups]),
      allGroups,
    );
    expect(
      effectiveChangeRequestScope(allGroups, [activeGroup, managedApps]),
      activeGroup,
    );
  });

  group('deepLinkChangeRequestScope', () {
    const other = {'groupId': 'g2', 'relatedAppId': 'notes'};

    test('stays put for the active group or an unreadable ticket', () {
      expect(
        deepLinkChangeRequestScope(
          {'groupId': 'g1'},
          activeGroupId: 'g1',
          stewardedAppIds: const {},
          isPlatformAdmin: true,
        ),
        isNull,
      );
      expect(
        deepLinkChangeRequestScope(
          null,
          activeGroupId: 'g1',
          stewardedAppIds: const {'notes'},
          isPlatformAdmin: true,
        ),
        isNull,
      );
    });

    test('prefers Apps I manage, then All groups for admins', () {
      expect(
        deepLinkChangeRequestScope(
          other,
          activeGroupId: 'g1',
          stewardedAppIds: const {'notes'},
          isPlatformAdmin: true,
        ),
        managedApps,
      );
      expect(
        deepLinkChangeRequestScope(
          other,
          activeGroupId: 'g1',
          stewardedAppIds: const {},
          isPlatformAdmin: true,
        ),
        allGroups,
      );
      expect(
        deepLinkChangeRequestScope(
          other,
          activeGroupId: 'g1',
          stewardedAppIds: const {},
          isPlatformAdmin: false,
        ),
        isNull,
      );
    });
  });

  test('isChangeRequestWritableInScope: only the ticket\'s own group, in every scope', () {
    const foreign = {'groupId': 'g2'};
    for (final scope in [activeGroup, managedApps, allGroups]) {
      expect(
        isChangeRequestWritableInScope(foreign,
            scope: scope, activeGroupId: 'g1'),
        isFalse,
        reason: '$scope: another group\'s ticket is read and comment only',
      );
      expect(
        isChangeRequestWritableInScope({'groupId': 'g1'},
            scope: scope, activeGroupId: 'g1'),
        isTrue,
        reason: '$scope: the active group\'s own ticket',
      );
    }
    expect(
      isChangeRequestWritableInScope({'groupId': ''},
          scope: allGroups, activeGroupId: ''),
      isFalse,
      reason: 'no active group: nothing is writable',
    );
  });

  test('changeRequestScopeLabel names the source group in mixed scopes', () {
    const ticket = {
      'groupId': 'g2',
      'groupName': 'Globex',
      'relatedAppId': 'notes',
      'relatedAppName': 'Notes',
    };
    expect(changeRequestScopeLabel(ticket, activeGroup), isNull);
    expect(changeRequestScopeLabel(ticket, managedApps), 'Globex · Notes');
    expect(changeRequestScopeLabel(ticket, allGroups), 'Globex · Notes');
    expect(
      changeRequestScopeLabel({'groupId': 'g2'}, allGroups),
      'g2',
      reason: 'no related app and no stamped name: the raw group id',
    );
  });
}
