import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/record_import_store.dart';
import 'package:shared_services/scoped_collection.dart';

/// The writer and undo against a fake Firestore: batch and chunk records,
/// references between created records, subcollections, and undo keeping
/// records edited since the import.
void main() {
  late FakeFirebaseFirestore fake;
  late RecordImportStore store;
  const uid = 'u1';

  ScopedCollection scoped(String collection, String appId) =>
      ScopedCollection(collection: collection, appId: appId, firestore: fake, currentUid: () => uid);

  final people = ImportSpec(
    id: 'test.contact',
    appId: 'contacts',
    collection: 'contacts',
    label: 'Contacts',
    singular: 'contact',
    remove: const ImportRemove.softDelete(),
    createTimestamps: const ['createdAt'],
    updateTimestamps: const ['updatedAt'],
    fields: const [
      ImportField.text('name', 'Name', required: true),
      ImportField.text('org', 'Organization'),
      ImportField.text('notes', 'Notes'),
    ],
    duplicateKeys: const [ImportKey(['name'])],
    build: (row, ctx) => {'name': row.text('name'), 'notes': row.text('notes')},
    expand: (row, data, ctx, x) => row.has('org')
        ? ImportBuildCreate(
            {...data, 'orgId': x.ensure(row.text('org').toLowerCase(), row.line, () => {'name': row.text('org'), 'notes': ''})})
        : null,
  );

  Future<ImportPlan> plan(ImportSpec spec, String csv, {ImportSettings settings = const ImportSettings(), String? parentId}) async {
    final table = parseCsvTable(csv);
    final existing = await store.loadExisting(spec, parentId: parentId);
    return planImport(spec, table, guessCsvColumns(table.headers, spec.csvFields),
        ctx: ImportContext(existing: existing, uid: uid), settings: settings);
  }

  Future<ImportJob> run(ImportSpec spec, ImportPlan p, {ImportSettings settings = const ImportSettings(), String? parentId}) async {
    final job = await store.start(spec, p, fileName: 'people.csv', settings: settings, parentId: parentId);
    await store.write(job);
    return job;
  }

  Future<Map<String, Map<String, dynamic>>> docs(String path) async =>
      {for (final d in (await fake.collection(path).get()).docs) d.id: d.data()};

  setUp(() {
    fake = FakeFirebaseFirestore();
    store = RecordImportStore(scoped: scoped, currentUid: () => uid);
    ActiveGroupService.instance.activeGroupId = 'g1';
  });

  tearDown(() => ActiveGroupService.instance.activeGroupId = null);

  test('writes records, the batch record and its chunk, resolving references', () async {
    final p = await plan(people, 'Name,Organization\nAna,Acme\nBo,acme\n');
    final job = await run(people, p);

    final contacts = await docs('contacts');
    expect(contacts, hasLength(3));
    final acme = contacts.entries.singleWhere((e) => e.value['name'] == 'Acme');
    final ana = contacts.values.singleWhere((c) => c['name'] == 'Ana');
    expect(ana['orgId'], acme.key);
    expect(ana['importBatchId'], job.batchId);
    expect(ana['groupId'], 'g1');
    expect(ana['creatorId'], uid);
    expect(ana.containsKey('createdAt'), isTrue);

    final batch = (await fake.doc('import_batches/${job.batchId}').get()).data()!;
    expect(batch['specId'], 'test.contact');
    expect(batch['appId'], 'contacts');
    expect(batch['ownerIds'], [uid]);
    expect(batch['status'], 'done');
    expect(batch['counts'], {'created': 3, 'updated': 0, 'skipped': 0, 'failed': 0});
    final chunks = await docs('import_batches/${job.batchId}/rows');
    expect(chunks.keys, ['0000']);
    expect((chunks['0000']!['created'] as List), hasLength(3));
  });

  test('undo removes created records and restores updated ones', () async {
    await scoped('contacts', 'contacts').doc('c1').set({'name': 'Cy', 'notes': '', 'groupId': 'g1', 'appId': 'contacts'});
    const settings = ImportSettings(duplicates: ImportDuplicates.update);
    final p = await plan(people, 'Name,Notes\nCy,Likes tea\nDee,\n', settings: settings);
    expect(p.updates.single.changes, {'notes': 'Likes tea'});
    final job = await run(people, p, settings: settings);
    expect((await fake.doc('contacts/c1').get()).data()!['notes'], 'Likes tea');

    final batch = (await store.getBatch(people, job.batchId))!;
    expect(batch.canUndo(uid: uid, isAppAdmin: false, now: DateTime.now()), isTrue);
    expect(batch.canUndo(uid: 'someone-else', isAppAdmin: false, now: DateTime.now()), isFalse);
    expect(batch.canUndo(uid: uid, isAppAdmin: false, now: DateTime.now().add(const Duration(days: 8))), isFalse);

    final preview = await store.previewUndo(people, batch);
    expect(preview.remove, hasLength(1));
    expect(preview.restore, hasLength(1));
    expect(preview.changed, isEmpty);
    final result = await store.undo(people, preview);
    expect(result.removed, 1);
    expect(result.restored, 1);

    final cy = (await fake.doc('contacts/c1').get()).data()!;
    expect(cy['notes'], '');
    expect(cy.containsKey('importBatchId'), isFalse);
    final dee = (await docs('contacts')).values.singleWhere((c) => c['name'] == 'Dee');
    expect(dee['deletedAt'], isNotNull);
    final undone = (await store.getBatch(people, job.batchId))!;
    expect(undone.status, ImportBatchStatus.undone);
    expect(undone.canUndo(uid: uid, isAppAdmin: true, now: DateTime.now()), isFalse);
  });

  test('records edited after the import are kept unless asked', () async {
    final p = await plan(people, 'Name\nEd\nFay\n');
    final job = await run(people, p);
    final ids = {for (final e in (await docs('contacts')).entries) e.value['name']: e.key};
    await fake.doc('contacts/${ids['Ed']}').update({'notes': 'Called on Monday'});

    final batch = (await store.getBatch(people, job.batchId))!;
    final preview = await store.previewUndo(people, batch);
    expect(preview.remove.map((r) => r.id), [ids['Fay']]);
    expect(preview.changed.single.record.id, ids['Ed']);

    final kept = await store.undo(people, preview);
    expect(kept.kept, 1);
    expect((await fake.doc('contacts/${ids['Ed']}').get()).data()!['deletedAt'], isNull);
    expect((await fake.doc('contacts/${ids['Fay']}').get()).data()!['deletedAt'], isNotNull);
  });

  test('undo can include records edited since', () async {
    final p = await plan(people, 'Name\nGus\n');
    final job = await run(people, p);
    final id = (await docs('contacts')).keys.single;
    await fake.doc('contacts/$id').update({'name': 'Gus Grant'});
    final preview = await store.previewUndo(people, (await store.getBatch(people, job.batchId))!);
    final result = await store.undo(people, preview, includeChanged: true);
    expect(result.removed, 1);
    expect((await fake.doc('contacts/$id').get()).data()!['deletedAt'], isNotNull);
  });

  test('a later import of the same file skips what the first one added', () async {
    await run(people, await plan(people, 'Name\nHal\nIvy\n'));
    final again = await plan(people, 'Name\nHal\nIvy\nJo\n');
    expect(again.duplicates.map((d) => d.line), [2, 3]);
    expect(again.creates.single.data['name'], 'Jo');
  });

  test('large imports are written in chunks of 400', () async {
    final csv = StringBuffer('Name\n');
    for (var i = 0; i < 450; i++) {
      csv.writeln('Person $i');
    }
    final job = await run(people, await plan(people, csv.toString()));
    expect(job.created, 450);
    expect((await docs('import_batches/${job.batchId}/rows')).keys, ['0000', '0001']);
    expect(job.isFinished, isTrue);
    await store.write(job); // already finished: a no-op
    expect((await docs('contacts')), hasLength(450));
  });

  test('subcollection specs write under the parent and hard-delete on undo', () async {
    await fake.doc('projects/list1').set({'name': 'Groceries', 'groupId': 'g1', 'appId': 'lists'});
    final tasks = ImportSpec(
      id: 'test.task',
      appId: 'lists',
      collection: 'projects',
      subcollection: 'tasks',
      label: 'Tasks',
      singular: 'task',
      fields: const [ImportField.text('text', 'Task', required: true)],
      build: (row, ctx) => {'text': row.text('text'), 'isCompleted': false},
    );
    expect(() => store.recordsOf(tasks), throwsArgumentError);
    final job = await run(tasks, await plan(tasks, 'Task\nMilk\nEggs\n', parentId: 'list1'), parentId: 'list1');
    final written = await docs('projects/list1/tasks');
    expect(written.values.map((t) => t['text']), unorderedEquals(['Milk', 'Eggs']));
    expect(written.values.first['groupId'], 'g1');

    final batch = (await store.getBatch(tasks, job.batchId))!;
    expect(batch.parentId, 'list1');
    await store.undo(tasks, await store.previewUndo(tasks, batch));
    expect(await docs('projects/list1/tasks'), isEmpty);
  });

  test('Recent imports lists the signed-in person\'s batches for the spec, newest first', () async {
    await run(people, await plan(people, 'Name\nKai\n'));
    await run(people, await plan(people, 'Name\nLu\n'));
    final batches = await store.watchBatches(people).first;
    expect(batches, hasLength(2));
    expect(batches.every((b) => b.specId == 'test.contact'), isTrue);
  });
}
