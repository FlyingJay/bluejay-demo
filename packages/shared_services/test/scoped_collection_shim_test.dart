import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/rules_contract_recorder.dart';
import 'package:shared_services/scoped_collection.dart';

/// The client shim's rules-facing semantics (plans/firestore-rules T10):
/// create-only identity stamping, sub(), docForKey(), the multi-app filter,
/// the raw-collection check and the contract recorder.
void main() {
  late FakeFirebaseFirestore fake;
  var uid = 'u1';

  ScopedCollection scoped(String collection,
          {String appId = 'notes', CollectionPolicy? policy}) =>
      ScopedCollection(
        collection: collection,
        appId: appId,
        firestore: fake,
        currentUid: () => uid,
        policy: policy,
      );

  Future<Map<String, dynamic>?> read(String path) async =>
      (await fake.doc(path).get()).data();

  setUp(() {
    fake = FakeFirebaseFirestore();
    uid = 'u1';
    ActiveGroupService.instance.activeGroupId = 'g1';
  });

  tearDown(() {
    ActiveGroupService.instance.activeGroupId = null;
    RulesContractRecorder.sink = null;
  });

  group('create-only identity', () {
    test('set() on a new doc stamps every permission field', () async {
      final notes = scoped('notes');
      await notes.set(notes.doc('a'), {'title': 't', 'groupId': 'evil', 'creatorId': 'evil'});
      expect(await read('notes/a'), {
        'title': 't',
        'groupId': 'g1',
        'appId': 'notes',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test("set(merge) on someone else's doc never rewrites its identity", () async {
      final notes = scoped('notes');
      await notes.set(notes.doc('a'), {'title': 't'});
      uid = 'u2';
      await notes.set(
        notes.doc('a'),
        {'title': 'edited', 'groupId': 'g2', 'appId': 'other', 'creatorId': 'u2'},
        SetOptions(merge: true),
      );
      expect(await read('notes/a'), {
        'title': 'edited',
        'groupId': 'g1',
        'appId': 'notes',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test('a full set() of an existing doc carries its identity over', () async {
      final notes = scoped('notes');
      await notes.set(notes.doc('a'), {'title': 't', 'extra': 1});
      uid = 'u2';
      await notes.set(notes.doc('a'), {'title': 'replaced'});
      expect(await read('notes/a'), {
        'title': 'replaced',
        'groupId': 'g1',
        'appId': 'notes',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test('an explicit ownerIds on update is kept (sharing)', () async {
      final notes = scoped('notes');
      await notes.set(notes.doc('a'), {'title': 't'});
      await notes.set(notes.doc('a'), {'ownerIds': ['u1', 'u3']}, SetOptions(merge: true));
      expect((await read('notes/a'))!['ownerIds'], ['u1', 'u3']);
      expect((await read('notes/a'))!['creatorId'], 'u1');
    });

    test('a mergeFields create still writes the identity fields', () async {
      final notes = scoped('notes');
      await notes.set(notes.doc('a'), {'title': 't'}, SetOptions(mergeFields: ['title']));
      // (fake_cloud_firestore writes every field whatever mergeFields says,
      // so this checks the identity fields arrive, not what's left out.)
      expect(await read('notes/a'), containsPair('groupId', 'g1'));
      expect(await read('notes/a'), containsPair('creatorId', 'u1'));
    });

    test('create(), add() and batchSet() stamp', () async {
      final notes = scoped('notes');
      await notes.create(notes.doc('a'), {'n': 1});
      final added = await notes.add({'n': 2});
      final batch = fake.batch();
      notes.batchSet(batch, notes.doc('c'), {'n': 3});
      await batch.commit();
      for (final path in ['notes/a', added.path, 'notes/c']) {
        expect((await read(path))!['groupId'], 'g1', reason: path);
        expect((await read(path))!['creatorId'], 'u1', reason: path);
      }
    });

    test('an update fills a missing tenant, never a missing creator', () async {
      await fake.doc('notes/legacy').set({'title': 'old'});
      final notes = scoped('notes');
      await notes.set(notes.doc('legacy'), {'title': 'new'}, SetOptions(merge: true));
      expect(await read('notes/legacy'), {'title': 'new', 'groupId': 'g1', 'appId': 'notes'});
    });

    test('fieldsForWrite is pure: create stamps, update strips', () {
      const args = (creatorId: 'u2', groupId: 'g2', appId: 'x');
      expect(
        ScopedCollection.fieldsForWrite({'n': 1},
            existing: null, merge: true, creatorId: args.creatorId, groupId: args.groupId, appId: args.appId),
        {'n': 1, 'groupId': 'g2', 'appId': 'x', 'creatorId': 'u2', 'ownerIds': ['u2']},
      );
      final existing = {'groupId': 'g1', 'appId': 'notes', 'creatorId': 'u1', 'ownerIds': ['u1']};
      expect(
        ScopedCollection.fieldsForWrite({'n': 1, 'creatorId': 'u2', 'groupId': 'g2'},
            existing: existing, merge: true, creatorId: 'u2', groupId: 'g2', appId: 'x'),
        {'n': 1},
      );
      expect(
        ScopedCollection.fieldsForWrite({'n': 1},
            existing: existing, merge: false, creatorId: 'u2', groupId: 'g2', appId: 'x'),
        {'n': 1, ...existing},
      );
    });
  });

  group('multi-app collections', () {
    const shared = CollectionPolicy(apps: ['a-app', 'b-app']);

    setUp(() async {
      await fake.doc('shared/1').set({'groupId': 'g1', 'appId': 'a-app'});
      await fake.doc('shared/2').set({'groupId': 'g1', 'appId': 'b-app'});
      await fake.doc('shared/3').set({'groupId': 'g2', 'appId': 'a-app'});
    });

    Future<List<String>> ids(Query<Map<String, dynamic>> q) async =>
        (await q.get()).docs.map((d) => d.id).toList()..sort();

    test("an owning app's query is also filtered to that app", () async {
      final a = scoped('shared', appId: 'a-app', policy: shared);
      expect(a.filtersByApp, isTrue);
      expect(await ids(a.query), ['1']);
    });

    test('a non-owner (staff tool) and a single-app collection get groupId only', () async {
      expect(await ids(scoped('shared', appId: 'staff', policy: shared).query), ['1', '2']);
      expect(
          await ids(scoped('shared', appId: 'a-app', policy: const CollectionPolicy(apps: ['a-app'])).query),
          ['1', '2']);
    });
  });

  group('sub()', () {
    test("stamps the parent's groupId and appId, and queries the subcollection", () async {
      await fake.doc('apps_docs/p').set({'groupId': 'g9', 'appId': 'origin-app'});
      final parent = scoped('apps_docs', appId: 'staff-tool');
      final history = parent.sub('p', 'edit_history');
      expect(history.collection, 'apps_docs/p/edit_history');
      expect(history.isSubcollection, isTrue);
      final ref = await history.add({'note': 'x'});
      expect(await read(ref.path), {
        'note': 'x',
        'groupId': 'g9',
        'appId': 'origin-app',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
      // A legacy subcollection doc without groupId stays visible.
      await fake.doc('apps_docs/p/edit_history/legacy').set({'note': 'old'});
      expect((await history.query.get()).docs, hasLength(2));
    });

    test("batchSet uses the parent's tenant once resolveTenant has read it", () async {
      await fake.doc('apps_docs/p').set({'groupId': 'g9', 'appId': 'origin-app'});
      final history = scoped('apps_docs', appId: 'staff-tool').sub('p', 'edit_history');
      expect(await history.resolveTenant(), ('g9', 'origin-app'));
      final batch = fake.batch();
      final ref = history.doc();
      history.batchSet(batch, ref, {'note': 'x', 'appId': 'staff-tool'});
      await batch.commit();
      expect(await read(ref.path), {
        'note': 'x',
        'groupId': 'g9',
        'appId': 'origin-app',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test('subOf(docRef) is the same sub() as through the parent collection', () async {
      await fake.doc('apps_docs/p').set({'groupId': 'g9', 'appId': 'origin-app'});
      final ledger = ScopedCollection.subOf(fake.doc('apps_docs/p'), 'transactions',
          appId: 'staff-tool', firestore: fake, currentUid: () => uid);
      expect(ledger.collection, 'apps_docs/p/transactions');
      expect(ledger.rootCollection, 'apps_docs');
      expect(ledger.isSubcollection, isTrue);
      final ref = ledger.doc();
      await ledger.create(ref, {'premiumCents': 1, 'groupId': 'evil'});
      expect(await read(ref.path), {
        'premiumCents': 1,
        'groupId': 'g9',
        'appId': 'origin-app',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test('transactionSet stamps like batchSet', () async {
      final notes = scoped('notes');
      final ref = notes.doc('t');
      await fake.runTransaction((tx) async {
        final snap = await tx.get(ref);
        expect(snap.exists, isFalse);
        notes.transactionSet(tx, ref, {'title': 't', 'creatorId': 'evil'});
      });
      expect(await read('notes/t'), {
        'title': 't',
        'groupId': 'g1',
        'appId': 'notes',
        'creatorId': 'u1',
        'ownerIds': ['u1'],
      });
    });

    test('resolveTenant of a top-level collection is the active group and app', () async {
      expect(await scoped('notes').resolveTenant(), ('g1', 'notes'));
    });

    test('falls back to the active group when the parent has no tenant', () async {
      final strokes = scoped('whiteboards', appId: 'whiteboard').sub('w', 'strokes');
      final ref = await strokes.add({'n': 1});
      expect((await read(ref.path))!['groupId'], 'g1');
      expect((await read(ref.path))!['appId'], 'whiteboard');
    });

    test('subcollectionGroup is filtered to the active group', () async {
      final events = scoped('events');
      await fake.doc('events/e1/attendees/u1').set({'groupId': 'g1'});
      await fake.doc('events/e2/attendees/u1').set({'groupId': 'g2'});
      final docs = (await events.subcollectionGroup('attendees').get()).docs;
      expect(docs.map((d) => d.reference.path), ['events/e1/attendees/u1']);
    });

    test('refuses a subcollection of a subcollection, which no rule reaches', () {
      final photos = scoped('recipes', appId: 'cookbook').sub('r', 'photos');
      expect(() => photos.sub('p', 'comments'), throwsUnsupportedError);
      expect(
          () => ScopedCollection.subOf(fake.doc('recipes/r/photos/p'), 'comments',
              appId: 'cookbook', firestore: fake, currentUid: () => uid),
          throwsUnsupportedError);
    });
  });

  group('docForKey()', () {
    test('tags the key with the active group, idempotently', () {
      final stats = scoped('farkle_stats');
      expect(stats.docForKey('u1').path, 'farkle_stats/g1__u1');
      expect(stats.docForKey('g1__u1').path, 'farkle_stats/g1__u1');
      expect(ScopedCollection.keyedDocId('g2', 'g1__u1'), 'g2__g1__u1');
      ActiveGroupService.instance.activeGroupId = null;
      expect(() => stats.docForKey('u1'), throwsStateError);
    });

    test('getForKey reads only the tagged doc', () async {
      final stats = scoped('farkle_stats');
      // An untagged doc with the same id as the key is never a fallback.
      await fake.doc('farkle_stats/u1').set({'groupId': 'g1', 'wins': 3});
      var snap = await stats.getForKey('u1');
      expect(snap.exists, isFalse);
      expect(snap.reference.path, 'farkle_stats/g1__u1');

      await fake.doc('farkle_stats/g1__u1').set({'groupId': 'g1', 'wins': 5});
      snap = await stats.getForKey('u1');
      expect(snap.data!['wins'], 5);
    });

    test('keyed writes touch only the tagged doc', () async {
      final stats = scoped('farkle_stats');
      await fake.doc('farkle_stats/u1').set({'groupId': 'g1', 'wins': 3});
      await stats.setForKey('u1', {'losses': 1}, SetOptions(merge: true));
      expect(await read('farkle_stats/g1__u1'), isNot(contains('wins')));
      await stats.updateForKey('u1', {'losses': FieldValue.increment(1)});
      expect((await read('farkle_stats/g1__u1'))!['losses'], 2);
      await stats.deleteForKey('u1');
      expect(await read('farkle_stats/g1__u1'), isNull);
      expect(await read('farkle_stats/u1'), isNotNull, reason: 'untagged doc untouched');
    });

    test('setForKey on a fresh key creates the tagged doc', () async {
      await scoped('farkle_stats').setForKey('u1', {'wins': 1});
      expect((await read('farkle_stats/g1__u1'))!['groupId'], 'g1');
      expect(await read('farkle_stats/u1'), isNull);
    });

    test('updateForKey on a missing key fails like update()', () async {
      await expectLater(
          scoped('farkle_stats').updateForKey('u1', {'wins': 1}), throwsA(anything));
    });

    test('deleteForKey of a missing key is a no-op', () async {
      await scoped('farkle_stats').deleteForKey('u1');
      expect(await read('farkle_stats/g1__u1'), isNull);
    });

    test('watchForKey emits missing, then the tagged doc once written', () async {
      final stats = scoped('farkle_stats');
      final seen = <String>[];
      final sub = stats.watchForKey('u1').listen((s) => seen.add('${s.data?['wins']}'));
      await pumpEventQueue();
      await stats.setForKey('u1', {'wins': 4}, SetOptions(merge: true));
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.first, 'null');
      expect(seen.last, '4');
    });

    test('naturalKeyOf / keyOf reverse the tag', () {
      expect(ScopedCollection.naturalKeyOf('g1', 'g1__u1'), 'u1');
      expect(ScopedCollection.naturalKeyOf('g1', 'u1'), 'u1');
      expect(ScopedCollection.naturalKeyOf('g1', 'g2__u1'), 'g2__u1');
      expect(ScopedCollection.naturalKeyOf('', '__u1'), '__u1');
      expect(scoped('farkle_stats').keyOf('g1__u1'), 'u1');
    });
  });

  group('raw-collection check', () {
    tearDown(() => MeteredFirestore.rawCollectionCheck = RawCollectionCheck.warn);

    test('pass-through kinds pass; tenant kinds fail only in fail mode', () {
      MeteredFirestore.rawCollectionCheck = RawCollectionCheck.fail;
      expect(collectionPolicyFor('payment_orders').isPassThrough, isTrue);
      expect(MeteredFirestore.checkRawCollection('payment_orders'), isTrue);
      expect(MeteredFirestore.checkRawCollection('notes'), isFalse);
      expect(MeteredFirestore.checkRawCollection('notes/a/items'), isFalse);
      expect(() => BluejayFirestore.forApp('notes', firestore: fake).collection('notes'),
          throwsA(isA<AssertionError>()));
      // ScopedCollection's own path skips the check.
      expect(() => scoped('notes').query, returnsNormally);

      MeteredFirestore.rawCollectionCheck = RawCollectionCheck.warn;
      expect(MeteredFirestore.checkRawCollection('notes'), isTrue);
    });

    test('an undeclared collection defaults to tenant', () {
      final p = collectionPolicyFor('zzz_not_in_the_table');
      expect(p.kind, CollectionKind.tenant);
      expect(p.isMultiApp, isFalse);
      expect(p.serverOwned, isFalse);
    });
  });

  test('the contract recorder sees the shim\'s operations', () async {
    final seen = <Map<String, Object?>>[];
    RulesContractRecorder.sink = seen.add;
    final notes = scoped('notes');
    notes.query;
    await notes.set(notes.doc('a'), {'title': 't'});
    await notes.set(notes.doc('a'), {'title': 'u'}, SetOptions(merge: true));
    expect(seen.map((d) => '${d['op']} ${d['path']}'), ['list notes', 'create notes/{id}', 'update notes/{id}']);
    expect(seen.first['filters'], [
      ['groupId', '==', r'$G'],
    ]);
    expect(seen.last['writeKeys'], ['title']);
  });

  group('audit trail stamping', () {
    const audited = CollectionPolicy(apps: ['notes'], auditTrail: true);

    test('every write to an audited collection stamps the writer and the server time', () async {
      final notes = scoped('notes', policy: audited);
      final ref = await notes.add({'title': 't'});
      var data = await read(ref.path);
      expect(data!['lastModifiedBy'], 'u1');
      expect(data['lastModifiedAt'], isA<Timestamp>());

      uid = 'u2';
      await notes.update(ref, {'title': 'edited', 'creatorId': 'u2', 'groupId': 'g2'});
      data = await read(ref.path);
      expect(data!['title'], 'edited');
      expect(data['lastModifiedBy'], 'u2');
      expect(data['creatorId'], 'u1', reason: 'update never sends identity fields');
      expect(data['groupId'], 'g1');

      final batch = fake.batch();
      uid = 'u3';
      notes.batchUpdate(batch, ref, {'title': 'batched'});
      await batch.commit();
      expect((await read(ref.path))!['lastModifiedBy'], 'u3');

      uid = 'u4';
      await notes.set(ref, {'title': 'merged'}, SetOptions(merge: true));
      expect((await read(ref.path))!['lastModifiedBy'], 'u4');
    });

    test('an audited subcollection (the comment thread) is stamped; its siblings are not', () async {
      const tickets = CollectionPolicy(
          apps: ['notes'], subcollections: {'comments': false, 'notes_x': false}, auditedSubcollections: {'comments'});
      final parent = scoped('notes', policy: tickets);
      final ref = await parent.add({'title': 't'});
      final comments = parent.sub(ref.id, 'comments');
      expect(parent.isAudited, isFalse);
      expect(comments.isAudited, isTrue);
      expect(parent.sub(ref.id, 'notes_x').isAudited, isFalse);
      uid = 'u7';
      final c = await comments.add({'text': 'hi', 'authorId': 'u7'});
      expect((await read(c.path))!['lastModifiedBy'], 'u7');
    });

    test('a collection without auditTrail, and an undeclared subcollection, gets no stamp', () async {
      final plain = scoped('notes', policy: const CollectionPolicy(apps: ['notes']));
      final ref = await plain.add({'title': 't'});
      await plain.update(ref, {'title': 'edited'});
      expect((await read(ref.path))!.containsKey('lastModifiedBy'), isFalse);
      expect(plain.auditStamp(), isEmpty);

      final parent = scoped('notes', policy: audited);
      final history = ScopedCollection.subOf(ref, 'edit_history', appId: 'notes', firestore: fake, currentUid: () => uid);
      expect(history.isAudited, isFalse);
      expect(parent.isAudited, isTrue);
    });
  });

  group('soft delete', () {
    const audited = CollectionPolicy(apps: ['notes'], auditTrail: true);

    test('softDelete and batchSoftDelete set deletedAt and keep the doc, stamped for the audit trail', () async {
      final notes = scoped('notes', policy: audited);
      final a = await notes.add({'title': 'a'});
      final b = await notes.add({'title': 'b'});
      expect(ScopedCollection.isSoftDeleted(await read(a.path)), isFalse);

      uid = 'u2';
      await notes.softDelete(a);
      final batch = fake.batch();
      notes.batchSoftDelete(batch, b);
      await batch.commit();

      for (final ref in [a, b]) {
        final data = await read(ref.path);
        expect(data, isNotNull, reason: 'a soft delete keeps the document');
        expect(data![ScopedCollection.softDeleteField], isA<Timestamp>());
        expect(data['lastModifiedBy'], 'u2');
        expect(data['creatorId'], 'u1');
        expect(ScopedCollection.isSoftDeleted(data), isTrue);
      }
    });

    test('a missing document counts as deleted', () {
      expect(ScopedCollection.isSoftDeleted(null), isTrue);
      expect(ScopedCollection.isSoftDeleted({'deletedAt': null}), isFalse);
    });
  });
}
