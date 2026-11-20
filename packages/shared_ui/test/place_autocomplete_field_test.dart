import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/places/google_places_client.dart';
import 'package:shared_ui/place_autocomplete_field.dart';

const _storys = PlaceDetails(
  placeId: 'ChIJstorys',
  name: 'Storys Building',
  formattedAddress: '11 Duncan St, Toronto, ON M5V 3M2, Canada',
  latitude: 43.6479,
  longitude: -79.3895,
);

class _FakeClient extends GooglePlacesClient {
  _FakeClient({this.fail = false});

  final bool fail;
  final List<String> queries = [];

  @override
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    PlaceSearchKind kind = PlaceSearchKind.anyPlace,
    List<String> countryCodes = const [],
  }) async {
    queries.add(input);
    if (fail) throw const PlacesUnavailableException('down');
    return const [
      PlaceSuggestion(
        placeId: 'ChIJstorys',
        description: 'Storys Building, Duncan Street, Toronto',
        mainText: 'Storys Building',
        secondaryText: 'Duncan Street, Toronto',
      ),
    ];
  }

  @override
  Future<PlaceDetails?> details(String placeId, {required String sessionToken}) async => _storys;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('picking a suggestion fills the field and shows the address block', (tester) async {
    final client = _FakeClient();
    final changes = <(String, PlaceDetails?)>[];
    await tester.pumpWidget(_host(PlaceAutocompleteField(
      client: client,
      onChanged: (text, place) => changes.add((text, place)),
    )));

    await tester.enterText(find.byType(TextField), 'sto');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(client.queries, ['sto']);
    expect(find.text('Duncan Street, Toronto'), findsOneWidget);

    await tester.tap(find.text('Storys Building'));
    await tester.pumpAndSettle();

    expect(changes.last.$1, 'Storys Building');
    expect(changes.last.$2, _storys);
    expect(find.text('11 Duncan St, Toronto, ON M5V 3M2, Canada'), findsOneWidget);
    expect(find.text('Open in Google Maps'), findsOneWidget);

    // Editing the text afterwards drops the pick.
    await tester.enterText(find.byType(TextField), 'Storys Building rooftop');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(changes.last, ('Storys Building rooftop', null));
    expect(find.text('Open in Google Maps'), findsNothing);
  });

  testWidgets('shows a saved place and keeps free text when lookup fails', (tester) async {
    final changes = <(String, PlaceDetails?)>[];
    await tester.pumpWidget(_host(PlaceAutocompleteField(
      client: _FakeClient(fail: true),
      initialPlace: _storys,
      onChanged: (text, place) => changes.add((text, place)),
    )));
    expect(find.widgetWithText(TextField, 'Storys Building'), findsOneWidget);
    expect(find.text('11 Duncan St, Toronto, ON M5V 3M2, Canada'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Boardroom 4');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(changes.last, ('Boardroom 4', null));
    expect(find.textContaining('saved as written'), findsOneWidget);
  });

  testWidgets('the clear button empties the field and the pick', (tester) async {
    final changes = <(String, PlaceDetails?)>[];
    await tester.pumpWidget(_host(PlaceAutocompleteField(
      client: _FakeClient(),
      initialPlace: _storys,
      onChanged: (text, place) => changes.add((text, place)),
    )));
    await tester.tap(find.byTooltip('Clear location'));
    await tester.pump();
    expect(changes.last, ('', null));
    expect(find.text('Open in Google Maps'), findsNothing);
  });
}
