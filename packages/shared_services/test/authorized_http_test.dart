import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_services/authorized_http.dart';

void main() {
  final uri = Uri.parse('https://proxy.test/fn?x=1');

  test('sends the ID token as a Bearer header', () async {
    final seen = <String?>[];
    final client = AuthorizedHttp(
      idToken: ({bool forceRefresh = false}) async => 'tok',
      client: MockClient((request) async {
        seen.add(request.headers['Authorization']);
        return http.Response('ok', 200);
      }),
    );
    final response = await client.get(uri);
    expect(response.statusCode, 200);
    expect(seen, ['Bearer tok']);
  });

  test('on 401 refreshes the token once and retries', () async {
    final refreshes = <bool>[];
    final seen = <String?>[];
    final client = AuthorizedHttp(
      idToken: ({bool forceRefresh = false}) async {
        refreshes.add(forceRefresh);
        return forceRefresh ? 'fresh' : 'stale';
      },
      client: MockClient((request) async {
        final auth = request.headers['Authorization'];
        seen.add(auth);
        return http.Response('', auth == 'Bearer fresh' ? 200 : 401);
      }),
    );
    final response = await client.get(uri);
    expect(response.statusCode, 200);
    expect(refreshes, [false, true]);
    expect(seen, ['Bearer stale', 'Bearer fresh']);
  });

  test('a second 401 is returned, not retried forever', () async {
    var calls = 0;
    final client = AuthorizedHttp(
      idToken: ({bool forceRefresh = false}) async => 'tok',
      client: MockClient((_) async {
        calls++;
        return http.Response('', 401);
      }),
    );
    expect((await client.get(uri)).statusCode, 401);
    expect(calls, 2);
  });

  test('signed out: no header, no retry; 429 is passed through', () async {
    final seen = <String?>[];
    var status = 401;
    final client = AuthorizedHttp(
      idToken: ({bool forceRefresh = false}) async => null,
      client: MockClient((request) async {
        seen.add(request.headers['Authorization']);
        return http.Response('', status);
      }),
    );
    expect((await client.get(uri)).statusCode, 401);
    expect(seen, [null]);
    status = 429;
    expect((await client.get(uri)).statusCode, 429);
  });

  test('postJson sends a JSON body and retries a 401 with a fresh token', () async {
    final seen = <(String?, String?, String)>[];
    final client = AuthorizedHttp(
      idToken: ({bool forceRefresh = false}) async => forceRefresh ? 'fresh' : 'stale',
      client: MockClient((request) async {
        final auth = request.headers['Authorization'];
        seen.add((auth, request.headers['Content-Type'], request.body));
        return http.Response('', auth == 'Bearer fresh' ? 200 : 401);
      }),
    );
    final response = await client.postJson(uri, {'folder': 'INBOX'});
    expect(response.statusCode, 200);
    expect(seen.map((s) => s.$1), ['Bearer stale', 'Bearer fresh']);
    expect(seen.first.$2, startsWith('application/json'));
    expect(jsonDecode(seen.last.$3), {'folder': 'INBOX'});
  });

  test('userMessage covers the gate statuses only', () {
    expect(AuthorizedHttp.userMessage(401), contains('Sign in'));
    expect(AuthorizedHttp.userMessage(429), contains('Too many'));
    expect(AuthorizedHttp.userMessage(500), isNull);
  });
}
