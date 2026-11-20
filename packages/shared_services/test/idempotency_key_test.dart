import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/idempotency_key.dart';

void main() {
  test('newIdempotencyKey is fresh each call', () {
    expect(newIdempotencyKey(), isNot(newIdempotencyKey()));
  });

  test('sessionIdempotencyKey reuses one key per attempt until cleared', () {
    final first = sessionIdempotencyKey('signup|team|acme');
    expect(sessionIdempotencyKey('signup|team|acme'), first);
    expect(sessionIdempotencyKey('signup|team|other'), isNot(first));
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')));

    clearSessionIdempotencyKey('signup|team|acme');
    expect(sessionIdempotencyKey('signup|team|acme'), isNot(first));
  });
}
