import 'package:shared_services/cloud_functions.dart';

/// Calls a Cloud Functions callable by name (tests pass a fake).
typedef CallableInvoker = Future<void> Function(
    String name, Map<String, dynamic> data);

/// A user's platform-wide account status: ACTIVE, INACTIVE or SUSPENDED.
///
/// The single source of truth is the user's `platformStatus` Auth custom
/// claim, which only the `adminSetUserStatus` callable (platform admins)
/// can change (functions/role_manager.js, functions/_platform_access.js).
/// Deactivating an account also disables its Firebase Auth sign-in, sets
/// `status` in its access index (so the rules and every server check deny
/// it), and makes the app shell show the "account inactive"
/// screen. `users/{uid}.status` is a display mirror the server keeps in
/// sync; nothing reads it for authorization.
///
/// This replaces the retired `users/{uid}.isBanned` flag, which the Users
/// app wrote directly and nothing enforced.
class AccountStatusService {
  AccountStatusService({CallableInvoker? invoke})
      : _invoke = invoke ?? _callFunction;

  /// The one server-side switch (functions/role_manager.js).
  static const String setStatusCallable = 'adminSetUserStatus';

  static const String active = 'ACTIVE';
  static const String inactive = 'INACTIVE';
  static const String suspended = 'SUSPENDED';

  final CallableInvoker _invoke;

  static Future<void> _callFunction(
      String name, Map<String, dynamic> data) async {
    await BluejayFunctions.instance.httpsCallable(name).call(data);
  }

  /// Activates or deactivates [targetUid] platform-wide. Platform admins
  /// only; the server refuses anyone else and changes to your own account.
  Future<void> setActive(String targetUid, {required bool isActive}) =>
      setStatus(targetUid, isActive ? active : inactive);

  /// Sets [targetUid]'s status to [status] (ACTIVE, INACTIVE or SUSPENDED).
  Future<void> setStatus(String targetUid, String status) => _invoke(
        setStatusCallable,
        {'targetUid': targetUid, 'status': normalize(status)},
      );

  /// [value] as a status: upper-cased, ACTIVE when missing.
  static String normalize(Object? value) {
    final text = value is String ? value.trim().toUpperCase() : '';
    return text.isEmpty ? active : text;
  }

  /// Whether a `users/{uid}` document says the account is deactivated
  /// (its `status` display mirror). For labels only.
  static bool isInactiveUserData(Map<String, dynamic>? userData) =>
      normalize(userData?['status']) != active;

  /// Whether the signed-in account is deactivated, from its ID token's
  /// `platformStatus` claim and its access index document. A missing claim
  /// means ACTIVE. An access index the rebuild wrote while failing (it has
  /// an `error` field and fails closed to SUSPENDED) is a server problem,
  /// not a deactivation, so it doesn't count.
  static bool isAccountBlocked({
    Object? claimStatus,
    Map<String, dynamic>? accessIndex,
  }) {
    if (normalize(claimStatus) != active) return true;
    if (accessIndex == null || accessIndex['error'] != null) return false;
    return normalize(accessIndex['status']) != active;
  }
}
