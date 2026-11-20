import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/account_status_service.dart';

void main() {
  group('setActive / setStatus', () {
    test('call adminSetUserStatus, never a Firestore write', () async {
      final calls = <List<Object>>[];
      final service = AccountStatusService(
        invoke: (name, data) async => calls.add([name, data]),
      );

      await service.setActive('u1', isActive: false);
      await service.setActive('u1', isActive: true);
      await service.setStatus('u2', 'suspended');

      expect(calls, [
        ['adminSetUserStatus', {'targetUid': 'u1', 'status': 'INACTIVE'}],
        ['adminSetUserStatus', {'targetUid': 'u1', 'status': 'ACTIVE'}],
        ['adminSetUserStatus', {'targetUid': 'u2', 'status': 'SUSPENDED'}],
      ]);
    });

    test('a server refusal propagates', () async {
      final service = AccountStatusService(
        invoke: (name, data) async => throw StateError('permission-denied'),
      );
      expect(service.setActive('u1', isActive: false), throwsStateError);
    });
  });

  test('isInactiveUserData reads the status mirror, not isBanned', () {
    expect(AccountStatusService.isInactiveUserData(null), isFalse);
    expect(AccountStatusService.isInactiveUserData({}), isFalse);
    expect(AccountStatusService.isInactiveUserData({'status': 'ACTIVE'}), isFalse);
    expect(AccountStatusService.isInactiveUserData({'status': 'inactive'}), isTrue);
    expect(AccountStatusService.isInactiveUserData({'status': 'SUSPENDED'}), isTrue);
    expect(AccountStatusService.isInactiveUserData({'isBanned': true}), isFalse);
  });

  group('isAccountBlocked', () {
    test('a deactivated claim blocks, whatever the index says', () {
      expect(AccountStatusService.isAccountBlocked(claimStatus: 'INACTIVE'), isTrue);
      expect(
        AccountStatusService.isAccountBlocked(
          claimStatus: 'SUSPENDED',
          accessIndex: {'status': 'ACTIVE'},
        ),
        isTrue,
      );
    });

    test('a deactivated access index blocks', () {
      expect(
        AccountStatusService.isAccountBlocked(accessIndex: {'status': 'INACTIVE'}),
        isTrue,
      );
    });

    test('active, missing, or a failed rebuild does not block', () {
      expect(AccountStatusService.isAccountBlocked(), isFalse);
      expect(
        AccountStatusService.isAccountBlocked(
          claimStatus: null,
          accessIndex: {'status': 'ACTIVE'},
        ),
        isFalse,
      );
      expect(
        AccountStatusService.isAccountBlocked(
          accessIndex: {'status': 'SUSPENDED', 'error': 'boom'},
        ),
        isFalse,
      );
    });
  });
}
