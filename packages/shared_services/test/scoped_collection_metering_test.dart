import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/active_group_service.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/usage_meter.dart';

/// ScopedCollection meters with no call-site changes.
void main() {
  late FakeFirebaseFirestore fake;

  setUp(() async {
    fake = FakeFirebaseFirestore();
    ActiveGroupService.instance.activeGroupId = 'g1';
    await fake.collection('notes').doc('a').set({'groupId': 'g1', 'appId': 'notes', 'relatedAppId': 'x'});
    await fake.collection('notes').doc('b').set({'groupId': 'g2', 'appId': 'notes', 'relatedAppId': 'x'});
  });

  group('through the default recorder (UsageMeter.instance)', () {
    late ScopedCollection notes;

    num total(String metric) => UsageMeter.instance.pendingEntries
        .fold<num>(0, (sum, e) => sum + (e.apps['notes']?[metric] ?? 0));

    setUp(() async {
      notes = ScopedCollection(collection: 'notes', appId: 'notes', firestore: fake);
      UsageMeter.instance
        ..setUser('u1')
        ..setGroup('g1');
      // Drains earlier tests' counts (the write itself fails: no Firebase app).
      await UsageMeter.instance.flush();
    });

    test('query and queryFor* are metered', () async {
      expect(notes.query, isA<MeteredQuery>());
      final threads = ScopedCollection(
          collection: 'notes',
          appId: 'notes',
          firestore: fake,
          policy: const CollectionPolicy(readerListField: 'ownerIds'));
      expect(threads.queryAsReader('u1'), isA<MeteredQuery>());
      expect(notes.queryForRelatedApp('x'), isA<MeteredQuery>());
      expect(notes.queryAcrossAllGroups(), isA<MeteredQuery>());

      final mine = await notes.query.get();
      expect(mine.docs.map((d) => d.id), ['a']);
      await notes.queryAcrossAllGroups().get();
      expect(total('fsReads'), 1 + 2);
    });

    test('doc() is the plugin\'s own reference', () {
      expect(notes.doc('a').runtimeType, fake.doc('notes/a').runtimeType);
    });
  });

  test('an injected metered instance keeps its recorder, attributed to the collection\'s app', () async {
    final seen = <String>[];
    final metered = MeteredFirestore(
      FirestoreMeteringContext('someone-else', (app, metric, n) => seen.add('$app $metric $n')),
      resolve: () => fake,
    );
    final notes = ScopedCollection(collection: 'notes', appId: 'notes', firestore: metered);
    await notes.query.get();
    expect(seen, ['notes fsReads 1']);
  });

  test('batchSet takes the plain reference doc() returns, in any batch', () async {
    // batchSet resolves the uid through FirebaseAuth, unavailable here, so
    // exercise the batch path it relies on directly.
    final notes = ScopedCollection(collection: 'notes', appId: 'notes', firestore: fake);
    final plain = fake.batch();
    plain.set(notes.doc('c'), {'n': 1});
    await plain.commit();
    final metered = BluejayFirestore.forApp('notes', firestore: fake).batch();
    metered.set(notes.doc('d'), {'n': 1});
    await metered.commit();
    expect((await fake.doc('notes/c').get()).exists, isTrue);
    expect((await fake.doc('notes/d').get()).exists, isTrue);
  });
}
