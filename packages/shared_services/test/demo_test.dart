import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/demo.dart';

void main() {
  test('isDemoGroup / isDemoUser are true only for isDemo == true', () {
    expect(isDemoGroup({'isDemo': true}), isTrue);
    expect(isDemoUser({'isDemo': true}), isTrue);
    for (final data in <Map<String, dynamic>?>[
      null,
      {},
      {'isDemo': false},
      {'isDemo': 'true'},
      {'isDemo': 1},
    ]) {
      expect(isDemoGroup(data), isFalse, reason: '$data');
      expect(isDemoUser(data), isFalse, reason: '$data');
    }
  });
}
