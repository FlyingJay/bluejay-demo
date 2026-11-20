import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/app_display_names.dart';

void main() {
  setUp(AppDisplayNames.clearCache);

  test('uses the catalog name, read once per app', () async {
    var reads = 0;
    Future<Map<String, dynamic>?> read(String id) async {
      reads++;
      return {'name': 'Course of Construction'};
    }

    expect(await AppDisplayNames.of('course_of_construction', usageAppId: 'forms', read: read),
        'Course of Construction');
    expect(await AppDisplayNames.of('course_of_construction', usageAppId: 'forms', read: read),
        'Course of Construction');
    expect(reads, 1);
  });

  test('falls back to a readable id when the doc has no name or the read fails', () async {
    expect(await AppDisplayNames.of('rented_dwelling', usageAppId: 'forms', read: (_) async => null),
        'Rented dwelling');
    expect(
        await AppDisplayNames.of('time-tracking', usageAppId: 'forms', read: (_) async => throw StateError('denied')),
        'Time tracking');
    expect(await AppDisplayNames.of('  ', usageAppId: 'forms', read: (_) async => null), '');
  });
}
