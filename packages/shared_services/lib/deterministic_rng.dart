/// A seeded random number generator that gives the same sequence on every
/// platform.
///
/// Game simulations (Flock, Civ Empire) replay the same orders on every
/// device, so their map generators must agree between a phone running
/// native Dart and a browser running compiled JavaScript, where integers are
/// doubles and bitwise operators truncate to 32 bits. This is the
/// Park–Miller generator (multiplier 48271, modulus 2^31 - 1): every
/// intermediate product stays below 2^47, so it is exact in both.
class DeterministicRng {
  static const int _modulus = 2147483647;
  static const int _multiplier = 48271;

  int _state;

  DeterministicRng(int seed) : _state = _normalize(seed);

  static int _normalize(int seed) {
    var s = seed % (_modulus - 1);
    if (s < 0) s += _modulus - 1;
    return s + 1;
  }

  /// The next raw value, from 1 to 2^31 - 2.
  int nextRaw() {
    _state = (_state * _multiplier) % _modulus;
    return _state;
  }

  /// A value from 0 to [max] - 1.
  int nextInt(int max) {
    assert(max > 0);
    return nextRaw() % max;
  }

  /// A value from [min] to [max], both inclusive.
  int range(int min, int max) => min + nextInt(max - min + 1);

  /// True [percent] times in a hundred.
  bool chance(int percent) => nextInt(100) < percent;

  /// One of [items].
  T pick<T>(List<T> items) => items[nextInt(items.length)];
}

/// The integer square root: the largest `r` with `r * r <= n`. Newton's
/// method in integers, so it is exact on every platform.
int isqrt(int n) {
  if (n <= 0) return 0;
  var x = n;
  var y = (x + 1) ~/ 2;
  while (y < x) {
    x = y;
    y = (x + n ~/ x) ~/ 2;
  }
  return x;
}
