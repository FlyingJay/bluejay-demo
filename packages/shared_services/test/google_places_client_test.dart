import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_services/places/google_places_client.dart';

Future<String?> _token({bool forceRefresh = false}) async => 'id-token';

const _storysResult = {
  'place_id': 'ChIJstorys',
  'name': 'Storys Building',
  'formatted_address': '11 Duncan St, Toronto, ON M5V 3M2, Canada',
  'url': 'https://maps.google.com/?cid=123',
  'types': ['point_of_interest', 'establishment'],
  'geometry': {
    'location': {'lat': 43.6479, 'lng': -79.3895},
  },
  'address_components': [
    {'long_name': '11', 'short_name': '11', 'types': ['street_number']},
    {'long_name': 'Duncan Street', 'short_name': 'Duncan St', 'types': ['route']},
    {'long_name': 'Old Toronto', 'short_name': 'Old Toronto', 'types': ['sublocality_level_1', 'sublocality', 'political']},
    {'long_name': 'Toronto', 'short_name': 'Toronto', 'types': ['locality', 'political']},
    {'long_name': 'Ontario', 'short_name': 'ON', 'types': ['administrative_area_level_1', 'political']},
    {'long_name': 'Canada', 'short_name': 'CA', 'types': ['country', 'political']},
    {'long_name': 'M5V 3M2', 'short_name': 'M5V 3M2', 'types': ['postal_code']},
  ],
};

void main() {
  group('PlaceDetails', () {
    test('parses a Places details result', () {
      final place = PlaceDetails.fromPlacesResult(Map<String, dynamic>.from(_storysResult));
      expect(place.placeId, 'ChIJstorys');
      expect(place.streetAddress, '11 Duncan Street');
      expect(place.city, 'Toronto');
      expect(place.region, 'Ontario');
      expect(place.regionCode, 'ON');
      expect(place.countryCode, 'CA');
      expect(place.postalCode, 'M5V 3M2');
      expect(place.latitude, 43.6479);
      expect(place.longitude, -79.3895);
      expect(place.hasDistinctName, isTrue);
      expect(place.displayLabel, 'Storys Building, 11 Duncan St, Toronto, ON M5V 3M2, Canada');
      expect(place.mapsUri.toString(), 'https://maps.google.com/?cid=123');
    });

    test('round-trips through toMap/fromMap', () {
      final place = PlaceDetails.fromPlacesResult(Map<String, dynamic>.from(_storysResult));
      final restored = PlaceDetails.fromMap(place.toMap())!;
      expect(restored, place);
      expect(restored.toMap(), place.toMap());
    });

    test('an address pick has no separate name', () {
      const place = PlaceDetails(
        placeId: 'p',
        name: '11 Duncan St',
        formattedAddress: '11 Duncan St, Toronto, ON M5V 3M2, Canada',
      );
      expect(place.hasDistinctName, isFalse);
      expect(place.displayLabel, place.formattedAddress);
    });

    test('rejects unusable maps and falls back to a search link', () {
      expect(PlaceDetails.fromMap(null), isNull);
      expect(PlaceDetails.fromMap({'placeId': 'x'}), isNull);
      final place = PlaceDetails.fromMap({
        'placeId': 'abc',
        'formattedAddress': '1 Main St',
        'latitude': 'nope',
        'googleMapsUrl': 'javascript:alert(1)',
      })!;
      expect(place.hasCoordinates, isFalse);
      final uri = place.mapsUri;
      expect(uri.host, 'www.google.com');
      expect(uri.queryParameters['query'], '1 Main St');
      expect(uri.queryParameters['query_place_id'], 'abc');
    });
  });

  group('GooglePlacesClient', () {
    test('proxyUri puts the endpoint first and never carries a key', () async {
      final uri = await GooglePlacesClient.proxyUri(
        'nearbysearch',
        {'location': '1,2', 'radius': '500'},
        proxyUrl: 'https://proxy.test/googlePlacesProxy',
      );
      expect(uri.toString(), 'https://proxy.test/googlePlacesProxy?endpoint=nearbysearch&location=1%2C2&radius=500');
    });

    test('autocomplete sends the session and filters, and parses predictions', () async {
      late Uri seen;
      String? seenAuth;
      final client = GooglePlacesClient(
        proxyUrl: 'https://proxy.test/googlePlacesProxy',
        idToken: _token,
        httpClient: MockClient((request) async {
          seen = request.url;
          seenAuth = request.headers['Authorization'];
          return http.Response(
            jsonEncode({
              'status': 'OK',
              'predictions': [
                {
                  'place_id': 'ChIJstorys',
                  'description': 'Storys Building, Duncan Street, Toronto, ON, Canada',
                  'structured_formatting': {'main_text': 'Storys Building', 'secondary_text': 'Duncan Street, Toronto'},
                },
                {'description': 'missing id'},
              ],
            }),
            200,
          );
        }),
      );
      final results = await client.autocomplete(
        'storys',
        sessionToken: 'tok',
        kind: PlaceSearchKind.establishment,
        countryCodes: const ['CA', 'US'],
      );
      // Every platform goes through the proxy; no key ever leaves the server.
      expect(seen.host, 'proxy.test');
      expect(seen.path, '/googlePlacesProxy');
      expect(seen.queryParameters['endpoint'], 'autocomplete');
      expect(seen.queryParameters['sessiontoken'], 'tok');
      expect(seen.queryParameters['types'], 'establishment');
      expect(seen.queryParameters['components'], 'country:ca|country:us');
      expect(seen.queryParameters.containsKey('key'), isFalse);
      expect(seenAuth, 'Bearer id-token');
      expect(results, hasLength(1));
      expect(results.single.mainText, 'Storys Building');
    });

    test('short input skips the request; ZERO_RESULTS is empty; errors throw', () async {
      var calls = 0;
      var status = 'ZERO_RESULTS';
      final client = GooglePlacesClient(
        proxyUrl: 'https://proxy.test/googlePlacesProxy',
        idToken: _token,
        httpClient: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode({'status': status}), 200);
        }),
      );
      expect(await client.autocomplete('a', sessionToken: 't'), isEmpty);
      expect(calls, 0);
      expect(await client.autocomplete('ab', sessionToken: 't'), isEmpty);
      status = 'REQUEST_DENIED';
      expect(client.autocomplete('ab', sessionToken: 't'), throwsA(isA<PlacesUnavailableException>()));
    });

    test('details asks for coordinates and address fields', () async {
      late Uri seen;
      final client = GooglePlacesClient(
        proxyUrl: 'https://proxy.test/googlePlacesProxy',
        idToken: _token,
        httpClient: MockClient((request) async {
          seen = request.url;
          return http.Response(jsonEncode({'status': 'OK', 'result': _storysResult}), 200);
        }),
      );
      final place = await client.details('ChIJstorys', sessionToken: 'tok');
      expect(seen.queryParameters['endpoint'], 'details');
      expect(seen.queryParameters['fields'], contains('geometry/location'));
      expect(seen.queryParameters['place_id'], 'ChIJstorys');
      expect(place?.city, 'Toronto');
    });

    test('the proxy refusing (signed out, rate limited) is a readable error', () async {
      var status = 401;
      final client = GooglePlacesClient(
        proxyUrl: 'https://proxy.test/googlePlacesProxy',
        idToken: _token,
        httpClient: MockClient((_) async => http.Response('{"error":"x"}', status)),
      );
      await expectLater(
        client.autocomplete('storys', sessionToken: 't'),
        throwsA(isA<PlacesUnavailableException>().having((e) => e.message, 'message', contains('Sign in'))),
      );
      status = 429;
      await expectLater(
        client.autocomplete('storys', sessionToken: 't'),
        throwsA(isA<PlacesUnavailableException>().having((e) => e.message, 'message', contains('Too many'))),
      );
    });
  });
}
