import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/deterministic_rng.dart';

void main() {
  test('is repeatable for a seed', () {
    final a = DeterministicRng(42);
    final b = DeterministicRng(42);
    expect([for (var i = 0; i < 20; i++) a.nextRaw()],
        [for (var i = 0; i < 20; i++) b.nextRaw()]);
  });

  test('matches the Park-Miller reference sequence', () {
    // minstd_rand (48271) from seed 1: 48271, 182605794, 1291394886.
    final rng = DeterministicRng(0);
    expect(rng.nextRaw(), 48271);
    expect(rng.nextRaw(), 182605794);
    expect(rng.nextRaw(), 1291394886);
  });

  test('isqrt floors exactly', () {
    for (final n in [0, 1, 2, 3, 4, 15, 16, 17, 99, 100, 101, 2250000]) {
      final r = isqrt(n);
      expect(r * r <= n && (r + 1) * (r + 1) > n, isTrue, reason: '$n');
    }
  });
}
