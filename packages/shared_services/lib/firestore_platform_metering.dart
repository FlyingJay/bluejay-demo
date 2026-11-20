// Document-level Firestore metering, installed under cloud_firestore at the
// platform layer (plans/usage-meter/IMPLEMENTATION_PLAN.md, Phase 4,
// "Document operations").
//
// metered_firestore.dart meters queries, collections, batches and
// transactions with decorators, but it can't wrap DocumentReferences:
// cloud_firestore turns a reference into a value by reading its private
// `_delegate`, so a wrapped reference crashes wherever one is used as a
// field value or filter. This file meters them one layer down instead.
// Every cloud_firestore DocumentReference, wherever it came from, holds a
// DocumentReferencePlatform created by the platform instance
// (`FirebaseFirestorePlatform.doc`/`collection().doc()`, including
// `snapshot.reference` and references decoded from data). Installing a
// platform instance whose references are *subclasses* of the plugin's own
// (MethodChannelDocumentReference / DocumentReferenceWeb, with the shared
// mixins in src/document_metering.dart) meters `get`, `snapshots`, `set`,
// `update` and `delete` on every reference with no call-site changes.
// Because the metered references are the plugin's own classes, every type
// check the codecs make (`is DocumentReferenceWeb`,
// `firestore is MethodChannelFirebaseFirestore`,
// `firestore as FirebaseFirestoreWeb`) still passes.
//
// Queries, batches and transactions are still metered by the decorators;
// they don't run through these reference methods, so nothing is counted
// twice. Attribution: see FirestoreAttribution.

import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'bluejay_firestore.dart' show platformAppId;
import 'src/document_metering.dart';
import 'src/firestore_platform_metering_native.dart'
    if (dart.library.js_interop) 'src/firestore_platform_metering_web.dart' as platform;
import 'usage_meter.dart';

export 'src/document_metering.dart' show FirestoreAttribution, unknownFirestoreAppId;

/// Usage metric recorded once when document metering couldn't be
/// installed, so the failure shows up on the Usage Meter dashboard.
const String meteringInstallFailedMetric = 'meteringInstallFailed';

bool _installed = false;
String? _failure;

/// Whether document-level metering is active.
bool get firestorePlatformMeteringInstalled => _installed;

/// Why the last install attempt failed, if it did.
String? get firestorePlatformMeteringFailure => _failure;

/// Replaces `FirebaseFirestorePlatform.instance` with its metered subclass.
///
/// Call once, right after `Firebase.initializeApp` and before any Firestore
/// use: a `FirebaseFirestore` resolves its platform instance on first use
/// and keeps it, so an instance used earlier stays unmetered. Idempotent.
///
/// A failure is loud: an error is logged (in release builds too) and a
/// one-time [meteringInstallFailedMetric] usage signal is recorded under
/// [platformAppId]. Gateway writes (`add()`, `ScopedCollection.set()`) are
/// still counted, by the gateway itself, when the platform layer isn't
/// active.
///
/// [settings] are applied to `FirebaseFirestore.instance` here, after the
/// platform swap and before the install check below first touches the
/// instance: on web, settings given after that first touch are ignored.
bool installFirestorePlatformMetering({Settings? settings}) {
  if (_installed) return true;
  String? failure;
  try {
    final base = FirebaseFirestorePlatform.instance;
    if (base is! MeteredFirestorePlatform) {
      final metered = platform.meteredPlatformFor(base);
      if (metered == null) {
        failure = 'unsupported Firestore platform ${base.runtimeType}';
      } else {
        FirebaseFirestorePlatform.instance = metered;
      }
    }
    if (settings != null) FirebaseFirestore.instance.settings = settings;
    if (failure == null && !_defaultInstanceIsMetered()) {
      failure = 'FirebaseFirestore.instance was used before metering was installed, '
          'so its references stay on the unmetered platform';
    }
  } catch (e) {
    failure = '$e';
  }
  if (failure != null) {
    _reportFailure(failure);
    return false;
  }
  _installed = true;
  _failure = null;
  return true;
}

/// Whether the default instance creates metered references: it keeps the
/// platform it resolved on first use, which predates install if Firestore
/// was touched earlier. Creating a reference makes no request.
bool _defaultInstanceIsMetered() {
  final before = FirestoreAttribution.referencesCreated;
  FirebaseFirestore.instance.doc('__usage_meter_probe__/probe');
  return FirestoreAttribution.referencesCreated != before;
}

bool _failureReported = false;

void _reportFailure(String why) {
  _failure = why;
  if (_failureReported) return;
  _failureReported = true;
  final message = '[UsageMeter] ERROR: Firestore document metering is not active ($why). '
      'Direct DocumentReference reads and writes are not metered; gateway writes are counted by the gateway.';
  developer.log(message, name: 'UsageMeter', level: 1000);
  // A plain print reaches release-build logs (browser console, logcat).
  // ignore: avoid_print
  print(message);
  UsageMeter.instance.recordWhenAttributed(platformAppId, meteringInstallFailedMetric, 1);
}

/// Forgets the install state (not the installed platform): a later
/// [installFirestorePlatformMetering] re-checks it from scratch.
@visibleForTesting
void resetFirestorePlatformMeteringForTesting() {
  _installed = false;
  _failure = null;
  _failureReported = false;
}
