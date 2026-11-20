/// A place picked from Google Places, in the shape apps persist to Firestore.
///
/// Stored as a nested map (see [toMap]) next to whatever display string the
/// app already keeps, so a document without one still reads cleanly.
class PlaceDetails {
  /// Google's stable identifier. Empty only for hand-built instances.
  final String placeId;

  /// The business or venue name ("Storys Building"), or the street address
  /// when the place is an address rather than an establishment.
  final String name;
  final String formattedAddress;
  final double? latitude;
  final double? longitude;

  final String streetNumber;
  final String route;
  final String unit;
  final String neighbourhood;
  final String city;
  final String region;
  final String regionCode;
  final String postalCode;
  final String country;
  final String countryCode;

  /// Google's own Maps link for the place, when the API returned one.
  final String googleMapsUrl;
  final List<String> types;

  const PlaceDetails({
    required this.placeId,
    required this.name,
    required this.formattedAddress,
    this.latitude,
    this.longitude,
    this.streetNumber = '',
    this.route = '',
    this.unit = '',
    this.neighbourhood = '',
    this.city = '',
    this.region = '',
    this.regionCode = '',
    this.postalCode = '',
    this.country = '',
    this.countryCode = '',
    this.googleMapsUrl = '',
    this.types = const [],
  });

  bool get hasCoordinates => latitude != null && longitude != null;

  String get streetAddress {
    final street = '$streetNumber $route'.trim();
    return unit.isEmpty || street.isEmpty ? street : '$unit - $street';
  }

  /// True when [name] adds something beyond the address (a venue or
  /// business), so UIs can show it as a heading above the address.
  bool get hasDistinctName {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return false;
    final address = formattedAddress.trim().toLowerCase();
    return !address.startsWith(n) && n != streetAddress.toLowerCase();
  }

  /// "Storys Building, 11 Duncan St, Toronto, ON M5V 3M2, Canada" for
  /// venues; just the address otherwise.
  String get displayLabel {
    if (!hasDistinctName) return formattedAddress.isNotEmpty ? formattedAddress : name;
    return formattedAddress.isEmpty ? name : '$name, $formattedAddress';
  }

  /// A Maps link that opens this exact place on any platform.
  Uri get mapsUri {
    if (googleMapsUrl.isNotEmpty) {
      final parsed = Uri.tryParse(googleMapsUrl);
      if (parsed != null && parsed.scheme == 'https') return parsed;
    }
    return mapsSearchUri(displayLabel, placeId: placeId);
  }

  /// Maps search link for [query], pinned to [placeId] when known.
  static Uri mapsSearchUri(String query, {String placeId = ''}) {
    return Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': query,
      if (placeId.isNotEmpty) 'query_place_id': placeId,
    });
  }

  Map<String, dynamic> toMap() => {
        'placeId': placeId,
        'name': name,
        'formattedAddress': formattedAddress,
        'latitude': latitude,
        'longitude': longitude,
        'streetNumber': streetNumber,
        'route': route,
        'unit': unit,
        'neighbourhood': neighbourhood,
        'city': city,
        'region': region,
        'regionCode': regionCode,
        'postalCode': postalCode,
        'country': country,
        'countryCode': countryCode,
        'googleMapsUrl': googleMapsUrl,
        'types': types,
        'source': 'google_places',
      };

  /// Null when [raw] isn't a map or carries no usable address.
  static PlaceDetails? fromMap(Object? raw) {
    if (raw is! Map) return null;
    String read(String key) => raw[key] is String ? (raw[key] as String).trim() : '';
    double? readDouble(String key) {
      final value = raw[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final place = PlaceDetails(
      placeId: read('placeId'),
      name: read('name'),
      formattedAddress: read('formattedAddress'),
      latitude: readDouble('latitude'),
      longitude: readDouble('longitude'),
      streetNumber: read('streetNumber'),
      route: read('route'),
      unit: read('unit'),
      neighbourhood: read('neighbourhood'),
      city: read('city'),
      region: read('region'),
      regionCode: read('regionCode'),
      postalCode: read('postalCode'),
      country: read('country'),
      countryCode: read('countryCode'),
      googleMapsUrl: read('googleMapsUrl'),
      types: raw['types'] is List
          ? (raw['types'] as List).whereType<String>().toList()
          : const [],
    );
    return place.formattedAddress.isEmpty && place.name.isEmpty ? null : place;
  }

  /// Parses a legacy Places API `details` result.
  static PlaceDetails fromPlacesResult(Map<String, dynamic> result) {
    final values = <String, (String, String)>{};
    for (final component in (result['address_components'] as List? ?? const [])) {
      if (component is! Map) continue;
      final longName = component['long_name']?.toString() ?? '';
      final shortName = component['short_name']?.toString() ?? '';
      for (final type in (component['types'] as List? ?? const [])) {
        values.putIfAbsent(type.toString(), () => (longName, shortName));
      }
    }
    String long(String type) => values[type]?.$1 ?? '';
    String short(String type) => values[type]?.$2 ?? '';

    final location = (result['geometry'] as Map?)?['location'] as Map?;
    double? coordinate(String key) {
      final value = location?[key];
      return value is num ? value.toDouble() : null;
    }

    final city = [long('locality'), long('postal_town'), long('administrative_area_level_3'), long('sublocality')]
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    return PlaceDetails(
      placeId: result['place_id']?.toString() ?? '',
      name: result['name']?.toString() ?? '',
      formattedAddress: result['formatted_address']?.toString() ?? '',
      latitude: coordinate('lat'),
      longitude: coordinate('lng'),
      streetNumber: long('street_number'),
      route: long('route'),
      unit: long('subpremise'),
      neighbourhood: long('neighborhood'),
      city: city,
      region: long('administrative_area_level_1'),
      regionCode: short('administrative_area_level_1'),
      postalCode: long('postal_code'),
      country: long('country'),
      countryCode: short('country'),
      googleMapsUrl: result['url']?.toString() ?? '',
      types: (result['types'] as List? ?? const []).map((t) => t.toString()).toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaceDetails && other.placeId == placeId && other.formattedAddress == formattedAddress && other.name == name;

  @override
  int get hashCode => Object.hash(placeId, formattedAddress, name);
}

/// One row in the autocomplete dropdown.
class PlaceSuggestion {
  final String placeId;
  final String description;

  /// "Storys Building" / "11 Duncan Street" …
  final String mainText;

  /// … "Duncan Street, Toronto, ON, Canada".
  final String secondaryText;

  const PlaceSuggestion({
    required this.placeId,
    required this.description,
    this.mainText = '',
    this.secondaryText = '',
  });

  static PlaceSuggestion? fromPrediction(Object? raw) {
    if (raw is! Map) return null;
    final placeId = raw['place_id']?.toString() ?? '';
    final description = raw['description']?.toString() ?? '';
    if (placeId.isEmpty || description.isEmpty) return null;
    final formatting = raw['structured_formatting'];
    return PlaceSuggestion(
      placeId: placeId,
      description: description,
      mainText: formatting is Map ? formatting['main_text']?.toString() ?? '' : '',
      secondaryText: formatting is Map ? formatting['secondary_text']?.toString() ?? '' : '',
    );
  }
}
