import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/data_deletion_requests.dart';

void main() {
  test('a result reads the request the callable returns', () {
    final result = DeletionRequestResult.fromData({
      'created': false,
      'request': {
        'requestId': 'r1',
        'scope': 'group',
        'groupId': 'shop',
        'groupName': 'Corner Shop',
        'status': 'in_progress',
        'open': true,
        'reason': 'Closing',
        'requesterName': 'Olive',
        'createdAtMs': 1763300000000,
      },
    });
    expect(result.created, isFalse);
    expect(result.request.scope, DeletionRequestScope.group);
    expect(result.request.groupId, 'shop');
    expect(result.request.statusLabel, 'In progress');
    expect(result.request.open, isTrue);
    expect(result.request.createdAt, DateTime.fromMillisecondsSinceEpoch(1763300000000));
  });

  test('an account request has no group; unknown fields fall back', () {
    final request = DeletionRequest.fromData({'requestId': 'r2', 'scope': 'account', 'status': 'completed', 'open': false});
    expect(request.scope, DeletionRequestScope.account);
    expect(request.groupId, isNull);
    expect(request.statusLabel, 'Completed');
    expect(request.open, isFalse);
    expect(DeletionRequest.fromData(const {}).status, 'requested');
  });
}
