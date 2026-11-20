/// Record types: what a contact, deal, invoice, item or ticket is called,
/// how to find one and how to open one, registered once per app
/// (plans/record-search/OVERVIEW.md §3). The launcher's search finds
/// records through these registrations; linked records (phase 2) will
/// store a [RecordRef] and open it with [openRecord].
///
/// Each app package exports its [RecordType]s; the root app registers them
/// at startup (lib/routing/record_types.dart). How a search runs is behind
/// [RecordSearch], so a server index can replace the per-type Firestore
/// query ([PrefixRecordSearch]) without touching registrations or the tray.
library;

import 'package:firebase_auth/firebase_auth.dart' as fire_auth;
import 'package:flutter/material.dart';

import 'app_launch_bridge.dart';
import 'group_app_links.dart';
import 'scoped_collection.dart';
import 'search_prefixes.dart';

/// A pointer to one record, safe to store on another document. Its
/// `appId`, `collection`, `id` and `parentId` are the same fields record
/// history and the audit trail name a record by (`collection`, `docId`,
/// `parentDocId`); a stored line source (`{appId, collection, id}`) parses
/// as one with no type or title.
@immutable
class RecordRef {
  const RecordRef({
    required this.type,
    required this.appId,
    required this.collection,
    required this.id,
    this.parentId,
    this.title = '',
  });

  /// The [RecordType.id], `'<appId>.<noun>'` (`'crm.deal'`).
  final String type;
  final String appId;

  /// The top-level collection, or the policy key (`'parent/sub'`) of a
  /// subcollection record.
  final String collection;
  final String id;

  /// The parent doc of a subcollection record.
  final String? parentId;

  /// The record's title when the reference was made (a snapshot).
  final String title;

  /// The record's document path (`'crm_deals/abc'`).
  String get path {
    final parts = collection.split('/');
    if (parentId != null && parts.length == 2) return '${parts[0]}/$parentId/${parts[1]}/$id';
    return '$collection/$id';
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'appId': appId,
        'collection': collection,
        'id': id,
        if (parentId != null) 'parentId': parentId,
        'title': title,
      };

  /// The reference stored in [raw], or null when it names no record.
  static RecordRef? fromMap(Object? raw) {
    if (raw is! Map) return null;
    String s(String key) => raw[key] is String ? (raw[key] as String).trim() : '';
    final appId = s('appId');
    final collection = s('collection');
    final id = s('id');
    if (appId.isEmpty || collection.isEmpty || id.isEmpty) return null;
    final parentId = s('parentId');
    return RecordRef(
      type: s('type'),
      appId: appId,
      collection: collection,
      id: id,
      parentId: parentId.isEmpty ? null : parentId,
      title: s('title'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecordRef &&
      other.type == type &&
      other.appId == appId &&
      other.collection == collection &&
      other.id == id &&
      other.parentId == parentId &&
      other.title == title;

  @override
  int get hashCode => Object.hash(type, appId, collection, id, parentId, title);

  @override
  String toString() => 'RecordRef($type, $path)';
}

/// One search result: the record and the line under its title.
@immutable
class RecordHit {
  const RecordHit({required this.ref, this.subtitle});

  final RecordRef ref;
  final String? subtitle;

  String get title => ref.title;
}

/// How a record type is searched. Runs as the signed-in person, so the
/// rules (or, for a server-read collection, the callable's checks) decide
/// what they can find.
abstract class RecordSearch {
  const RecordSearch();

  /// Up to [limit] records in [groupId] matching [query], unranked.
  Future<List<RecordHit>> find(String query, {required String groupId, int limit = defaultRecordSearchLimit});
}

/// How many records one search reads per type.
const int defaultRecordSearchLimit = 8;

/// Builds a type's [RecordSearch]; it gets the type to build hits with.
typedef RecordSearchBuilder = RecordSearch Function(RecordType type);

/// A kind of record an app owns, registered once with [RecordTypes].
class RecordType {
  RecordType({
    required this.id,
    required this.appId,
    required this.collection,
    required this.label,
    required this.pluralLabel,
    required this.icon,
    required this.title,
    this.subtitle,
    this.searchWith,
    required this.launchArgs,
  });

  /// `'<appId>.<noun>'`, the way automations names its events (`'crm.deal'`).
  final String id;

  /// The app that owns and opens it.
  final String appId;

  /// Its collection; the policy table decides scope and rules.
  final String collection;

  /// What one is called (`'Deal'`), and several (`'Deals'`).
  final String label;
  final String pluralLabel;
  final IconData icon;

  /// The record's title from its data.
  final String Function(Map<String, dynamic> data) title;

  /// The line under the title (a contact's organization, an item's SKU).
  final String? Function(Map<String, dynamic> data)? subtitle;

  /// How it is searched; null when it can only be opened and linked.
  final RecordSearchBuilder? searchWith;

  /// The launch args that open one record in [appId] (`{'deal': ref.id}`);
  /// each key is written once, here.
  final Map<String, String> Function(RecordRef ref) launchArgs;

  /// This type's search, or null.
  late final RecordSearch? search = searchWith?.call(this);

  /// A reference to record [id] with [data].
  RecordRef refOf(String id, Map<String, dynamic> data, {String? parentId}) => RecordRef(
        type: this.id,
        appId: appId,
        collection: collection,
        id: id,
        parentId: parentId,
        title: title(data),
      );

  /// A search hit for record [id] with [data].
  RecordHit hitOf(String id, Map<String, dynamic> data) =>
      RecordHit(ref: refOf(id, data), subtitle: subtitle?.call(data));
}

/// The registry of every app's record types.
class RecordTypes {
  RecordTypes._();

  static final Map<String, RecordType> _types = {};

  static final RegExp _idPattern = RegExp(r'^[a-z0-9-]+\.[a-z0-9_]+$');

  /// Registers [type]. Throws [StateError] when its id is taken or
  /// malformed, its app doesn't own its collection in the policy table, or
  /// it searches a collection with no `search` block.
  static void register(RecordType type, {CollectionPolicy Function(String collection) policyOf = collectionPolicyFor}) {
    if (!_idPattern.hasMatch(type.id) || !type.id.startsWith('${type.appId}.')) {
      throw StateError('Record type "${type.id}" must be named "<appId>.<noun>" for app "${type.appId}"');
    }
    if (_types.containsKey(type.id)) throw StateError('Record type "${type.id}" is registered twice');
    final policy = policyOf(type.collection.split('/').first);
    if (!policy.apps.contains(type.appId)) {
      throw StateError('Record type "${type.id}": app "${type.appId}" doesn\'t own "${type.collection}" in security/collections.json');
    }
    if (type.searchWith != null && !policy.searchable) {
      throw StateError('Record type "${type.id}" searches "${type.collection}", which has no search block in security/collections.json');
    }
    _types[type.id] = type;
  }

  /// Registers each of [types].
  static void registerAll(Iterable<RecordType> types) => types.forEach(register);

  static RecordType? byId(String id) => _types[id];

  /// [appId]'s record types, in registration order.
  static List<RecordType> forApp(String appId) => [
        for (final t in _types.values)
          if (t.appId == appId) t,
      ];

  /// Every registered type, in registration order.
  static List<RecordType> get all => List.unmodifiable(_types.values);

  /// The type that opens [ref]: its own, else the one for its app and
  /// collection (a reference stored with no type).
  static RecordType? of(RecordRef ref) =>
      _types[ref.type] ??
      _types.values.where((t) => t.appId == ref.appId && t.collection == ref.collection).firstOrNull;

  @visibleForTesting
  static void reset() => _types.clear();
}

/// Opens [ref] in its app through [AppLaunchBridge], so the app's admin
/// gate, usage session and help shell wrap it as on every other launch.
/// Resolves to false when the record's type isn't registered or the app
/// can't be opened.
Future<bool> openRecord(BuildContext context, RecordRef ref, {fire_auth.User? user}) async {
  final type = RecordTypes.of(ref);
  if (type == null) return false;
  return AppLaunchBridge.openApp(
    context,
    ref.appId,
    user ?? _signedInUser(),
    args: type.launchArgs(ref),
  );
}

fire_auth.User? _signedInUser() {
  try {
    return fire_auth.FirebaseAuth.instance.currentUser;
  } catch (_) {
    return null; // Firebase isn't initialized (a test).
  }
}

/// A link that opens [ref] in group [groupId] (`/{groupId}/{appId}?...`),
/// or null when its type isn't registered.
Uri? recordUri(RecordRef ref, String groupId, {Uri? origin}) {
  final type = RecordTypes.of(ref);
  if (type == null) return null;
  return groupAppUri(groupId, ref.appId, args: type.launchArgs(ref), origin: origin);
}

/// [hits] ranked for [query] and cut to [limit]: an exact title first,
/// then titles that start with the query, then the rest, each in the order
/// found.
List<RecordHit> rankRecordHits(List<RecordHit> hits, String query, {int limit = 5}) {
  final q = foldSearchText(query.trim());
  int rank(RecordHit hit) {
    final title = foldSearchText(hit.title.trim());
    if (title == q) return 0;
    if (title.startsWith(q)) return 1;
    return 2;
  }

  final ranked = [for (var i = 0; i < hits.length; i++) (i: i, rank: rank(hits[i]), hit: hits[i])]
    ..sort((a, b) => a.rank != b.rank ? a.rank - b.rank : a.i - b.i);
  return [for (final r in ranked.take(limit)) r.hit];
}

/// Phase 1's search: one Firestore query per type, run as the signed-in
/// person, on the server-maintained `searchPrefixes`
/// (`array-contains` the query's most selective term), with the query's
/// other terms matched against the records it returns.
class PrefixRecordSearch extends RecordSearch {
  PrefixRecordSearch(this.type, this.collection, {this.ownRecordsOnly = false});

  final RecordType type;
  final ScopedCollection collection;

  /// For an `ownerScoped` collection: search only the person's own records
  /// (`creatorId ==`), the shape the rules prove.
  final bool ownRecordsOnly;

  @override
  Future<List<RecordHit>> find(String query, {required String groupId, int limit = defaultRecordSearchLimit}) async {
    final terms = searchTerms(query);
    final term = primarySearchTerm(terms);
    if (term == null || groupId.isEmpty) return const [];
    final base = ownRecordsOnly ? collection.queryCreatedInGroup(groupId) : collection.queryInGroup(groupId);
    final snap = await base.where(searchPrefixesField, arrayContains: term).limit(limit).get();
    return [
      for (final doc in snap.docs)
        if (!ScopedCollection.isSoftDeleted(doc.data()) && matchesAllSearchTerms(doc.data()[searchPrefixesField], terms))
          type.hitOf(doc.id, doc.data()),
    ];
  }
}
