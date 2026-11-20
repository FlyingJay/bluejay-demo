import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_services/cloud_functions.dart';

/// The shortest and longest password `claimInvitation` accepts
/// (functions/group_membership.js MIN_PASSWORD_LENGTH / MAX_PASSWORD_LENGTH).
const int kClaimMinPasswordLength = 8;
const int kClaimMaxPasswordLength = 128;

/// Why [password] (with its [confirmation]) can't be used to claim an
/// account, or null. Mirrors claimInvitation's server-side check, plus the
/// confirmation match only the form has.
String? claimPasswordProblem(String password, String confirmation) {
  if (password.length < kClaimMinPasswordLength) {
    return 'Use at least $kClaimMinPasswordLength characters.';
  }
  if (password.length > kClaimMaxPasswordLength) {
    return 'Use at most $kClaimMaxPasswordLength characters.';
  }
  if (password.trim().isEmpty) return "Your password can't be only spaces.";
  if (password != confirmation) return "The passwords don't match.";
  return null;
}

/// Why a claim link can't be used (`getInvitationClaim`'s `status`).
enum InvitationClaimStatus { valid, invalid, expired, claimed }

InvitationClaimStatus _statusFrom(Object? value) {
  switch (value) {
    case 'valid':
      return InvitationClaimStatus.valid;
    case 'expired':
      return InvitationClaimStatus.expired;
    case 'claimed':
      return InvitationClaimStatus.claimed;
    default:
      return InvitationClaimStatus.invalid;
  }
}

/// What a claim link is an invitation to, as `getInvitationClaim` describes
/// it: shown on the claim screen before the invitee sets a password.
class InvitationClaim {
  const InvitationClaim({
    required this.status,
    this.message,
    this.username = '',
    this.email = '',
    this.groupId = '',
    this.groupName = '',
    this.groupLogoUrl,
    this.inviterName = '',
    this.role = 'member',
    this.contactHint = '',
    this.deliveredVia = 'email',
    this.expiresAt,
    this.noSeatsMessage,
  });

  factory InvitationClaim.fromMap(Object? data) {
    final map = data is Map ? data : const {};
    String text(String key) {
      final value = map[key];
      return value is String ? value : '';
    }

    final expiresAtMs = map['expiresAtMs'];
    final logo = text('groupLogoUrl');
    return InvitationClaim(
      status: _statusFrom(map['status']),
      message: text('message').isEmpty ? null : text('message'),
      username: text('username'),
      email: text('email'),
      groupId: text('groupId'),
      groupName: text('groupName'),
      groupLogoUrl: logo.isEmpty ? null : logo,
      inviterName: text('inviterName'),
      role: text('role').isEmpty ? 'member' : text('role'),
      contactHint: text('contactHint'),
      deliveredVia: text('deliveredVia').isEmpty ? 'email' : text('deliveredVia'),
      expiresAt: expiresAtMs is num
          ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs.toInt())
          : null,
      noSeatsMessage:
          text('noSeatsMessage').isEmpty ? null : text('noSeatsMessage'),
    );
  }

  final InvitationClaimStatus status;

  /// The server's explanation when [status] isn't valid.
  final String? message;
  final String username;

  /// The sign-in address the account is created under (`<username>@bluejay.gg`).
  final String email;
  final String groupId;
  final String groupName;
  final String? groupLogoUrl;
  final String inviterName;
  final String role;

  /// The contact the link was sent to, masked (`j•••@example.com`).
  final String contactHint;

  /// `email` or `sms`.
  final String deliveredVia;
  final DateTime? expiresAt;

  /// Why the workspace can't take the invitee right now, when it has no
  /// free seat (plans/group-seats/DESIGN.md); null when it has room. The
  /// link stays valid and works once a seat frees up.
  final String? noSeatsMessage;

  bool get isValid => status == InvitationClaimStatus.valid;

  /// This claim, with the workspace found full ([message] from the server).
  InvitationClaim withNoSeats(String message) => InvitationClaim(
        status: status,
        message: this.message,
        username: username,
        email: email,
        groupId: groupId,
        groupName: groupName,
        groupLogoUrl: groupLogoUrl,
        inviterName: inviterName,
        role: role,
        contactHint: contactHint,
        deliveredVia: deliveredVia,
        expiresAt: expiresAt,
        noSeatsMessage: message,
      );
}

/// The result of a successful `claimInvitation`.
class ClaimedInvitation {
  const ClaimedInvitation({
    required this.email,
    required this.createdAccount,
    required this.joinedGroupIds,
    this.waitingForSeat = false,
  });

  /// The sign-in address to sign in with.
  final String email;

  /// False when the caller was already signed in as the invited username.
  final bool createdAccount;
  final List<String> joinedGroupIds;

  /// The account exists (or was signed in), but the workspace had no free
  /// seat, so it joins at a later sign-in once one frees up.
  final bool waitingForSeat;
}

/// Workspace invitations, from the invitee's side: the callables in
/// functions/group_membership.js.
///
/// Invitations and memberships are server-written (security/collections.json),
/// so an invitee can neither read their invitation nor create their own
/// membership. An invitation arrives as a single-use claim link
/// (`/claim?token=...`): [getClaim] describes it and [claim] creates the
/// account and joins the workspace. [hasPendingInvitation] lets the login
/// screen tell an invitee to use their link.
class InvitationService {
  InvitationService({FirebaseFunctions? functions})
      : _functions = functions ?? BluejayFunctions.instance;

  final FirebaseFunctions _functions;

  /// Whether a pending invitation exists for [email] (`lookupInvitation`,
  /// callable without signing in and rate limited). Throws
  /// [FirebaseFunctionsException] (`resource-exhausted` after too many
  /// attempts).
  Future<bool> hasPendingInvitation(String email) async {
    final result = await _functions
        .httpsCallable('lookupInvitation')
        .call(<String, dynamic>{'email': email});
    final data = result.data;
    return data is Map && data['invited'] == true;
  }

  /// What the claim link [token] is an invitation to (`getInvitationClaim`,
  /// callable without signing in, rate limited).
  Future<InvitationClaim> getClaim(String token) async {
    final result = await _functions
        .httpsCallable('getInvitationClaim')
        .call(<String, dynamic>{'token': token});
    return InvitationClaim.fromMap(result.data);
  }

  /// Claims the invitation behind [token] (`claimInvitation`). Signed out,
  /// creates the account with [password]; signed in as the invited
  /// username, just joins. Throws [FirebaseFunctionsException]:
  /// `failed-precondition` (details `reason`: invalid, expired, claimed,
  /// account-exists, no-seats), `invalid-argument` (password),
  /// `resource-exhausted`.
  Future<ClaimedInvitation> claim(
    String token, {
    String? password,
    bool acceptedTerms = false,
  }) async {
    final result = await _functions.httpsCallable('claimInvitation').call(
      <String, dynamic>{
        'token': token,
        if (password != null) 'password': password,
        if (acceptedTerms) 'acceptedTerms': true,
      },
    );
    final data = result.data is Map ? result.data as Map : const {};
    final accepted = data['accepted'];
    return ClaimedInvitation(
      email: data['email'] is String ? data['email'] as String : '',
      createdAccount: data['createdAccount'] != false,
      joinedGroupIds: accepted is List
          ? accepted.whereType<String>().toList()
          : const <String>[],
      waitingForSeat: data['waitingForSeat'] == true,
    );
  }

  /// Finishes joining for invitations the signed-in user already claimed
  /// through their link, if the claim's join step didn't complete
  /// (`acceptInvitation`). Returns the joined group ids; safe to repeat.
  Future<List<String>> acceptPendingInvitations() async {
    final result = await _functions
        .httpsCallable('acceptInvitation')
        .call(<String, dynamic>{});
    final data = result.data;
    final accepted = data is Map ? data['accepted'] : null;
    return accepted is List ? accepted.whereType<String>().toList() : const [];
  }

  /// Sends a pending invitation a new claim link (`resendInvitation`); the
  /// earlier links stop working. [contact] (an email or phone number)
  /// replaces the invitation's contact first. Returns `email` or `sms`.
  Future<String> resend(String invitationId, {String? contact}) async {
    final result = await _functions.httpsCallable('resendInvitation').call(
      <String, dynamic>{
        'invitationId': invitationId,
        if (contact != null && contact.trim().isNotEmpty) 'contact': contact,
      },
    );
    final data = result.data;
    return data is Map && data['via'] is String ? data['via'] as String : 'email';
  }
}

/// The claim token in a web URL like `https://bluejay.gg/claim?token=...`,
/// or null when [uri] isn't a claim link.
String? claimTokenFromUri(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty || segments.first != 'claim') return null;
  final token = uri.queryParameters['token']?.trim() ?? '';
  return token;
}
