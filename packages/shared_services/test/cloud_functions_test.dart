import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/cloud_functions.dart';
import 'package:shared_services/places/google_places_client.dart';

/// Every callable and `onRequest` URL goes to northamerica-northeast2, the
/// region `functions/_function_regions.js` names as CLIENT_REGION.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  const toronto = 'https://northamerica-northeast2-bluejay-d926f.cloudfunctions.net';

  test('callables go to northamerica-northeast2', () {
    expect(kFunctionsRegion, 'northamerica-northeast2');
    // The plugin caches one instance per (app, region), so identical()
    // means same region and same client.
    expect(
      identical(BluejayFunctions.instance, FirebaseFunctions.instanceFor(region: 'northamerica-northeast2')),
      isTrue,
    );
    expect(identical(BluejayFunctions.instance, FirebaseFunctions.instance), isFalse,
        reason: 'FirebaseFunctions.instance is us-central1');
  });

  test('inRegion keeps the warehouse row-data callables in their data region', () {
    expect(identical(BluejayFunctions.inRegion(null), BluejayFunctions.instance), isTrue);
    expect(
      identical(
        BluejayFunctions.inRegion('northamerica-northeast2'),
        FirebaseFunctions.instanceFor(region: 'northamerica-northeast2'),
      ),
      isTrue,
    );
  });

  test('onRequest function URLs point at northamerica-northeast2', () {
    expect(kFunctionsBaseUrl, toronto);
    for (final name in [
      'getGroupBranding',
      'updateUserEmailDomain',
      'sendPasswordReset',
      'systemReportsRunReport',
      'reportsGenerateReport',
      'winnipegPropertyProxy',
      'googlePlacesProxy',
    ]) {
      expect(BluejayFunctions.functionUrl(name), '$toronto/$name');
      expect('$kFunctionsBaseUrl/$name', '$toronto/$name');
    }
    expect(GooglePlacesClient.defaultProxyUrl, '$toronto/googlePlacesProxy');
    expect(
      BluejayFunctions.functionUri('storageDownloadFile', query: {'fileId': 'a b'}),
      Uri.https('northamerica-northeast2-bluejay-d926f.cloudfunctions.net', 'storageDownloadFile', {'fileId': 'a b'}),
    );
    expect(BluejayFunctions.functionUrl('fn', path: 'x/y'), '$toronto/fn/x/y');
  });

  test('publicUri is region-free', () {
    expect(BluejayFunctions.publicUri('/rsvp', {'t': '1'}).toString(), 'https://bluejay.gg/rsvp?t=1');
    expect(BluejayFunctions.publicUri('calendar/ics', {'eventId': 'e'}).toString(),
        'https://bluejay.gg/calendar/ics?eventId=e');
    expect(BluejayFunctions.publicUri('files/download').toString(), 'https://bluejay.gg/files/download');
  });

  group('publicLinkHostFor', () {
    test('production builds link to bluejay.gg', () {
      expect(publicLinkHostFor(previewBuild: false, page: Uri.parse('https://bluejay.gg/sunnyside')), 'bluejay.gg');
      expect(publicLinkHostFor(previewBuild: false), 'bluejay.gg');
      expect(publicLinkHost, kPublicHost);
    });

    test('a preview build links to the preview it is running on', () {
      expect(
        publicLinkHostFor(previewBuild: true, page: Uri.parse('https://bluejay-preview-sandbox--pr-12-abc.web.app/sunnyside')),
        'bluejay-preview-sandbox--pr-12-abc.web.app',
      );
    });

    test('a preview without a usable page URL falls back to bluejay.gg', () {
      expect(publicLinkHostFor(previewBuild: true), 'bluejay.gg');
      expect(publicLinkHostFor(previewBuild: true, page: Uri.parse('http://localhost:8080/')), 'bluejay.gg');
    });
  });
}
