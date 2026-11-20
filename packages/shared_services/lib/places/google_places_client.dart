import 'dart:convert';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../authorized_http.dart';
import 'place_details.dart';
import 'package:shared_services/cloud_functions.dart';

export 'place_details.dart';

/// What kinds of results autocomplete should return.
enum PlaceSearchKind {
  /// Venues, businesses and street addresses.
  anyPlace,

  /// Street addresses only.
  address,

  /// Businesses and venues only.
  establishment,

  /// Cities and regions.
  region,
}

/// Google Places lookups (autocomplete + details).
///
/// Every platform goes through the `googlePlacesProxy` Cloud Function
/// ([proxyGet]), which calls Google with a server-only key; no device holds
/// or sends a Places key. The proxy only serves signed-in users (guests
/// included) from the app's origins, rate-limited per user, so requests
/// carry the user's Firebase ID token (AuthorizedHttp). Pass one
/// [sessionToken] per search-and-pick so Google bills the pair as a single
/// session.
class GooglePlacesClient {
  /// [proxyUrl] overrides the proxy endpoint and [idToken] the ID-token
  /// source (tests).
  GooglePlacesClient({http.Client? httpClient, String? proxyUrl, IdTokenProvider? idToken})
      : _http = AuthorizedHttp(client: httpClient, idToken: idToken),
        _explicitProxyUrl = proxyUrl;

  final AuthorizedHttp _http;
  final String? _explicitProxyUrl;

  static const defaultProxyUrl = '$kFunctionsBaseUrl/googlePlacesProxy';
  static const detailsFields =
      'place_id,name,formatted_address,address_components,geometry/location,url,types';

  static Future<String>? _proxyUrl;

  /// The `googlePlacesProxy` request for Places web-service [endpoint]
  /// (`autocomplete`, `details`, `nearbysearch`, `textsearch`) with [params].
  ///
  /// The proxy adds the key server-side. `google_places_proxy_url` in Remote
  /// Config overrides the default endpoint. Send it with [proxyGet], which
  /// adds the ID token the proxy requires; scripts/check_gateways.js fails
  /// CI on direct Places calls.
  static Future<Uri> proxyUri(String endpoint, Map<String, String> params, {String? proxyUrl}) async {
    final base = proxyUrl ?? await (_proxyUrl ??= _resolveProxyUrl());
    return Uri.parse(base).replace(queryParameters: {'endpoint': endpoint, ...params});
  }

  /// GETs Places web-service [endpoint] through the proxy with the signed-in
  /// user's ID token. The one way client code reaches Google Places (the
  /// response is Google's JSON, or the gate's 401/429). Non-200s are the
  /// caller's to handle; [AuthorizedHttp.userMessage] has standard wording.
  static Future<http.Response> proxyGet(
    String endpoint,
    Map<String, String> params, {
    String? proxyUrl,
    AuthorizedHttp? client,
  }) async {
    final uri = await proxyUri(endpoint, params, proxyUrl: proxyUrl);
    return (client ?? AuthorizedHttp()).get(uri, timeout: const Duration(seconds: 12));
  }

  static Future<String> _resolveProxyUrl() async {
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      await remoteConfig.fetchAndActivate();
      final url = remoteConfig.getString('google_places_proxy_url').trim();
      return url.isEmpty ? defaultProxyUrl : url;
    } catch (e) {
      debugPrint('[GooglePlacesClient] Remote Config "google_places_proxy_url" unavailable: $e');
      return defaultProxyUrl;
    }
  }

  Future<Map<String, dynamic>?> _get(String endpoint, Map<String, String> params) async {
    final response = await proxyGet(endpoint, params, proxyUrl: _explicitProxyUrl, client: _http);
    if (response.statusCode != 200) {
      throw PlacesUnavailableException(
        switch (response.statusCode) {
          401 => 'Sign in to search places.',
          429 => 'Too many place searches right now. Wait a minute and try again.',
          _ => 'Place search failed (HTTP ${response.statusCode}).',
        },
      );
    }
    final body = json.decode(response.body);
    if (body is! Map<String, dynamic>) return null;
    final status = body['status'];
    if (status == 'OK') return body;
    if (status == 'ZERO_RESULTS') return null;
    throw PlacesUnavailableException(
      'Place search failed ($status${body['error_message'] != null ? ': ${body['error_message']}' : ''}).',
    );
  }

  static String? _typesFor(PlaceSearchKind kind) => switch (kind) {
        PlaceSearchKind.anyPlace => null,
        PlaceSearchKind.address => 'address',
        PlaceSearchKind.establishment => 'establishment',
        PlaceSearchKind.region => '(regions)',
      };

  /// Suggestions for [input]. [countryCodes] are ISO 3166-1 alpha-2 codes
  /// (at most five); empty searches worldwide.
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    PlaceSearchKind kind = PlaceSearchKind.anyPlace,
    List<String> countryCodes = const [],
  }) async {
    final query = input.trim();
    if (query.length < 2) return const [];
    final types = _typesFor(kind);
    final body = await _get('autocomplete', {
      'input': query,
      'sessiontoken': sessionToken,
      if (types != null) 'types': types,
      if (countryCodes.isNotEmpty)
        'components': countryCodes.take(5).map((c) => 'country:${c.toLowerCase()}').join('|'),
    });
    return (body?['predictions'] as List? ?? const [])
        .map(PlaceSuggestion.fromPrediction)
        .whereType<PlaceSuggestion>()
        .toList();
  }

  /// Full details for a picked suggestion; closes the billing session.
  Future<PlaceDetails?> details(String placeId, {required String sessionToken}) async {
    final body = await _get('details', {
      'place_id': placeId,
      'fields': detailsFields,
      'sessiontoken': sessionToken,
    });
    final result = body?['result'];
    return result is Map<String, dynamic> ? PlaceDetails.fromPlacesResult(result) : null;
  }
}

class PlacesUnavailableException implements Exception {
  final String message;
  const PlacesUnavailableException(this.message);

  @override
  String toString() => message;
}
