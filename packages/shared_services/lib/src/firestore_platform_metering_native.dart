// Document-level Firestore metering for the method-channel platform
// (Android, iOS, macOS, Windows, and VM tests): the plugin's own classes
// with the shared metering mixins from document_metering.dart. Only
// constructors and the methods whose signatures differ from the web
// (`update`, `snapshots`) are here.
//
// These classes come from cloud_firestore_platform_interface's src/, which
// isn't exported. They're verified against 8.0.x (pinned in pubspec.yaml)
// by test/firestore_platform_metering_test.dart, which drives them through
// cloud_firestore's public API and the real pigeon codec.
// ignore_for_file: implementation_imports

import 'package:cloud_firestore_platform_interface/cloud_firestore_platform_interface.dart';
import 'package:cloud_firestore_platform_interface/src/method_channel/method_channel_collection_reference.dart';
import 'package:cloud_firestore_platform_interface/src/method_channel/method_channel_document_reference.dart';
import 'package:cloud_firestore_platform_interface/src/method_channel/method_channel_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../metered_firestore.dart' show FirestoreMeteringContext;
import 'document_metering.dart';

/// The metered replacement for [base] (the platform's default instance), or
/// null when [base] isn't the plain method-channel implementation.
FirebaseFirestorePlatform? meteredPlatformFor(FirebaseFirestorePlatform base) {
  if (base.runtimeType != MethodChannelFirebaseFirestore) return null;
  // Same app as the plugin's own root instance; like it, this one is only
  // used for delegateFor(app).
  return MeteredMethodChannelFirestore(app: base.app);
}

class MeteredMethodChannelFirestore extends MethodChannelFirebaseFirestore with MeteredFirestorePlatform {
  MeteredMethodChannelFirestore({super.app, super.databaseId});

  @override
  FirebaseFirestorePlatform delegateFor({required FirebaseApp app, required String databaseId}) =>
      MeteredMethodChannelFirestore(app: app, databaseId: databaseId);

  @override
  CollectionReferencePlatform newMeteredCollection(String path, FirestoreMeteringContext? metering) =>
      MeteredMethodChannelCollectionReference(this, path, pigeonApp, metering);

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      MeteredMethodChannelDocumentReference(this, path, pigeonApp, metering);
}

class MeteredMethodChannelCollectionReference extends MethodChannelCollectionReference
    with MeteredCollectionReferencePlatform {
  MeteredMethodChannelCollectionReference(super.firestore, super.path, super.pigeonApp, this.metering);

  @override
  final FirestoreMeteringContext? metering;

  @override
  DocumentReferencePlatform newMeteredDocument(String path, FirestoreMeteringContext? metering) =>
      MeteredMethodChannelDocumentReference(firestore, path, pigeonApp, metering);
}

class MeteredMethodChannelDocumentReference extends MethodChannelDocumentReference
    with MeteredDocumentReferencePlatform {
  MeteredMethodChannelDocumentReference(super.firestore, super.path, super.pigeonApp, this.metering);

  @override
  final FirestoreMeteringContext? metering;

  @override
  Future<void> update(Map<FieldPath, dynamic> data) => meter.write(() => super.update(data), op: 'update');

  @override
  Stream<DocumentSnapshotPlatform> snapshots({
    bool includeMetadataChanges = false,
    ServerTimestampBehavior serverTimestampBehavior = ServerTimestampBehavior.none,
    required ListenSource listenSource,
  }) =>
      meter.snapshots(
        () => super.snapshots(
          includeMetadataChanges: includeMetadataChanges,
          serverTimestampBehavior: serverTimestampBehavior,
          listenSource: listenSource,
        ),
        includeMetadataChanges: includeMetadataChanges,
      );
}
