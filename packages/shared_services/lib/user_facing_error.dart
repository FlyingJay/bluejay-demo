/// Turns any caught error into a sentence a user can read.
///
/// A caught exception's `toString()` is developer text
/// (`[firebase_functions/failed-precondition] ...`, `PlatformException(...)`)
/// and reads as a crash in a snack bar or an error state. Show
/// [userFacingError] instead:
///
/// ```dart
/// } catch (e) {
///   BjSnack.error(context, userFacingError(e, fallback: "Couldn't save the form."));
/// }
/// ```
///
/// scripts/ci/user_facing_errors.test.js fails CI when new code puts a caught
/// exception's text into a snack bar, a Text or an error message.
library;

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart' show FirebaseFunctionsException;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;

/// What [userFacingError] says when nothing better is known.
const String kUserFacingErrorFallback = 'Something went wrong. Please try again.';

const String _offline = "Couldn't reach Bluejay. Check your connection and try again.";
const String _noPermission = "You don't have permission to do that.";
const String _gone = 'That item is no longer available.';
const String _busy = 'Too many attempts. Wait a moment and try again.';
const String _signIn = 'Sign in again to continue.';

/// An exception whose [userMessage] was written for the user. Throw one from
/// a service when the reason is something the user can act on;
/// [userFacingError] shows [userMessage] as is.
abstract interface class UserFacingException implements Exception {
  String get userMessage;
}

/// A plain sentence for [error], never its raw text.
///
/// - A [UserFacingException]: its [UserFacingException.userMessage].
/// - A callable's refusal ([FirebaseFunctionsException]): the server's own
///   message, which Bluejay's functions write for the user, for deliberate
///   refusals (`failed-precondition`, `not-found`, `permission-denied`, ...).
///   For a crash or an outage (`internal`, `unknown`, `unavailable`, ...) the
///   server's text is the SDK's, so a plain line by code or [fallback].
/// - Any other [FirebaseException] (Firestore, Storage, Auth): a plain line
///   for the codes users hit, else [fallback].
/// - A [TimeoutException]: the connection line.
/// - Anything else: [fallback], which the caller words for what failed
///   ("Couldn't send the photo.").
String userFacingError(Object? error, {String fallback = kUserFacingErrorFallback}) {
  if (error is UserFacingException) {
    final message = error.userMessage.trim();
    return message.isEmpty ? fallback : message;
  }
  if (error is FirebaseFunctionsException) return _callableMessage(error, fallback);
  if (error is FirebaseException) return _firebaseMessage(error.code, fallback);
  if (error is TimeoutException) return _offline;
  return fallback;
}

/// The server's `details.reason` on a callable refusal (e.g.
/// `already-signed`), or null.
String? userFacingErrorReason(Object? error) {
  if (error is! FirebaseFunctionsException) return null;
  final details = error.details;
  final reason = details is Map ? details['reason'] : null;
  return reason is String && reason.isNotEmpty ? reason : null;
}

/// Codes whose message a Bluejay function wrote on purpose.
const Set<String> _authoredCodes = {
  'invalid-argument',
  'failed-precondition',
  'not-found',
  'already-exists',
  'permission-denied',
  'resource-exhausted',
  'out-of-range',
  'unauthenticated',
  'aborted',
};

String _callableMessage(FirebaseFunctionsException error, String fallback) {
  final message = _clean(error.message);
  if (_authoredCodes.contains(error.code) && message != null && !_looksLikeCode(message)) {
    return message;
  }
  return _firebaseMessage(error.code, fallback);
}

String _firebaseMessage(String code, String fallback) => switch (code) {
      'unavailable' || 'deadline-exceeded' || 'network-request-failed' || 'retry-limit-exceeded' => _offline,
      'permission-denied' || 'unauthorized' => _noPermission,
      'not-found' || 'object-not-found' => _gone,
      'resource-exhausted' || 'too-many-requests' || 'quota-exceeded' => _busy,
      'unauthenticated' || 'unauthenticated-user' || 'user-token-expired' || 'requires-recent-login' => _signIn,
      'cancelled' || 'canceled' => 'Cancelled.',
      _ => fallback,
    };

/// [message] trimmed, without a leading `[plugin/code]` tag; null when empty.
String? _clean(String? message) {
  final trimmed = (message ?? '').replaceFirst(RegExp(r'^\[[^\]]*\]\s*'), '').trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Whether [message] is a bare code (`INTERNAL`, `failed-precondition`), as
/// the SDK sends for a crash, rather than a sentence.
bool _looksLikeCode(String message) => !message.trim().contains(' ');
