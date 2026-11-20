import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// Returns the signed-in user's Firebase ID token, or null when nobody is
/// signed in. [forceRefresh] mints a fresh one.
typedef IdTokenProvider = Future<String?> Function({bool forceRefresh});

/// HTTP calls to our own `onRequest` Cloud Functions that require a
/// verified caller (functions/_http_auth.js `guardProxyRequest`): attaches
/// `Authorization: Bearer <Firebase ID token>`, and on a 401 refreshes the
/// token once and retries (an ID token lasts an hour; the cached one may
/// have just expired). Anonymous guests have ID tokens too.
///
/// Callers get the final response and decide what to show; [userMessage]
/// has the standard wording for the statuses the gate produces.
class AuthorizedHttp {
  AuthorizedHttp({http.Client? client, IdTokenProvider? idToken})
      : _client = client ?? http.Client(),
        _idToken = idToken ?? currentUserIdToken;

  final http.Client _client;
  final IdTokenProvider _idToken;

  /// The current Firebase user's ID token (cached by the SDK, refreshed
  /// when close to expiry), or null when signed out.
  static Future<String?> currentUserIdToken({bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    return user.getIdToken(forceRefresh);
  }

  /// GET [uri] with the caller's ID token.
  Future<http.Response> get(Uri uri, {Duration timeout = const Duration(seconds: 15)}) {
    return _withToken((headers) => _client.get(uri, headers: headers).timeout(timeout));
  }

  /// POST [body] as JSON to [uri] with the caller's ID token.
  Future<http.Response> postJson(
    Uri uri,
    Object? body, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final encoded = jsonEncode(body);
    return _withToken((headers) => _client
        .post(uri, headers: {...headers, 'Content-Type': 'application/json'}, body: encoded)
        .timeout(timeout));
  }

  /// Sends with the current token; on a 401 refreshes it once and resends.
  Future<http.Response> _withToken(
    Future<http.Response> Function(Map<String, String> headers) send,
  ) async {
    var token = await _idToken(forceRefresh: false);
    var response = await send(_authHeaders(token));
    if (response.statusCode == 401 && token != null) {
      token = await _idToken(forceRefresh: true);
      if (token != null) response = await send(_authHeaders(token));
    }
    return response;
  }

  static Map<String, String> _authHeaders(String? token) => {
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  /// A short, user-facing explanation for a gate refusal, or null for
  /// statuses the gate doesn't produce.
  static String? userMessage(int statusCode) => switch (statusCode) {
        401 => 'Your session has expired. Sign in again to continue.',
        403 => 'This request isn\'t allowed from here.',
        429 => 'Too many requests right now. Wait a minute and try again.',
        _ => null,
      };
}
