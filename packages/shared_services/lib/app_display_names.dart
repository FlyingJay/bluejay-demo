/// App display names for showing an app id to a user ("From Course of
/// Construction", never "From course_of_construction").
library;

import 'bluejay_firestore.dart';

/// Reads an app's catalog doc (`apps/{appId}`) data, or null.
typedef AppDocReader = Future<Map<String, dynamic>?> Function(String appId);

/// The catalog's `name` for an app id, read once per id and cached.
/// `apps` is a platform collection any signed-in user can read.
class AppDisplayNames {
  AppDisplayNames._();

  static final Map<String, Future<String>> _names = {};

  /// [appId]'s display name: the catalog's `name`, or [readable] when the
  /// doc has none or can't be read. [usageAppId] is the app the read is
  /// metered to; [read] replaces the catalog read (tests).
  static Future<String> of(String appId, {required String usageAppId, AppDocReader? read}) {
    final id = appId.trim();
    if (id.isEmpty) return Future.value('');
    return _names.putIfAbsent(id, () async {
      try {
        final data = await (read ?? _reader(usageAppId))(id);
        final name = data?['name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
      } catch (_) {
        // Offline or not readable: the readable id is still better than the raw one.
      }
      return readable(id);
    });
  }

  /// [appId] made readable without the catalog: `course_of_construction`
  /// becomes `Course of construction`.
  static String readable(String appId) {
    final words = appId.trim().split(RegExp(r'[_\-\s]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    final first = words.first;
    return [first[0].toUpperCase() + first.substring(1), ...words.skip(1)].join(' ');
  }

  /// Forgets the cached names (tests).
  static void clearCache() => _names.clear();

  static AppDocReader _reader(String usageAppId) => (appId) async {
        final doc = await BluejayFirestore.forApp(usageAppId).collection('apps').doc(appId).get();
        return doc.data();
      };
}
