import 'package:cloud_firestore/cloud_firestore.dart';

import 'metered_firestore.dart';

export 'metered_firestore.dart';

/// The appId the host app shell (the repo's top-level `lib/`) attributes its
/// own Firestore usage to.
const String launcherAppId = 'launcher';

/// The appId shared platform services (entitlements, guest accounts, …)
/// attribute usage to when no specific app asked for it. Matches
/// functions/_usage.js PLATFORM_APP_ID.
const String platformAppId = '~platform';

/// The gateway to Firestore for code that needs raw collections — personal
/// docs (`users/{uid}`), platform collections, admin tools — rather than a
/// tenant-scoped `ScopedCollection` (which already uses this internally).
///
/// ```dart
/// final db = BluejayFirestore.forApp(APP_ID);
/// await db.collection('users').doc(uid).get();
/// ```
///
/// What it returns is a drop-in [FirebaseFirestore], so existing code typed
/// against `FirebaseFirestore` keeps working. Its collections, queries,
/// listeners, batches and transactions record the reads, writes and deletes
/// Firestore bills against the app through `UsageMeter`
/// (plans/usage-meter/IMPLEMENTATION_PLAN.md, Phase 4). Cache-served reads
/// are free. DocumentReferences it hands out are the plugin's own objects,
/// attributed to the app; operations called directly on them are metered at
/// the platform layer (firestore_platform_metering.dart).
///
/// Raw `FirebaseFirestore.instance` is banned outside this gateway by
/// scripts/check_gateways.js.
class BluejayFirestore {
  BluejayFirestore._();

  static final Map<String, MeteredFirestore> _byApp = {};

  /// The metered Firestore for [appId] (the app the usage is attributed to:
  /// a package's `APP_ID`, or `launcher` for the host app shell).
  ///
  /// [firestore] overrides the underlying instance (tests, a non-default
  /// app/database); otherwise `FirebaseFirestore.instance` is resolved
  /// lazily on first use, so this is safe to call before Firebase is
  /// initialized.
  static FirebaseFirestore forApp(String appId, {FirebaseFirestore? firestore}) {
    if (firestore == null) {
      return _byApp.putIfAbsent(appId, () => MeteredFirestore(FirestoreMeteringContext(appId)));
    }
    if (firestore is MeteredFirestore) {
      // Keep its recorder; only the attribution changes.
      if (firestore.appId == appId) return firestore;
      final base = firestore;
      return MeteredFirestore(base.metering.withAppId(appId), resolve: () => base.unmetered);
    }
    return MeteredFirestore(FirestoreMeteringContext(appId), resolve: () => firestore);
  }
}
