// Document-level Firestore metering for the web platform: the plugin's own
// classes with the shared metering mixins from document_metering.dart (so
// the logic is the one the VM tests exercise). Only constructors and the
// methods whose signatures differ from native (`update`, `snapshots`) are
// here. They must be the plugin's classes: the web encoder only accepts a
// DocumentReferenceWeb as a reference value, and the web decoder casts the
// snapshot's platform to FirebaseFirestoreWeb.
//
// These classes come from cloud_firestore_web's src/, which isn't exported.
// They're verified against 5.7.x (pinned in pubspec.yaml); the web release
// build compiles this file.
// ignore_for_file: implementation_imports

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:cloud_firestore_web/cloud_firestore_web.dart';
import 'package:cloud_firestore_web/src/collection_reference_web.dart';
import 'package:cloud_firestore_web/src/document_reference_web.dart';
import 'package:cloud_firestore_web/src/interop/firestore.dart' as firestore_interop;
import 'package:firebase_core/firebase_core.dart';

import '../metered_firestore.dart' show FirestoreMeteringContext;
import 'document_metering.dart';

/// The metered replacement for [base] (the platform's default instance), or
/// null when [base] isn't the plain web implementation.
FirebaseFirestorePlatform? meteredPlatformFor(FirebaseFirestorePlatform base) {
  if (base.runtimeType != FirebaseFirestoreWeb) return null;
  // Same app as the plugin's own root instance; like it, this one is only
  // used for delegateFor(app).
  return MeteredFirestoreWeb(app: base.app);
}

/// Reaches the plugin's own `doc()` (the metering mixin overrides it in
/// the subclass) to read the JS Firestore instance, which the plugin keeps
/// private but every DocumentReferenceWeb exposes.
class _FirestoreWebAccess extends FirebaseFirestoreWeb {
  _FirestoreWebAccess({super.app, super.databaseId});

  late final firestore_interop.Firestore _webFirestore = (super.doc('_/_') as DocumentReferenceWeb).firestoreWeb;
}

class MeteredFirestoreWeb extends _FirestoreWebAccess with MeteredFirestorePlatform {
  MeteredFirestoreWeb({super.app, super.databaseId});

  @override
  FirebaseFirestorePlatform delegateFor({required FirebaseApp app, required String databaseId}) =>
      MeteredFirestoreWeb(app: app, databaseId: databaseId);

  @override
  CollectionReferencePlatform newMeteredCollection(String path, FirestoreMeteringContext? metering) =>
      MeteredCollectionReferenceWeb(this, _webFirestore, path, metering);

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      MeteredDocumentReferenceWeb(this, _webFirestore, path, metering);
}

class MeteredCollectionReferenceWeb extends CollectionReferenceWeb with MeteredCollectionReferencePlatform {
  MeteredCollectionReferenceWeb(this._platform, this._webFirestore, String path, this.metering)
      : super(_platform, _webFirestore, path);

  final FirebaseFirestorePlatform _platform;
  final firestore_interop.Firestore _webFirestore;

  @override
  final FirestoreMeteringContext? metering;

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      MeteredDocumentReferenceWeb(_platform, _webFirestore, path, metering);
}

class MeteredDocumentReferenceWeb extends DocumentReferenceWeb with MeteredDocumentReferencePlatform {
  MeteredDocumentReferenceWeb(super.firestore, super.firestoreWeb, super.path, this.metering);

  @override
  final FirestoreMeteringContext? metering;

  @override
  Future<void> update(Map<Object, dynamic> data) => meter.write(() => super.update(data), op: 'update');

  @override
  Stream<DocumentSnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    required ListenSource listenSource,
  }) =>
      meter.snapshots(
        () => super.snapshots(includeMetadataChanges: includeMetadataChanges, listenSource: listenSource),
        includeMetadataChanges: includeMetadataChanges,
      );
}
