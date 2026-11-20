import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/email_recipients.dart';

void main() {
  group('normalizeEmailAddress', () {
    test('lowercases and trims plausible addresses', () {
      expect(normalizeEmailAddress('  Pat@Example.COM '), 'pat@example.com');
    });

    test('blanks implausible, null and overlong values', () {
      expect(normalizeEmailAddress('not-an-email'), '');
      expect(normalizeEmailAddress(null), '');
      expect(normalizeEmailAddress('${'x' * 250}@example.com'), '');
    });
  });

  group('normalizeEmailRecipients', () {
    test('skips blanks, de-duplicates and drops excluded addresses', () {
      final result = normalizeEmailRecipients(
        [' A@Example.com', 'a@example.com', '', 'Primary@Example.com', 'b@x.org'],
        exclude: ['primary@example.com'],
      );
      expect(result.recipients, ['a@example.com', 'b@x.org']);
      expect(result.invalid, isEmpty);
      expect(result.isValid, isTrue);
    });

    test('reports invalid entries', () {
      final result = normalizeEmailRecipients(['ok@x.co', 'nope']);
      expect(result.recipients, ['ok@x.co']);
      expect(result.invalid, ['nope']);
      expect(result.isValid, isFalse);
    });

    test('checks max after de-duplication', () {
      expect(
        normalizeEmailRecipients(['a@x.co', 'A@x.co', 'b@x.co'], max: 2).tooMany,
        isFalse,
      );
      expect(
        normalizeEmailRecipients(['a@x.co', 'b@x.co', 'c@x.co'], max: 2).tooMany,
        isTrue,
      );
    });
  });
}
