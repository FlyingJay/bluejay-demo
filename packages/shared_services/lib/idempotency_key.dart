import 'package:uuid/uuid.dart';

import 'session_storage.dart';

/// A fresh, random idempotency key for one user action sent to a callable
/// (e.g. a ticket status change), so a retried call can't apply twice.
///
/// Generated locally: no Firestore reference (the old
/// `collection('_').doc().id` idiom) is needed just to mint a random id.
String newIdempotencyKey() => const Uuid().v4();

const _sessionPrefix = 'bluejay.idempotency.';

/// The idempotency key for one attempt at [attempt] (a string naming the
/// action and what it was asked to do), kept in session storage so a page
/// reload after a lost response sends the same key again and the server
/// returns what the first call made. Call [clearSessionIdempotencyKey] once
/// the action has succeeded, so the next attempt gets a new key.
String sessionIdempotencyKey(String attempt) {
  final storageKey = '$_sessionPrefix$attempt';
  final existing = readSessionValue(storageKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final key = newIdempotencyKey();
  writeSessionValue(storageKey, key);
  return key;
}

/// Forgets [attempt]'s key (see [sessionIdempotencyKey]).
void clearSessionIdempotencyKey(String attempt) =>
    removeSessionValue('$_sessionPrefix$attempt');
