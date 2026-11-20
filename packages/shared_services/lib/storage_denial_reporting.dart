// Storage half of the production permission-denied reporter
// (rules_denial_reporter.dart).
//
// Callers reach Storage through ScopedStorage, but what it hands out is the
// plugin's own `Reference`, on which they call getDownloadURL()/delete()/
// putData()/... directly. Every such Reference holds a ReferencePlatform
// created by the platform instance, so, as with Firestore's document
// metering (firestore_platform_metering.dart), the hook is one layer down:
// [installStorageDenialReporting] replaces `FirebaseStoragePlatform.instance`
// with a delegating wrapper whose references report rules denials
// (`unauthorized`) and otherwise behave exactly like the plugin's own. Every
// result and error is the plugin's, unchanged; tasks are returned as-is,
// with only a side listener on their completion.

import 'dart:io' show File;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'rules_denial_reporter.dart';

bool _installed = false;

/// Whether Storage denial reporting is active.
bool get storageDenialReportingInstalled => _installed;

/// Wraps `FirebaseStoragePlatform.instance` so every Storage reference
/// reports rules denials. Call once, right after `Firebase.initializeApp`
/// and before any Storage use (a `FirebaseStorage` keeps the platform
/// instance it first resolved). Idempotent; never throws.
bool installStorageDenialReporting() {
  if (_installed) return true;
  try {
    final base = FirebaseStoragePlatform.instance;
    if (base is! DenialReportingStoragePlatform) {
      FirebaseStoragePlatform.instance = DenialReportingStoragePlatform(base);
    }
    _installed = true;
  } catch (e) {
    debugPrint('[RulesDenialReporter] Storage denial reporting not installed: $e');
  }
  return _installed;
}

@visibleForTesting
void resetStorageDenialReportingForTesting() => _installed = false;

/// A [FirebaseStoragePlatform] that delegates everything to [inner] and
/// hands out references that report rules denials.
class DenialReportingStoragePlatform extends FirebaseStoragePlatform {
  DenialReportingStoragePlatform(this.inner) : super(bucket: inner.bucket);

  final FirebaseStoragePlatform inner;

  ReferencePlatform wrap(ReferencePlatform ref) =>
      ref is DenialReportingReference ? ref : DenialReportingReference(this, ref);

  @override
  FirebaseApp get app => inner.app;

  @override
  int get maxOperationRetryTime => inner.maxOperationRetryTime;

  @override
  int get maxUploadRetryTime => inner.maxUploadRetryTime;

  @override
  int get maxDownloadRetryTime => inner.maxDownloadRetryTime;

  @override
  String? get emulatorHost => inner.emulatorHost;

  @override
  set emulatorHost(String? value) => inner.emulatorHost = value;

  @override
  int? get emulatorPort => inner.emulatorPort;

  @override
  set emulatorPort(int? value) => inner.emulatorPort = value;

  @override
  FirebaseStoragePlatform delegateFor({required FirebaseApp app, required String bucket}) {
    final delegate = inner.delegateFor(app: app, bucket: bucket);
    return delegate is DenialReportingStoragePlatform ? delegate : DenialReportingStoragePlatform(delegate);
  }

  @override
  ReferencePlatform ref(String path) => wrap(inner.ref(path));

  @override
  Future<void> useStorageEmulator(String host, int port) => inner.useStorageEmulator(host, port);

  @override
  void setMaxOperationRetryTime(int time) => inner.setMaxOperationRetryTime(time);

  @override
  void setMaxUploadRetryTime(int time) => inner.setMaxUploadRetryTime(time);

  @override
  void setMaxDownloadRetryTime(int time) => inner.setMaxDownloadRetryTime(time);
}

/// A [ReferencePlatform] delegating to the plugin's own [inner], reporting
/// rules denials of its operations to [RulesDenialReporter].
class DenialReportingReference extends ReferencePlatform {
  DenialReportingReference(this._storage, this.inner) : super(_storage, inner.fullPath);

  final DenialReportingStoragePlatform _storage;
  final ReferencePlatform inner;

  void Function(Object error) _report(String op) =>
      (error) => RulesDenialReporter.instance.storage(error, op: op, fullPath: () => inner.fullPath);

  Future<T> _watch<T>(String op, Future<T> operation) => RulesDenialReporter.watch(operation, _report(op));

  /// [task], unchanged, with a side listener that reports a denial.
  TaskPlatform _watchTask(String op, TaskPlatform task) {
    try {
      task.onComplete.then((_) {}, onError: (Object error) => _report(op)(error));
    } catch (_) {
      // A task without onComplete (test fakes): nothing to watch.
    }
    return task;
  }

  @override
  String get bucket => inner.bucket;

  @override
  String get fullPath => inner.fullPath;

  @override
  String get name => inner.name;

  @override
  ReferencePlatform? get parent {
    final p = inner.parent;
    return p == null ? null : _storage.wrap(p);
  }

  @override
  ReferencePlatform get root => _storage.wrap(inner.root);

  @override
  ReferencePlatform child(String path) => _storage.wrap(inner.child(path));

  @override
  Future<void> delete() => _watch('delete', inner.delete());

  @override
  Future<String> getDownloadURL() => _watch('download', inner.getDownloadURL());

  @override
  Future<FullMetadata> getMetadata() => _watch('get', inner.getMetadata());

  @override
  Future<ListResultPlatform> list([ListOptions? options]) =>
      _watch('list', inner.list(options)).then((r) => DenialReportingListResult(_storage, r));

  @override
  Future<ListResultPlatform> listAll() =>
      _watch('list', inner.listAll()).then((r) => DenialReportingListResult(_storage, r));

  @override
  Future<Uint8List?> getData(int maxSize) => _watch('download', inner.getData(maxSize));

  @override
  TaskPlatform putData(Uint8List data, [SettableMetadata? metadata]) =>
      _watchTask('upload', inner.putData(data, metadata));

  @override
  TaskPlatform putBlob(dynamic data, [SettableMetadata? metadata]) =>
      _watchTask('upload', inner.putBlob(data, metadata));

  @override
  TaskPlatform putFile(File file, [SettableMetadata? metadata]) =>
      _watchTask('upload', inner.putFile(file, metadata));

  @override
  TaskPlatform putString(String data, PutStringFormat format, [SettableMetadata? metadata]) =>
      _watchTask('upload', inner.putString(data, format, metadata));

  @override
  Future<FullMetadata> updateMetadata(SettableMetadata metadata) =>
      _watch('update', inner.updateMetadata(metadata));

  @override
  TaskPlatform writeToFile(File file) => _watchTask('download', inner.writeToFile(file));
}

/// A listing whose item and prefix references report denials too.
class DenialReportingListResult extends ListResultPlatform {
  DenialReportingListResult(this._storage, this.inner) : super(_storage, inner.nextPageToken);

  final DenialReportingStoragePlatform _storage;
  final ListResultPlatform inner;

  @override
  List<ReferencePlatform> get items => [for (final r in inner.items) _storage.wrap(r)];

  @override
  List<ReferencePlatform> get prefixes => [for (final r in inner.prefixes) _storage.wrap(r)];
}
