import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/public_collection.dart';
import 'package:shared_services/scoped_collection.dart';

void main() {
  late FakeFirebaseFirestore fake;

  setUp(() async {
    fake = FakeFirebaseFirestore();
    await fake.doc('public_vendor_market_listings/g1__l1').set({
      'sourceGroupId': 'g1',
      'sourceAppId': 'marketplace-admin',
      'sourceCollection': 'vendor_market_listings',
      'sourceId': 'l1',
      'name': 'Bar',
    });
    await fake.doc('public_vendor_market_listings/g2__l2').set({
      'sourceGroupId': 'g2',
      'sourceId': 'l2',
      'name': 'Band',
    });
  });

  test('resolves the public collection from the generated table', () {
    final catalog = PublicCollection(source: 'vendor_market_listings', appId: 'vendor-marketplace', firestore: fake);
    expect(catalog.name, 'public_vendor_market_listings');
    expect(collectionPolicyFor('public_vendor_market_listings').kind, CollectionKind.public);
    expect(collectionPolicyFor('public_vendor_market_listings').source, 'vendor_market_listings');
    expect(PublicCollection(source: 'files', appId: 'storage').name, 'public_files');
    expect(() => PublicCollection(source: 'notes', appId: 'notes').name, throwsStateError);
  });

  test('reads every group, or one source group, metered', () async {
    final catalog = PublicCollection(source: 'vendor_market_listings', appId: 'vendor-marketplace', firestore: fake);
    expect(catalog.query, isA<MeteredQuery>());
    expect((await catalog.query.get()).docs.map((d) => d.id), ['g1__l1', 'g2__l2']);
    expect((await catalog.whereSourceGroup('g1').get()).docs.map((d) => d.id), ['g1__l1']);
    expect((await catalog.whereSourceGroup('').get()).docs, isEmpty);
    final doc = await catalog.doc('g1', 'l1').get();
    final published = PublishedDoc.fromSnapshot(doc);
    expect(published.sourceId, 'l1');
    expect(published.sourceGroupId, 'g1');
    expect(published.data['name'], 'Bar');
  });

  test('public ids are {sourceGroupId}__{sourceId}', () {
    expect(PublicCollection.publicId('contoso', 'contoso_x'), 'contoso__contoso_x');
    expect(PublicCollection.sourceIdOf('contoso__contoso_x'), 'contoso_x');
    expect(PublishedDoc.fromMap('g__abc', const {}).sourceId, 'abc');
  });
}
