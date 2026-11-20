import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/ai_service.dart';
import 'package:shared_services/user_facing_error.dart';

class _Friendly implements UserFacingException {
  const _Friendly(this.userMessage);
  @override
  final String userMessage;
}

FirebaseFunctionsException callable(String code, String? message, [Object? details]) =>
    FirebaseFunctionsException(code: code, message: message ?? '', details: details);

void main() {
  test("an AI client failure shows its own message", () {
    expect(userFacingError(const AiException.noGroup()), 'Select a group to use AI features.');
    expect(userFacingError(const AiException.incomplete()), "The AI reply didn't finish. Please try again.");
  });

  test("a callable's deliberate refusal shows the server's message", () {
    expect(
      userFacingError(callable('failed-precondition', 'You already signed this document.')),
      'You already signed this document.',
    );
    expect(userFacingError(callable('not-found', 'This secure signing link is invalid.')),
        'This secure signing link is invalid.');
  });

  test('a crash or outage never shows the SDK text', () {
    expect(userFacingError(callable('internal', 'INTERNAL'), fallback: "Couldn't sign."), "Couldn't sign.");
    expect(userFacingError(callable('internal', 'Cannot read properties of undefined (reading x)'), fallback: 'F'),
        'F');
    expect(userFacingError(callable('unavailable', 'UNAVAILABLE')), contains('connection'));
    expect(userFacingError(callable('failed-precondition', 'FAILED_PRECONDITION'), fallback: 'F'), 'F');
    expect(userFacingError(callable('permission-denied', '')), "You don't have permission to do that.");
  });

  test('other Firebase errors map by code', () {
    expect(userFacingError(FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied', message: 'x y')),
        "You don't have permission to do that.");
    expect(userFacingError(FirebaseException(plugin: 'firebase_storage', code: 'unauthorized')),
        "You don't have permission to do that.");
    expect(userFacingError(FirebaseException(plugin: 'cloud_firestore', code: 'unavailable')), contains('connection'));
    expect(userFacingError(FirebaseException(plugin: 'cloud_firestore', code: 'aborted', message: 'raw sdk text'),
        fallback: 'F'), 'F');
  });

  test('anything else gets the fallback, never its toString', () {
    expect(userFacingError(Exception('boom'), fallback: "Couldn't load."), "Couldn't load.");
    expect(userFacingError(StateError('bad')), kUserFacingErrorFallback);
    expect(userFacingError(null), kUserFacingErrorFallback);
    expect(userFacingError(TimeoutException('slow')), contains('connection'));
    expect(userFacingError(const _Friendly('Pick a smaller photo.')), 'Pick a smaller photo.');
  });

  test('userFacingErrorReason reads details.reason', () {
    expect(userFacingErrorReason(callable('failed-precondition', 'x y', {'reason': 'already-signed'})), 'already-signed');
    expect(userFacingErrorReason(callable('failed-precondition', 'x y')), isNull);
    expect(userFacingErrorReason(Exception('x')), isNull);
  });
}
