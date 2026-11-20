import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'bluejay_firestore.dart';
import 'login_identifier.dart';
import 'usage_meter.dart';
import 'package:shared_services/cloud_functions.dart';

/// Result codes returned by [GuestUserService.signInAsGuestWithIdentity].
enum GuestIdentityResult {
  /// Session created and domain was whitelisted.
  success,

  /// The email domain is not on the group's whitelist.
  domainDenied,

  /// A one-time code was emailed to the address; call again with it.
  codeSent,

  /// The code was wrong, expired or already used, too many were requested,
  /// or no email could be sent (demo groups).
  codeRefused,

  /// An unexpected error occurred.
  error,
}

/// Manages the lifecycle of anonymous (guest) users who access embeddable apps
/// via deep links without logging in.
///
/// A guest user is created as an anonymous Firebase Auth user. All data they
/// create is stored under their anonymous UID. When they "claim" their account
/// by choosing a username and password, their anonymous credential is linked to
/// an email credential (`username@bluejay.gg`). The UID – and therefore all of
/// their data – is preserved.
class GuestUserService {
  static final _functions = BluejayFunctions.instance;
  static const _kUserNotFound = 'user-not-found';
  static const _kInvalidCredential = 'invalid-credential';

  // ---------------------------------------------------------------------------
  // Guest session creation
  // ---------------------------------------------------------------------------

  /// Signs in anonymously and configures a guest session for the given group
  /// and app.
  ///
  /// Calls the `createGuestSession` Cloud Function, which:
  ///  - Verifies the app is flagged as `isEmbeddable`.
  ///  - Verifies the group has the app installed.
  ///  - Creates the user document, membership, and access index.
  ///
  /// Returns `true` on success, `false` if the app is not embeddable or any
  /// other error occurs (in which case the anonymous session is cleaned up).
  static Future<bool> signInAsGuest(String groupId, String appId) async {
    try {
      await fire_auth.FirebaseAuth.instance.signInAnonymously();
      final callable = _functions.httpsCallable('createGuestSession');
      await callable.call({'groupId': groupId, 'appId': appId});
      return true;
    } catch (e) {
      // Ensure we don't leave a dangling anonymous session on failure.
      try {
        await signOutWithUsageFlush();
      } catch (_) {}
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Guest session with identity (name + email, domain whitelist enforced)
  // ---------------------------------------------------------------------------

  /// Signs in anonymously and creates a guest session that requires the user
  /// to supply their [guestName] and [guestEmail].
  ///
  /// The `createGuestSessionWithIdentity` Cloud Function validates the email
  /// domain against the group's whitelist before creating the session. If the
  /// domain is not approved, the anonymous session is cleaned up and
  /// [GuestIdentityResult.domainDenied] is returned.
  ///
  /// The guest must prove they control [guestEmail]: the first call emails a
  /// one-time code and returns [GuestIdentityResult.codeSent], keeping the
  /// anonymous session; call again with [code] from the same session.
  ///
  /// This is an additive call path; the existing [signInAsGuest] method and
  /// `createGuestSession` Cloud Function are unchanged.
  static Future<GuestIdentityResult> signInAsGuestWithIdentity(
    String groupId,
    String appId, {
    required String guestName,
    required String guestEmail,
    String? code,
  }) async {
    try {
      // The code is bound to the uid it was sent for, so keep the session.
      // Guest sessions are for anonymous users only (the server refuses others).
      final current = fire_auth.FirebaseAuth.instance.currentUser;
      if (current == null || !current.isAnonymous) {
        await fire_auth.FirebaseAuth.instance.signInAnonymously();
      }
      final callable =
          _functions.httpsCallable('createGuestSessionWithIdentity');
      final result = await callable.call({
        'groupId': groupId,
        'appId': appId,
        'guestName': guestName,
        'guestEmail': guestEmail,
        if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['codeSent'] == true) return GuestIdentityResult.codeSent;
      if (data['codeInvalid'] == true || data['rateLimited'] == true || data['sendSkipped'] == true) {
        return GuestIdentityResult.codeRefused;
      }
      if (data['domainAllowed'] == false) {
        // Domain not whitelisted – clean up the anonymous session.
        try {
          await signOutWithUsageFlush();
        } catch (_) {}
        return GuestIdentityResult.domainDenied;
      }
      return data['success'] == true ? GuestIdentityResult.success : GuestIdentityResult.error;
    } catch (e) {
      try {
        await signOutWithUsageFlush();
      } catch (_) {}
      return GuestIdentityResult.error;
    }
  }

  // ---------------------------------------------------------------------------
  // Guest detection
  // ---------------------------------------------------------------------------

  /// Returns `true` when the currently signed-in Firebase Auth user is an
  /// anonymous session (a visitor who has not claimed an account). This is
  /// about how they signed in; whether someone is a guest in a group is
  /// GuestStatus (guest_status.dart).
  static bool isCurrentUserGuest() {
    return fire_auth.FirebaseAuth.instance.currentUser?.isAnonymous ?? false;
  }

  // ---------------------------------------------------------------------------
  // Username availability
  // ---------------------------------------------------------------------------

  /// Checks whether [username] is available.
  ///
  /// A username is taken when `$username@bluejay.gg` is already registered in
  /// Firebase Auth.  Returns a map with:
  ///  - `available` (bool): whether the username can be used.
  ///  - `reason` (String?): a human-readable explanation when not available.
  static Future<Map<String, dynamic>> checkUsernameAvailable(
      String username) async {
    try {
      final callable = _functions.httpsCallable('checkUsernameAvailable');
      final result = await callable.call({'username': username});
      return Map<String, dynamic>.from(result.data as Map);
    } catch (_) {
      return {'available': false, 'reason': 'Error checking availability.'};
    }
  }

  // ---------------------------------------------------------------------------
  // Account claiming
  // ---------------------------------------------------------------------------

  /// Claims the guest account by linking an email + password credential.
  ///
  /// After this call:
  ///  - The Firebase Auth user is no longer anonymous.
  ///  - The UID is unchanged, so all previously created data is preserved.
  ///  - The Firestore user document is updated with the new email.
  ///  - `portalClaimVisitor` has kept each visitor membership, so the account
  ///    keeps the apps it was using and the records it created there. It
  ///    becomes a client membership only where the group's portal admits the
  ///    account as an active client and gives every app it holds (a pure
  ///    upgrade); a claim never removes a membership. The server also sets
  ///    `users.isGuest: false`, which keeps the account out of the nightly
  ///    purge of anonymous visitors, and rebuilds the access index. Returns
  ///    its per-group results (empty if the call failed: the account is
  ///    claimed and keeps its visitor memberships either way).
  ///
  /// Throws a [fire_auth.FirebaseAuthException] if linking fails (e.g. email
  /// already in use, weak password).
  static Future<List<VisitorClaimResult>> claimAccount(String username, String password) async {
    final user = fire_auth.FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('No authenticated user to claim.');

    final email = '$username@bluejay.gg';
    final credential = fire_auth.EmailAuthProvider.credential(
      email: email,
      password: password,
    );

    // Link the anonymous credential to the new email credential.
    // The UID and all Firestore data remain intact.
    await user.linkWithCredential(credential);

    // Update the user document.  The doc already has creatorId == uid so the
    // Firestore security-rules ownership check allows this write.
    // isGuest is written here too (portalClaimVisitor sets it as well) so
    // the purge of inactive visitors never takes a claimed account whose
    // callable below failed.
    await BluejayFirestore.forApp(platformAppId)
        .collection('users')
        .doc(user.uid)
        .set({
      'email': email,
      'uid': user.uid,
      'isGuest': false,
      // Flag the email account as not yet created so the existing
      // login-screen mechanism can provision the mailbox on next login.
      'emailAccountCreated': false,
      'lastLogin': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));

    try {
      // The callable refuses anonymous tokens: refresh so it sees the
      // password sign-in the link just added.
      await fire_auth.FirebaseAuth.instance.currentUser?.getIdToken(true);
      final result = await _functions.httpsCallable('portalClaimVisitor').call(<String, dynamic>{});
      return VisitorClaimResult.listFrom(result.data);
    } catch (_) {
      return const [];
    }
  }

  /// Signs in to an existing account with a Bluejay username or an email
  /// address ([LoginIdentifier]) and a password.
  ///
  /// A username tries the preferred `@bluejay.gg` email first, then falls
  /// back to legacy `@bluejay.ca` for older accounts. Any other address is
  /// used as it is (a portal client's real email).
  static Future<void> signInWithExistingAccount(
      String usernameOrEmail, String password) async {
    final emails = LoginIdentifier.parse(usernameOrEmail).emails;
    if (emails.isEmpty) {
      throw fire_auth.FirebaseAuthException(code: _kInvalidCredential);
    }
    for (var i = 0; i < emails.length; i++) {
      try {
        await fire_auth.FirebaseAuth.instance
            .signInWithEmailAndPassword(email: emails[i], password: password);
        return;
      } on fire_auth.FirebaseAuthException catch (e) {
        final last = i == emails.length - 1;
        if (last || (e.code != _kUserNotFound && e.code != _kInvalidCredential)) rethrow;
      }
    }
  }
}

/// One group's outcome of `portalClaimVisitor` after a visitor claims an
/// account: they became an active client there ([becameClient], [status]
/// `active`), or they stay a visitor of the group with the same apps.
class VisitorClaimResult {
  const VisitorClaimResult({required this.groupId, required this.becameClient, this.status});

  /// The group's doc id.
  final String groupId;
  final bool becameClient;
  final String? status;

  static List<VisitorClaimResult> listFrom(Object? data) {
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];
    return [
      for (final raw in results.whereType<Map>())
        VisitorClaimResult(
          groupId: raw['groupId']?.toString() ?? '',
          becameClient: raw['outcome'] == 'client',
          status: raw['status']?.toString(),
        ),
    ];
  }
}
