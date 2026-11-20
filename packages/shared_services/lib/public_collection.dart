import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'bluejay_firestore.dart';
import 'generated/collection_policies.g.dart';
import 'package:shared_services/cloud_functions.dart';

/// One published projection read from a [PublicCollection]: the source
/// doc's identity plus the fields the table's `projection` publishes.
class PublishedDoc {
  const PublishedDoc({
    required this.publicId,
    required this.sourceGroupId,
    required this.sourceAppId,
    required this.sourceCollection,
    required this.sourceId,
    required this.data,
  });

  /// The public doc's id: `{sourceGroupId}__{sourceId}`.
  final String publicId;

  /// The group that published it.
  final String sourceGroupId;
  final String sourceAppId;
  final String sourceCollection;

  /// The tenant doc's id: what the rest of the app (favorites, threads,
  /// category references) calls this item.
  final String sourceId;

  /// The whole published doc: the projected fields plus the source fields.
  final Map<String, dynamic> data;

  static PublishedDoc fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap) =>
      fromMap(snap.id, snap.data() ?? const <String, dynamic>{});

  static PublishedDoc fromMap(String publicId, Map<String, dynamic> data) {
    String str(String key) => data[key] is String ? data[key] as String : '';
    final sourceId = str('sourceId');
    final sourceGroupId = str('sourceGroupId');
    return PublishedDoc(
      publicId: publicId,
      sourceGroupId: sourceGroupId,
      sourceAppId: str('sourceAppId'),
      sourceCollection: str('sourceCollection'),
      // A doc without its source fields (shouldn't happen; only the server
      // writes these) falls back to its own id's parts.
      sourceId: sourceId.isNotEmpty ? sourceId : PublicCollection.sourceIdOf(publicId),
      data: data,
    );
  }
}

/// The public namespace (plans/firestore-rules §2.7, D2): published,
/// cross-group projections of a tenant collection.
///
/// Tenant docs are readable only inside their group, whatever they say
/// (the rules ignore `visibility`). A collection whose docs other groups must
/// see (a marketplace catalog, a file shared publicly) declares
/// `publishTo: "public_<collection>"` in security/collections.json; its
/// owners [publish] a doc, and the server (functions/public_namespace.js)
/// writes a projection — only the table's `projection` fields — to
/// `public_<collection>/{sourceGroupId}__{sourceId}`, copying its files under
/// `published/` ([ScopedStorage.published]). Any signed-in user reads those
/// docs; no client writes them. Edits to the source re-sync the projection,
/// and deleting it (or making it no longer publishable) unpublishes it.
///
/// ```dart
/// final _catalog = PublicCollection(source: 'vendor_market_listings', appId: 'vendor-marketplace');
///
/// _catalog.whereSourceGroup(operatorGroupId).snapshots();   // read, from any group
/// await _catalog.publish(listingId);                         // owner/staff, in the source's group
/// ```
///
/// Reads need no group filter: the rules prove a public read on the
/// collection alone. [whereSourceGroup] narrows to one publisher.
class PublicCollection {
  PublicCollection({
    required this.source,
    required this.appId,
    @visibleForTesting FirebaseFirestore? firestore,
    @visibleForTesting FirebaseFunctions? functions,
    @visibleForTesting CollectionPolicy? policy,
  })  : _firestore = firestore,
        _functions = functions,
        _policy = policy;

  /// The tenant collection whose published docs this reads.
  final String source;

  /// The app the reads are metered against (the reading app).
  final String appId;

  final FirebaseFirestore? _firestore;
  final FirebaseFunctions? _functions;
  final CollectionPolicy? _policy;

  static const String _noGroupSentinel = '__no_group__';

  /// The public collection's name, from the generated policy table
  /// (`publishTo`). Throws if [source] doesn't publish.
  String get name {
    final target = (_policy ?? collectionPolicyFor(source)).publishTo;
    if (target == null || target.isEmpty) {
      throw StateError(
          '"$source" has no public namespace: declare publishTo in security/collections.json');
    }
    return target;
  }

  CollectionReference<Map<String, dynamic>> get _ref =>
      BluejayFirestore.forApp(appId, firestore: _firestore).collection(name);

  FirebaseFunctions get _fns => _functions ?? BluejayFunctions.instance;

  /// `{sourceGroupId}__{sourceId}`, the public doc id of a source doc.
  static String publicId(String sourceGroupId, String sourceId) =>
      '${sourceGroupId}__$sourceId';

  /// The source id in a public doc id (everything after the first `__`).
  static String sourceIdOf(String publicId) {
    final i = publicId.indexOf('__');
    return i < 0 ? publicId : publicId.substring(i + 2);
  }

  /// Every published doc, from every group.
  Query<Map<String, dynamic>> get query => _ref;

  /// The docs [sourceGroupId] published. An empty id matches nothing.
  Query<Map<String, dynamic>> whereSourceGroup(String sourceGroupId) =>
      _ref.where('sourceGroupId',
          isEqualTo: sourceGroupId.isEmpty ? _noGroupSentinel : sourceGroupId);

  /// The published projection of [sourceId] in [sourceGroupId] (it may not
  /// exist: not published, or unpublished).
  DocumentReference<Map<String, dynamic>> doc(
          String sourceGroupId, String sourceId) =>
      _ref.doc(publicId(sourceGroupId, sourceId));

  /// Publishes (or re-publishes) tenant doc [sourceId] through the
  /// `publicPublish` callable. The caller needs the table's `publishTier` on
  /// it in its own group; the server validates it and decides what is
  /// published.
  Future<void> publish(String sourceId) => _fns
      .httpsCallable('publicPublish')
      .call<Object?>({'collection': source, 'id': sourceId});

  /// Removes tenant doc [sourceId]'s projection and published files.
  Future<void> unpublish(String sourceId) => _fns
      .httpsCallable('publicUnpublish')
      .call<Object?>({'collection': source, 'id': sourceId});
}
