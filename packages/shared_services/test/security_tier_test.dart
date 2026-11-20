import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/security_tier.dart';

void main() {
  test('effectiveSecurityTier is the lower of declared and computed, as the install gate judges', () {
    expect(effectiveSecurityTier('business', 'casual'), 'casual');
    expect(effectiveSecurityTier('casual', 'regulated'), 'casual');
    expect(effectiveSecurityTier('business', null), 'business');
    expect(effectiveSecurityTier(null, 'shared'), 'casual');
    expect(effectiveSecurityTier('regulated', 'not-a-tier'), 'regulated');
  });

  test('every tier has a one-line meaning; unknown tiers read as casual', () {
    for (final tier in securityTiers) {
      expect(securityTierMeaning(tier), isNotEmpty);
    }
    expect(securityTierMeaning('nonsense'), securityTierMeaning('casual'));
  });
}
