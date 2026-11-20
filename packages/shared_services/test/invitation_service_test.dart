import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/invitation_service.dart';

void main() {
  group('claimPasswordProblem', () {
    test('accepts a long-enough matching password', () {
      expect(claimPasswordProblem('correct horse', 'correct horse'), isNull);
      expect(claimPasswordProblem('x' * kClaimMinPasswordLength, 'x' * kClaimMinPasswordLength), isNull);
    });

    test('refuses short, overlong, blank and mismatched passwords', () {
      expect(claimPasswordProblem('short', 'short'), contains('at least'));
      final long = 'x' * (kClaimMaxPasswordLength + 1);
      expect(claimPasswordProblem(long, long), contains('at most'));
      expect(claimPasswordProblem('          ', '          '), contains('spaces'));
      expect(claimPasswordProblem('correct horse', 'correct horsf'), contains("don't match"));
    });
  });

  group('InvitationClaim.fromMap', () {
    test('reads a full workspace\'s noSeatsMessage', () {
      final full = InvitationClaim.fromMap({'status': 'valid', 'groupName': 'Acme', 'noSeatsMessage': 'Acme is full.'});
      expect(full.isValid, isTrue);
      expect(full.noSeatsMessage, 'Acme is full.');
      expect(InvitationClaim.fromMap({'status': 'valid', 'noSeatsMessage': null}).noSeatsMessage, isNull);
      final later = InvitationClaim.fromMap({'status': 'valid', 'groupName': 'Acme'}).withNoSeats('No seats left.');
      expect(later.groupName, 'Acme');
      expect(later.noSeatsMessage, 'No seats left.');
    });

    test('reads a valid preview', () {
      final claim = InvitationClaim.fromMap({
        'status': 'valid',
        'username': 'zed',
        'email': 'zed@bluejay.gg',
        'groupId': 'g1',
        'groupName': 'Acme',
        'groupLogoUrl': '',
        'inviterName': 'Olive',
        'role': 'editor',
        'contactHint': 'z•••@example.com',
        'deliveredVia': 'email',
        'expiresAtMs': 1793000000000,
      });
      expect(claim.isValid, isTrue);
      expect(claim.username, 'zed');
      expect(claim.groupLogoUrl, isNull);
      expect(claim.role, 'editor');
      expect(claim.expiresAt, DateTime.fromMillisecondsSinceEpoch(1793000000000));
    });

    test('anything unrecognised is an invalid link', () {
      expect(InvitationClaim.fromMap(null).status, InvitationClaimStatus.invalid);
      expect(InvitationClaim.fromMap({'status': 'weird'}).status, InvitationClaimStatus.invalid);
      expect(InvitationClaim.fromMap({'status': 'expired'}).status, InvitationClaimStatus.expired);
      expect(InvitationClaim.fromMap({'status': 'claimed', 'message': 'used'}).message, 'used');
    });
  });

  group('claimTokenFromUri', () {
    test('finds the token on the claim route only', () {
      expect(claimTokenFromUri(Uri.parse('https://bluejay.gg/claim?token=abc_-1')), 'abc_-1');
      expect(claimTokenFromUri(Uri.parse('https://bluejay.gg/claim')), '');
      expect(claimTokenFromUri(Uri.parse('https://bluejay.gg/claim/?token=t')), 't');
      expect(claimTokenFromUri(Uri.parse('https://bluejay.gg/acme?token=t')), isNull);
      expect(claimTokenFromUri(Uri.parse('https://bluejay.gg/')), isNull);
    });
  });
}
