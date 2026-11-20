import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'record_import.dart';
import 'scoped_collection.dart';

export 'record_import.dart';

/// The Firestore side of spreadsheet import (plans/spreadsheet-import §5):
/// loading the records a plan is checked against, writing a plan in
/// batches with an `import_batches` record, Recent imports, and undo.
///
/// Every write goes through [ScopedCollection], so the deployed rules
/// decide what the person importing may do, and audited collections get an
/// audit event per record with no extra work.
///
/// ```
/// import_batches/{batchId}
///   groupId, appId, creatorId, ownerIds      // ScopedCollection identity
///   specId, collection, parentId, fileName, rowCount
///   options: { duplicates, replaceExisting }
///   status: 'writing' | 'done' | 'failed' | 'undone'
///   counts: { created, updated, skipped, failed, undone, kept }
///   chunkCount, startedAt, finishedAt, undoneAt, undoneBy
/// import_batches/{batchId}/rows/{chunk}      // up to 400 entries each
///   created: [{ id, h, k }]                  // h: fingerprint of fields k
///   updated: [{ id, before, absent, h, k }]  // before: the changed fields' old values
/// ```
///
/// Each chunk doc is committed in the same batch as its records, so the
/// batch record always matches what was written.

/// How long the person who ran an import (or the app's admins) can undo it.
const Duration kImportUndoWindow = Duration(days: 7);

/// Records per Firestore batch, leaving room for the chunk and batch docs.
const int kImportChunkSize = 400;

/// The collection batch records live in.
const String kImportBatchesCollection = 'import_batches';

enum ImportBatchStatus {
  writing,
  done,
  failed,
  undone;

  static ImportBatchStatus parse(Object? value) =>
      ImportBatchStatus.values.where((s) => s.name == value).firstOrNull ?? ImportBatchStatus.failed;
}

/// A batch record, as Recent imports shows it.
class ImportBatch {
  const ImportBatch({
    required this.id,
    required this.specId,
    required this.status,
    this.creatorId = '',
    this.collection = '',
    this.parentId,
    this.fileName = '',
    this.rowCount = 0,
    this.counts = const {},
    this.startedAt,
    this.finishedAt,
    this.undoneAt,
  });

  factory ImportBatch.fromMap(String id, Map<String, dynamic> d) {
    DateTime? date(Object? v) => v is Timestamp ? v.toDate() : (v is DateTime ? v : null);
    return ImportBatch(
      id: id,
      specId: d['specId'] as String? ?? '',
      status: ImportBatchStatus.parse(d['status']),
      creatorId: d['creatorId'] as String? ?? '',
      collection: d['collection'] as String? ?? '',
      parentId: d['parentId'] as String?,
      fileName: d['fileName'] as String? ?? '',
      rowCount: (d['rowCount'] as num?)?.toInt() ?? 0,
      counts: {
        for (final e in ((d['counts'] as Map?) ?? const {}).entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      },
      startedAt: date(d['startedAt']),
      finishedAt: date(d['finishedAt']),
      undoneAt: date(d['undoneAt']),
    );
  }

  final String id;
  final String specId;
  final ImportBatchStatus status;
  final String creatorId;
  final String collection;
  final String? parentId;
  final String fileName;
  final int rowCount;
  final Map<String, int> counts;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? undoneAt;

  int count(String key) => counts[key] ?? 0;

  /// Whether [uid] may still undo it at [now]: its importer, or an admin of
  /// the app ([isAppAdmin]), within [kImportUndoWindow] of its start, unless
  /// it was undone already or wrote nothing.
  bool canUndo({required String uid, required bool isAppAdmin, required DateTime now}) {
    if (status == ImportBatchStatus.undone) return false;
    if (count('created') + count('updated') == 0) return false;
    if (uid != creatorId && !isAppAdmin) return false;
    final start = startedAt;
    return start != null && now.difference(start) <= kImportUndoWindow;
  }
}

/// Progress of a write: records written so far out of [total].
typedef ImportProgress = void Function(int done, int total);

class _Op {
  _Op.create(this.ref, this.payload, this.fields)
      : before = const {},
        absent = const [],
        isUpdate = false;

  _Op.update(this.ref, this.payload, this.fields, this.before, this.absent) : isUpdate = true;

  final DocumentReference<Map<String, dynamic>> ref;
  final Map<String, dynamic> payload;

  /// The fields the fingerprint covers: what the import wrote.
  final List<String> fields;
  final Map<String, dynamic> before;
  final List<String> absent;
  final bool isUpdate;

  Map<String, dynamic> entry() => {
        'id': ref.id,
        'h': importFingerprint(payload, fields),
        'k': fields,
        if (isUpdate) 'before': before,
        if (isUpdate && absent.isNotEmpty) 'absent': absent,
      };
}

/// A plan being written. [RecordImportStore.write] can be called again
/// after a failure: it continues from the first chunk that wasn't
/// committed, with the same ids, so nothing is written twice.
class ImportJob {
  ImportJob._(this.spec, this.plan, this.batchRef, this._records, this._rows, this._ops, this.skipped);

  final ImportSpec spec;
  final ImportPlan plan;
  final DocumentReference<Map<String, dynamic>> batchRef;
  final ScopedCollection _records;
  final ScopedCollection _rows;
  final List<_Op> _ops;

  /// Rows not imported (duplicates, unchanged and problems).
  final int skipped;

  int _nextChunk = 0;
  int created = 0;
  int updated = 0;

  /// Updates the rules refused (Contacts members may only change contacts
  /// they added).
  int failed = 0;

  String get batchId => batchRef.id;
  int get total => _ops.length;
  int get written => math.min(_nextChunk * kImportChunkSize, _ops.length);
  bool get isFinished => _nextChunk * kImportChunkSize >= _ops.length;

  Map<String, int> get counts =>
      {'created': created, 'updated': updated, 'skipped': skipped, 'failed': failed + plan.problems.length};
}

/// What undo would do with a batch, worked out before anything changes.
class ImportUndoPreview {
  const ImportUndoPreview({
    required this.batch,
    this.remove = const [],
    this.restore = const [],
    this.changed = const [],
    this.gone = 0,
  });

  final ImportBatch batch;

  /// Created records still as the import left them.
  final List<ImportExisting> remove;

  /// Updated records still as the import left them, with their old values.
  final List<(ImportExisting, Map<String, dynamic>, List<String>)> restore;

  /// Records edited since the import: kept unless the person asks.
  final List<ImportUndoChanged> changed;

  /// Created records already removed.
  final int gone;
}

/// A record edited after the import, which undo keeps by default.
class ImportUndoChanged {
  const ImportUndoChanged(this.record, {this.before, this.absent = const []});

  final ImportExisting record;

  /// For an updated record, its values before the import; null for one the
  /// import created.
  final Map<String, dynamic>? before;
  final List<String> absent;

  bool get wasCreated => before == null;
}

class ImportUndoResult {
  const ImportUndoResult({this.removed = 0, this.restored = 0, this.kept = 0});

  final int removed;
  final int restored;
  final int kept;
}

class RecordImportStore {
  /// [scoped] makes the collections (tests pass ones on a fake Firestore);
  /// [currentUid] is who undoes, for the batch record.
  RecordImportStore({
    ScopedCollection Function(String collection, String appId)? scoped,
    String Function()? currentUid,
  })  : _scopedOverride = scoped,
        _currentUid = currentUid;

  static final RecordImportStore instance = RecordImportStore();

  final ScopedCollection Function(String collection, String appId)? _scopedOverride;
  final String Function()? _currentUid;

  ScopedCollection _scoped(String collection, String appId) =>
      _scopedOverride?.call(collection, appId) ?? ScopedCollection(collection: collection, appId: appId);

  /// The collection [spec] writes to (under [parentId] for a subcollection).
  ScopedCollection recordsOf(ImportSpec spec, {String? parentId}) {
    final top = _scoped(spec.collection, spec.appId);
    final sub = spec.subcollection;
    if (sub == null) return top;
    if (parentId == null || parentId.isEmpty) {
      throw ArgumentError('Import spec ${spec.id} needs the parent id of its ${spec.collection} record.');
    }
    return top.sub(parentId, sub);
  }

  ScopedCollection batchesOf(String appId) => _scoped(kImportBatchesCollection, appId);

  /// Every record [spec]'s duplicates are checked against: the whole list,
  /// or, where the collection is ownerScoped (each person's own records),
  /// only the signed-in person's own, even for the app's admins.
  Future<List<ImportExisting>> loadExisting(ImportSpec spec, {String? parentId}) async {
    final records = recordsOf(spec, parentId: parentId);
    final ownedOnly = !records.isSubcollection && records.policy.ownerScoped;
    final snap = await (ownedOnly ? records.queryOwned() : records.query).get();
    return [for (final d in snap.docs) ImportExisting(d.id, d.data())];
  }

  /// Writes the batch record for [plan] and prepares its writes; then call
  /// [write].
  Future<ImportJob> start(
    ImportSpec spec,
    ImportPlan plan, {
    required String fileName,
    ImportSettings settings = const ImportSettings(),
    String? parentId,
  }) async {
    final records = recordsOf(spec, parentId: parentId);
    if (records.isSubcollection) await records.resolveTenant();
    final batches = batchesOf(spec.appId);
    final batchRef = batches.doc();
    final batchId = batchRef.id;

    // Ids first, so rows can refer to extra records the import creates.
    final extraIds = <String, String>{};
    final createRefs = <(PlannedCreate, DocumentReference<Map<String, dynamic>>)>[];
    for (final c in [...plan.extras, ...plan.creates]) {
      final ref = records.doc();
      if (c.extraKey != null) extraIds[c.extraKey!] = ref.id;
      createRefs.add((c, ref));
    }
    Object? resolve(Object? v) => switch (v) {
          ImportRef(:final key) => extraIds[key],
          final Map<String, dynamic> m => {for (final e in m.entries) e.key: resolve(e.value)},
          final List<dynamic> l => [for (final x in l) resolve(x)],
          _ => v,
        };
    Map<String, dynamic> resolved(Map<String, dynamic> data) =>
        {for (final e in data.entries) e.key: resolve(e.value)};

    final ops = <_Op>[];
    for (final (c, ref) in createRefs) {
      final data = resolved(c.data);
      ops.add(_Op.create(
        ref,
        {...data, 'importBatchId': batchId, for (final t in spec.createTimestamps) t: FieldValue.serverTimestamp()},
        data.keys.toList(),
      ));
    }
    for (final u in plan.updates) {
      final changes = resolved(u.changes);
      final keys = [...changes.keys, 'importBatchId'];
      ops.add(_Op.update(
        records.doc(u.existing.id),
        {...changes, 'importBatchId': batchId, for (final t in spec.updateTimestamps) t: FieldValue.serverTimestamp()},
        changes.keys.toList(),
        {for (final k in keys) if (u.existing.data.containsKey(k)) k: u.existing.data[k]},
        [for (final k in keys) if (!u.existing.data.containsKey(k)) k],
      ));
    }

    await batches.create(batchRef, {
      'specId': spec.id,
      'collection': spec.collection,
      'parentId': parentId,
      'fileName': fileName,
      'rowCount': plan.rowCount,
      'options': {'duplicates': settings.duplicates.name, 'replaceExisting': settings.replaceExisting},
      'status': ImportBatchStatus.writing.name,
      'counts': {'created': 0, 'updated': 0, 'skipped': 0, 'failed': 0},
      'chunkCount': 0,
      'startedAt': FieldValue.serverTimestamp(),
    });
    final rows = batches.sub(batchId, 'rows');
    await rows.resolveTenant();
    return ImportJob._(spec, plan, batchRef, records, rows, ops, plan.notImported.length + plan.unchanged);
  }

  /// Writes [job]'s remaining chunks. Throws when a chunk fails; the batch
  /// is marked failed, and calling this again continues where it stopped.
  Future<void> write(ImportJob job, {ImportProgress? onProgress}) async {
    final batches = batchesOf(job.spec.appId);
    try {
      while (!job.isFinished) {
        final start = job._nextChunk * kImportChunkSize;
        final ops = job._ops.sublist(start, math.min(start + kImportChunkSize, job._ops.length));
        final chunkRef = job._rows.doc(job._nextChunk.toString().padLeft(4, '0'));
        final written = await _writeChunk(job, ops, chunkRef);
        job.created += written.where((o) => !o.isUpdate).length;
        job.updated += written.where((o) => o.isUpdate).length;
        job.failed += ops.length - written.length;
        job._nextChunk++;
        onProgress?.call(job.written, job.total);
      }
      await batches.update(job.batchRef, {
        'status': ImportBatchStatus.done.name,
        'counts': job.counts,
        'chunkCount': job._nextChunk,
        'finishedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      try {
        await batches.update(job.batchRef, {
          'status': ImportBatchStatus.failed.name,
          'counts': job.counts,
          'chunkCount': job._nextChunk,
        });
      } catch (_) {
        // The record keeps "writing"; Recent imports still offers undo.
      }
      rethrow;
    }
  }

  /// Commits [ops] with their chunk doc. Creates go in one batch. Updates
  /// too, but when the rules refuse that batch each update is retried on
  /// its own so one refused record doesn't stop the rest; the chunk doc
  /// then lists only those written.
  Future<List<_Op>> _writeChunk(ImportJob job, List<_Op> ops, DocumentReference<Map<String, dynamic>> chunkRef) async {
    final records = job._records;
    void stage(WriteBatch batch, _Op op) =>
        op.isUpdate ? records.batchUpdate(batch, op.ref, op.payload) : records.batchSet(batch, op.ref, op.payload);
    Map<String, dynamic> chunk(List<_Op> written) => {
          'created': [for (final o in written) if (!o.isUpdate) o.entry()],
          'updated': [for (final o in written) if (o.isUpdate) o.entry()],
        };

    final batch = records.batch();
    for (final op in ops) {
      stage(batch, op);
    }
    job._rows.batchSet(batch, chunkRef, chunk(ops));
    try {
      await batch.commit();
      return ops;
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied' || ops.any((o) => !o.isUpdate)) rethrow;
    }
    final written = <_Op>[];
    for (final op in ops) {
      try {
        await records.update(op.ref, op.payload);
        written.add(op);
      } on FirebaseException catch (e) {
        if (e.code != 'permission-denied') rethrow;
      }
    }
    await job._rows.create(chunkRef, chunk(written));
    return written;
  }

  /// [spec]'s batch records, newest first: the signed-in person's own, or
  /// everyone's when [all] (the app's admins).
  Stream<List<ImportBatch>> watchBatches(ImportSpec spec, {bool all = false, String? parentId}) {
    final batches = batchesOf(spec.appId);
    var query = (all ? batches.query : batches.queryOwned()).where('specId', isEqualTo: spec.id);
    if (parentId != null) query = query.where('parentId', isEqualTo: parentId);
    return query.limit(200).snapshots().map((snap) {
      final list = [for (final d in snap.docs) ImportBatch.fromMap(d.id, d.data())];
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      list.sort((a, b) => (b.startedAt ?? epoch).compareTo(a.startedAt ?? epoch));
      return list;
    });
  }

  Future<ImportBatch?> getBatch(ImportSpec spec, String batchId) async {
    final snap = await batchesOf(spec.appId).doc(batchId).get();
    final data = snap.data();
    return data == null ? null : ImportBatch.fromMap(snap.id, data);
  }

  /// What undoing [batch] would do: which records are still as the import
  /// left them, and which were changed since.
  Future<ImportUndoPreview> previewUndo(ImportSpec spec, ImportBatch batch) async {
    final records = recordsOf(spec, parentId: batch.parentId);
    final chunks = await batchesOf(spec.appId).sub(batch.id, 'rows').query.get();
    final created = <Map<String, dynamic>>[];
    final updated = <Map<String, dynamic>>[];
    for (final c in chunks.docs) {
      created.addAll(((c.data()['created'] as List?) ?? const []).whereType<Map<String, dynamic>>());
      updated.addAll(((c.data()['updated'] as List?) ?? const []).whereType<Map<String, dynamic>>());
    }

    final ids = {...created.map((e) => e['id'] as String), ...updated.map((e) => e['id'] as String)}.toList();
    final current = <String, Map<String, dynamic>?>{};
    for (var i = 0; i < ids.length; i += 30) {
      final snaps = await Future.wait(ids.skip(i).take(30).map((id) => records.doc(id).get()));
      for (final s in snaps) {
        current[s.id] = s.data();
      }
    }

    bool untouched(Map<String, dynamic> data, Map<String, dynamic> entry) =>
        data['importBatchId'] == batch.id &&
        importFingerprint(data, ((entry['k'] as List?) ?? const []).cast<String>()) == entry['h'];

    final remove = <ImportExisting>[];
    final restore = <(ImportExisting, Map<String, dynamic>, List<String>)>[];
    final changed = <ImportUndoChanged>[];
    var gone = 0;
    for (final e in created) {
      final data = current[e['id']];
      if (data == null || !spec.remove.isLive(data)) {
        gone++;
      } else if (untouched(data, e)) {
        remove.add(ImportExisting(e['id'] as String, data));
      } else {
        changed.add(ImportUndoChanged(ImportExisting(e['id'] as String, data)));
      }
    }
    for (final e in updated) {
      final data = current[e['id']];
      if (data == null) continue;
      final before = Map<String, dynamic>.from((e['before'] as Map?) ?? const {});
      final absent = ((e['absent'] as List?) ?? const []).cast<String>();
      final record = ImportExisting(e['id'] as String, data);
      if (untouched(data, e)) {
        restore.add((record, before, absent));
      } else {
        changed.add(ImportUndoChanged(record, before: before, absent: absent));
      }
    }
    return ImportUndoPreview(batch: batch, remove: remove, restore: restore, changed: changed, gone: gone);
  }

  /// Undoes [preview]'s batch: created records are removed the way the
  /// spec says and updated ones get their old values back. Records changed
  /// since the import are kept unless [includeChanged].
  Future<ImportUndoResult> undo(ImportSpec spec, ImportUndoPreview preview, {bool includeChanged = false}) async {
    final records = recordsOf(spec, parentId: preview.batch.parentId);
    final remove = [
      ...preview.remove,
      if (includeChanged) for (final c in preview.changed) if (c.wasCreated) c.record,
    ];
    final restore = [
      ...preview.restore,
      if (includeChanged)
        for (final c in preview.changed)
          if (!c.wasCreated) (c.record, c.before!, c.absent),
    ];

    final ops = <void Function(WriteBatch)>[
      for (final r in remove)
        (b) => switch (spec.remove.mode) {
              ImportRemoveMode.delete => records.batchDelete(b, records.doc(r.id)),
              ImportRemoveMode.softDelete => records.batchSoftDelete(b, records.doc(r.id)),
              ImportRemoveMode.archive => records.batchUpdate(b, records.doc(r.id), {spec.remove.field!: true}),
            },
      for (final (r, before, absent) in restore)
        (b) => records.batchUpdate(b, records.doc(r.id), {
              ...before,
              for (final k in absent) k: FieldValue.delete(),
              for (final t in spec.updateTimestamps) t: FieldValue.serverTimestamp(),
            }),
    ];
    for (var i = 0; i < ops.length; i += kImportChunkSize) {
      final batch = records.batch();
      for (final op in ops.skip(i).take(kImportChunkSize)) {
        op(batch);
      }
      await batch.commit();
    }

    final kept = includeChanged ? 0 : preview.changed.length;
    final uid = _currentUid?.call() ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    await batchesOf(spec.appId).update(batchesOf(spec.appId).doc(preview.batch.id), {
      'status': ImportBatchStatus.undone.name,
      'undoneAt': FieldValue.serverTimestamp(),
      if (uid.isNotEmpty) 'undoneBy': uid,
      'counts.undone': remove.length + restore.length,
      'counts.kept': kept,
    });
    return ImportUndoResult(removed: remove.length, restored: restore.length, kept: kept);
  }
}
