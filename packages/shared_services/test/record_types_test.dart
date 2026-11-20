import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/record_types.dart';
import 'package:shared_services/scoped_collection.dart';
import 'package:shared_services/search_prefixes.dart';

RecordType _type({
  String id = 'crm.deal',
  String appId = 'crm',
  String collection = 'crm_deals',
  RecordSearchBuilder? searchWith,
}) =>
    RecordType(
      id: id,
      appId: appId,
      collection: collection,
      label: 'Deal',
      pluralLabel: 'Deals',
      icon: Icons.handshake_outlined,
      title: (d) => '${d['title'] ?? ''}',
      subtitle: (d) => (d['contact'] as Map?)?['name'] as String?,
      searchWith: searchWith,
      launchArgs: (ref) => {'deal': ref.id},
    );

RecordHit _hit(String title) => RecordHit(
      ref: RecordRef(type: 'crm.deal', appId: 'crm', collection: 'crm_deals', id: title, title: title),
    );

void main() {
  tearDown(RecordTypes.reset);

  group('RecordRef', () {
    test('round-trips through a map, and a line source parses with no title', () {
      const ref = RecordRef(type: 'crm.deal', appId: 'crm', collection: 'crm_deals', id: 'd1', title: 'Spring job');
      expect(RecordRef.fromMap(ref.toMap()), ref);
      expect(ref.path, 'crm_deals/d1');
      final line = RecordRef.fromMap({'appId': 'inventory', 'collection': 'inventory_items', 'id': 'i1'})!;
      expect(line.type, '');
      expect(line.title, '');
      expect(line.path, 'inventory_items/i1');
      expect(RecordRef.fromMap({'appId': 'crm', 'id': 'x'}), isNull);
      expect(RecordRef.fromMap('crm_deals/x'), isNull);
    });

    test('a subcollection record names its parent in the path', () {
      const ref = RecordRef(type: 'a.b', appId: 'a', collection: 'bug_reports/comments', id: 'c1', parentId: 'b1');
      expect(ref.path, 'bug_reports/b1/comments/c1');
      expect(RecordRef.fromMap(ref.toMap()), ref);
    });
  });

  group('RecordTypes.register', () {
    test('registers the real tables\' owners and refuses duplicates', () {
      RecordTypes.register(_type());
      expect(RecordTypes.byId('crm.deal'), isNotNull);
      expect(RecordTypes.forApp('crm').map((t) => t.id), ['crm.deal']);
      expect(() => RecordTypes.register(_type()), throwsStateError);
    });

    test('refuses a malformed id, an app that doesn\'t own the collection, and an unindexed search', () {
      expect(() => RecordTypes.register(_type(id: 'deal')), throwsStateError);
      expect(() => RecordTypes.register(_type(id: 'crm.deal', appId: 'invoices')), throwsStateError);
      expect(() => RecordTypes.register(_type(collection: 'invoicing_documents')), throwsStateError);
      expect(
        () => RecordTypes.register(_type(id: 'crm.setting', collection: 'crm_settings', searchWith: (t) => _NoSearch())),
        throwsStateError,
      );
      expect(RecordTypes.all, isEmpty);
    });

    test('finds a stored reference\'s type by app and collection', () {
      RecordTypes.register(_type());
      const ref = RecordRef(type: '', appId: 'crm', collection: 'crm_deals', id: 'd1');
      expect(RecordTypes.of(ref)?.id, 'crm.deal');
      expect(recordUri(ref, 'acme', origin: Uri.parse('https://bluejay.gg'))?.toString(), 'https://bluejay.gg/acme/crm?deal=d1');
    });
  });

  test('rankRecordHits: exact title, then title prefix, then the rest; capped', () {
    final ranked = rankRecordHits([_hit('Big Smith job'), _hit('Smithers'), _hit('Smith'), _hit('Other')], 'smith', limit: 3);
    expect(ranked.map((h) => h.title), ['Smith', 'Smithers', 'Big Smith job']);
  });

  group('PrefixRecordSearch', () {
    late FakeFirebaseFirestore fake;

    Future<void> seed(String id, Map<String, dynamic> data) => fake.collection('crm_deals').doc(id).set({
          'groupId': 'g1',
          'appId': 'crm',
          ...data,
          searchPrefixesField: searchPrefixesFor(data, fields: ['title', 'contact.name']),
        });

    setUp(() async {
      fake = FakeFirebaseFirestore();
      await seed('d1', {'title': 'Spring renovation', 'contact': {'name': 'Ada Ng'}, 'creatorId': 'u1'});
      await seed('d2', {'title': 'Spring cleaning', 'contact': {'name': 'Bo Li'}, 'creatorId': 'u2'});
      await seed('d3', {'title': 'Spring gone', 'deletedAt': 1});
      await fake.collection('crm_deals').doc('other').set({
        'groupId': 'g2',
        'appId': 'crm',
        'title': 'Spring',
        searchPrefixesField: ['sp', 'spr', 'spri', 'sprin', 'spring'],
      });
    });

    ScopedCollection deals() => ScopedCollection(collection: 'crm_deals', appId: 'crm', firestore: fake, currentUid: () => 'u1');

    test('finds the group\'s live records matching every word', () async {
      final search = PrefixRecordSearch(_type(), deals());
      final hits = await search.find('spring', groupId: 'g1');
      expect(hits.map((h) => h.ref.id).toList()..sort(), ['d1', 'd2']);
      final narrowed = await search.find('Spring ada', groupId: 'g1');
      expect(narrowed.single.ref, const RecordRef(type: 'crm.deal', appId: 'crm', collection: 'crm_deals', id: 'd1', title: 'Spring renovation'));
      expect(narrowed.single.subtitle, 'Ada Ng');
      expect(await search.find('s', groupId: 'g1'), isEmpty);
      expect(await search.find('spring', groupId: ''), isEmpty);
    });

    test('own records only: filters on creatorId', () async {
      final hits = await PrefixRecordSearch(_type(), deals(), ownRecordsOnly: true).find('spring', groupId: 'g1');
      expect(hits.map((h) => h.ref.id), ['d1']);
    });
  });
}

class _NoSearch extends RecordSearch {
  @override
  Future<List<RecordHit>> find(String query, {required String groupId, int limit = defaultRecordSearchLimit}) async => const [];
}
