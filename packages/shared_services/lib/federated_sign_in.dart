import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'app_environment.dart';

/// An identity provider a Bluejay account can sign in with besides its
/// username and password. Every account still has a username and a
/// `<username>@bluejay.gg` sign-in email (functions/_new_accounts.js); a
/// provider is linked to that account, so signing in with it opens the
/// same account.
///
/// [enabled] providers show in the app. A provider must also be turned on
/// in Firebase Authentication, and its id must be in FEDERATED_PROVIDERS
/// (functions/_self_serve_signup.js) for signup to accept it.
enum FederatedProvider {
  google('google.com', 'Google', enabled: true),
  microsoft('microsoft.com', 'Microsoft', enabled: false),
  apple('apple.com', 'Apple', enabled: false);

  const FederatedProvider(this.id, this.label, {required this.enabled});

  /// Firebase's provider id (`google.com`).
  final String id;
  final String label;
  final bool enabled;

  /// The providers the app offers, in order.
  static List<FederatedProvider> get available =>
      values.where((p) => p.enabled).toList(growable: false);

  static FederatedProvider? byId(String? id) {
    for (final provider in values) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  fire_auth.AuthProvider _authProvider() {
    switch (this) {
      case FederatedProvider.google:
        return fire_auth.GoogleAuthProvider()
          ..setCustomParameters({'prompt': 'select_account'});
      case FederatedProvider.microsoft:
        return fire_auth.MicrosoftAuthProvider()
          ..setCustomParameters({'prompt': 'select_account'});
      case FederatedProvider.apple:
        return fire_auth.AppleAuthProvider();
    }
  }
}

/// Why a provider sign-in or link didn't work, with a message fit to show.
class FederatedSignInException implements Exception {
  const FederatedSignInException(this.message, {this.code});

  final String message;

  /// `no-account`, `already-linked`, `recent-login`, `last-method`,
  /// [previewUnavailableCode], or the Firebase Auth error code.
  final String? code;

  @override
  String toString() => message;
}

/// The providers linked to [user], in [FederatedProvider] order.
List<FederatedProvider> linkedProviders(fire_auth.User? user) {
  final ids = {
    for (final info in user?.providerData ?? const []) info.providerId
  };
  return FederatedProvider.values.where((p) => ids.contains(p.id)).toList();
}

/// Whether [user] can sign in with a password.
bool hasPassword(fire_auth.User? user) =>
    (user?.providerData ?? const []).any((i) => i.providerId == 'password');

/// The email [provider] shared for [user], or null.
String? providerEmail(fire_auth.User? user, FederatedProvider provider) {
  for (final info in user?.providerData ?? const []) {
    if (info.providerId == provider.id) return info.email;
  }
  return null;
}

/// Sign-in, signup and linking with identity providers. Accounts are never
/// created by the browser (the blockClientSignups blocking function refuses
/// that), so:
///   - [signIn] opens an account the provider is already linked to;
///   - [startSignup] links the provider to a guest session, which
///     `signupCreateFederatedAccount` then turns into an account;
///   - [link] and [unlink] change the providers of the signed-in account.
class FederatedSignIn {
  const FederatedSignIn._();

  static fire_auth.FirebaseAuth get _auth => fire_auth.FirebaseAuth.instance;

  /// The [FederatedSignInException.code] when provider sign-in isn't
  /// available in this build (a pull request preview, app_environment.dart).
  static const String previewUnavailableCode = 'preview-unavailable';

  /// Whether provider sign-in is off in this build; tests override it.
  @visibleForTesting
  static bool unavailable = kFederatedSignInUnavailable;

  /// The notice shown when someone picks [provider] in a preview build.
  static FederatedSignInException previewUnavailable(FederatedProvider provider) => FederatedSignInException(
        '${provider.label} sign-in doesn\'t work in test versions of Bluejay yet. '
        'Sign in with your username or email and your password instead. If you '
        'only sign in with ${provider.label}, you can try this change once it goes live.',
        code: previewUnavailableCode,
      );

  static void _checkAvailable(FederatedProvider provider) {
    if (unavailable) throw previewUnavailable(provider);
  }

  /// Signs in with [provider]. Returns null when the person closed the
  /// window. Throws [FederatedSignInException] with code `no-account` when
  /// no Bluejay account uses this provider account.
  static Future<fire_auth.UserCredential?> signIn(
    FederatedProvider provider,
  ) async {
    _checkAvailable(provider);
    try {
      return kIsWeb
          ? await _auth.signInWithPopup(provider._authProvider())
          : await _auth.signInWithProvider(provider._authProvider());
    } on fire_auth.FirebaseAuthMultiFactorException {
      rethrow;
    } on fire_auth.FirebaseAuthException catch (e) {
      if (_cancelled(e)) return null;
      // Signing in with a provider no account uses would create one, which
      // the blocking function refuses.
      if (_refusedSignup(e)) {
        throw FederatedSignInException(
          'No Bluejay account uses this ${provider.label} account yet. Create '
          'an account and choose "Continue with ${provider.label}", or sign '
          'in with your username and connect ${provider.label} from your '
          'profile.',
          code: 'no-account',
        );
      }
      throw _friendly(e, provider);
    }
  }

  /// Links [provider] to a guest session (started here if needed) for
  /// signup, and returns the email it shared. Null when the person closed
  /// the window. [discardSignup] undoes it.
  static Future<String?> startSignup(FederatedProvider provider) async {
    _checkAvailable(provider);
    var user = _auth.currentUser;
    if (user != null && !user.isAnonymous) {
      throw const FederatedSignInException(
        'You\'re already signed in. Sign out first to create a new account.',
      );
    }
    user ??= (await _auth.signInAnonymously()).user!;
    try {
      final credential = kIsWeb
          ? await user.linkWithPopup(provider._authProvider())
          : await user.linkWithProvider(provider._authProvider());
      final linked = credential.user ?? _auth.currentUser;
      return providerEmail(linked, provider) ?? linked?.email;
    } on fire_auth.FirebaseAuthException catch (e) {
      if (_cancelled(e)) return null;
      throw _friendly(e, provider);
    }
  }

  /// Deletes the account [startSignup] began, when the person leaves
  /// before choosing a username, and signs out. Best-effort: the daily
  /// signupCleanupUnfinishedAccounts sweep removes any left behind.
  static Future<void> discardSignup() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final started = user.isAnonymous ||
        (!hasPassword(user) &&
            linkedProviders(user).isNotEmpty &&
            !(user.email ?? '').endsWith('@bluejay.gg'));
    if (!started) return;
    try {
      await user.delete();
    } catch (_) {
      // The sweep removes it.
    }
    await _auth.signOut();
  }

  /// Links [provider] to the signed-in account. Returns false when the
  /// person closed the window.
  static Future<bool> link(FederatedProvider provider) async {
    _checkAvailable(provider);
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      if (kIsWeb) {
        await user.linkWithPopup(provider._authProvider());
      } else {
        await user.linkWithProvider(provider._authProvider());
      }
      await user.reload();
      return true;
    } on fire_auth.FirebaseAuthException catch (e) {
      if (_cancelled(e)) return false;
      throw _friendly(e, provider);
    }
  }

  /// Unlinks [provider] from the signed-in account, unless it's the only
  /// way left to sign in.
  static Future<void> unlink(FederatedProvider provider) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final others = linkedProviders(user).where((p) => p != provider);
    if (!hasPassword(user) && others.isEmpty) {
      throw FederatedSignInException(
        '${provider.label} is the only way you sign in. Set a password first '
        '(use "Forgot password?" on the sign-in screen) and then disconnect it.',
        code: 'last-method',
      );
    }
    try {
      await user.unlink(provider.id);
      await user.reload();
    } on fire_auth.FirebaseAuthException catch (e) {
      throw _friendly(e, provider);
    }
  }

  static bool _cancelled(fire_auth.FirebaseAuthException e) =>
      e.code == 'popup-closed-by-user' ||
      e.code == 'cancelled-popup-request' ||
      e.code == 'web-context-canceled' ||
      e.code == 'canceled';

  static bool _refusedSignup(fire_auth.FirebaseAuthException e) {
    final text = '${e.code} ${e.message ?? ''}';
    return text.contains('BLOCKING_FUNCTION') ||
        text.contains('can\'t be created here') ||
        text.contains('admin-restricted-operation');
  }

  static FederatedSignInException _friendly(
    fire_auth.FirebaseAuthException e,
    FederatedProvider provider,
  ) {
    switch (e.code) {
      case 'credential-already-in-use':
      case 'email-already-in-use':
      case 'account-exists-with-different-credential':
        return FederatedSignInException(
          'That ${provider.label} account is already connected to a Bluejay '
          'account. Sign in with it instead.',
          code: 'already-linked',
        );
      case 'provider-already-linked':
        return FederatedSignInException(
          '${provider.label} is already connected to your account.',
          code: 'already-linked',
        );
      case 'requires-recent-login':
        return const FederatedSignInException(
          'For your security, sign out and sign in again, then try this '
          'again.',
          code: 'recent-login',
        );
      case 'operation-not-allowed':
        return FederatedSignInException(
          'Signing in with ${provider.label} isn\'t available yet.',
          code: e.code,
        );
      case 'popup-blocked':
        return const FederatedSignInException(
          'Your browser blocked the sign-in window. Allow pop-ups for this '
          'site and try again.',
          code: 'popup-blocked',
        );
      case 'unauthorized-domain':
        return FederatedSignInException(
          'Signing in with ${provider.label} isn\'t available on this '
          'address yet.',
          code: e.code,
        );
    }
    return FederatedSignInException(
      e.message ?? 'Signing in with ${provider.label} didn\'t work. Try again.',
      code: e.code,
    );
  }
}
