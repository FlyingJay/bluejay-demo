import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'src/browser_reload_stub.dart' if (dart.library.html) 'src/browser_reload_web.dart';

/// Firestore settings that turn on the IndexedDB cache on web, shared across
/// open tabs; null off web.
///
/// Native builds persist by default; web defaults to a memory-only cache,
/// which refetches the launcher's apps, groups, user doc and access index
/// from the server on every page load. With the cache on, listeners emit
/// the last-known data immediately and the server copy follows.
///
/// Pass to `installFirestorePlatformMetering(settings:)`, which applies them
/// before anything starts the web Firestore instance (settings given after
/// that are ignored).
Settings? get firestoreWebCacheSettings => kIsWeb
    ? const Settings(
        persistenceEnabled: true,
        webPersistentTabManager: WebPersistentMultipleTabManager(),
      )
    : null;

/// Removes the signed-out user's cached Firestore data from the browser so
/// the next person on a shared computer can't read it, then reloads the tab
/// (a terminated Firestore instance can't be reused). No-op off web.
///
/// Clearing fails while another tab still holds the cache; the data then
/// stays until that tab signs out too, and the reload still happens.
Future<void> clearFirestoreWebCacheAndReload() async {
  if (!kIsWeb) return;
  try {
    await FirebaseFirestore.instance.terminate();
    await FirebaseFirestore.instance.clearPersistence();
  } catch (e) {
    debugPrint('[FirestoreWebCache] clearPersistence failed: $e');
  }
  reloadBrowserTab();
}
