import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/tenant_ids.dart';

void main() {
  group('isValidTenantId', () {
    test('accepts lowercase letters, digits and inner hyphens up to 63 chars', () {
      for (final id in ['a', 'bluejay', 'naic-sight', 'a1-b2', 'x' * 63]) {
        expect(isValidTenantId(id), isTrue, reason: id);
      }
    });

    test('rejects separators, capitals, edge hyphens and overlong ids', () {
      for (final id in ['', 'group_a', 'a:b', 'Wiki', 'Mail Admin', '-a', 'a-', 'x' * 64]) {
        expect(isValidTenantId(id), isFalse, reason: id);
      }
    });
  });

  group('tenantIdFromName', () {
    test('slugifies a display name', () {
      expect(tenantIdFromName('Engineering Team'), 'engineering-team');
      expect(tenantIdFromName('  AI -- Chat!! '), 'ai-chat');
      expect(tenantIdFromName("Bob's_Shop"), 'bob-s-shop');
    });

    test('falls back when the name has no usable characters', () {
      expect(tenantIdFromName('!!!'), 'group');
      expect(tenantIdFromName('!!!', fallback: 'app'), 'app');
    });

    test('appends a uniqueness suffix', () {
      expect(tenantIdFromName('Engineering Team', suffix: 2), 'engineering-team-2');
    });

    test('caps the length but always keeps the suffix', () {
      final long = 'word ' * 30;
      final plain = tenantIdFromName(long);
      final suffixed = tenantIdFromName(long, suffix: 12);
      expect(plain.length, lessThanOrEqualTo(tenantIdMaxLength));
      expect(suffixed.length, lessThanOrEqualTo(tenantIdMaxLength));
      expect(suffixed.endsWith('-12'), isTrue);
      expect(isValidTenantId(plain), isTrue, reason: plain);
      expect(isValidTenantId(suffixed), isTrue, reason: suffixed);
      expect(tenantIdFromName(long, suffix: 13), isNot(suffixed));
    });

    test('always yields a valid id', () {
      for (final name in ['Été Group', '123', '-x-', 'A' * 200, '日本語', 'a_b:c']) {
        for (final suffix in [0, 1, 99]) {
          final id = tenantIdFromName(name, suffix: suffix);
          expect(isValidTenantId(id), isTrue, reason: '$name/$suffix → $id');
        }
      }
    });
  });
}
