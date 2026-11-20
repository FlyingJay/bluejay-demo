import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/login_identifier.dart';

void main() {
  test('a username tries @bluejay.gg, then legacy @bluejay.ca', () {
    final id = LoginIdentifier.parse('  Jay ');
    expect(id.isUsername, isTrue);
    expect(id.username, 'jay');
    expect(id.emails, ['jay@bluejay.gg', 'jay@bluejay.ca']);
    expect(id.primaryEmail, 'jay@bluejay.gg');
  });

  test('a Bluejay login address counts as its username', () {
    expect(LoginIdentifier.parse('jay@bluejay.gg').emails, ['jay@bluejay.gg', 'jay@bluejay.ca']);
    expect(LoginIdentifier.parse('Jay@Bluejay.ca').username, 'jay');
  });

  test('any other email address is used as it is, lowercased', () {
    final id = LoginIdentifier.parse(' Pat@Example.COM ');
    expect(id.isUsername, isFalse);
    expect(id.username, isNull);
    expect(id.emails, ['pat@example.com']);
    expect(id.primaryEmail, 'pat@example.com');
  });

  test('a subdomain of a Bluejay domain is an outside address', () {
    expect(LoginIdentifier.parse('a@mail.bluejay.gg').isUsername, isFalse);
  });

  test('blank input gives nothing to try', () {
    expect(LoginIdentifier.parse('   ').emails, isEmpty);
    expect(LoginIdentifier.parse('').primaryEmail, isNull);
  });

  test('isLegacyEmail', () {
    expect(LoginIdentifier.isLegacyEmail('jay@bluejay.ca'), isTrue);
    expect(LoginIdentifier.isLegacyEmail('jay@bluejay.gg'), isFalse);
  });
}
