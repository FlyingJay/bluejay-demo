import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_services/bluejay_firestore.dart';
import 'package:shared_services/cloud_functions.dart';

/// Calls the callable [name] with [data] and returns its result data.
typedef FeatureSuggestionCall = Future<Object?> Function(String name, Map<String, Object?> data);

/// One feature the server offers a person for an app they use a lot
/// (`feature_suggestions/{uid}.offer`, written by the nightly job).
class FeatureSuggestionOffer {
  final String offerId;

  /// The routing app id, e.g. `notes`.
  final String appId;

  /// The app's display name, e.g. `Notes`.
  final String appName;

  /// The group the request would be filed in.
  final String groupId;

  /// A short name for the feature.
  final String title;

  /// One or two plain sentences about what it does.
  final String pitch;

  /// Not shown before this. Null shows it right away.
  final DateTime? showAfter;

  /// Not shown from this time on. An offer without one is never shown.
  final DateTime? expiresAt;

  const FeatureSuggestionOffer({
    required this.offerId,
    required this.appId,
    required this.appName,
    required this.groupId,
    required this.title,
    required this.pitch,
    this.showAfter,
    this.expiresAt,
  });

  /// The offer in [data] (the `offer` field), or null when there is none or
  /// it lacks what the prompt needs (an id, a group and a title).
  static FeatureSuggestionOffer? fromData(Object? data) {
    if (data is! Map) return null;
    final offerId = _str(data['offerId']);
    final groupId = _str(data['groupId']);
    final title = _str(data['title']);
    if (offerId.isEmpty || groupId.isEmpty || title.isEmpty) return null;
    final appId = _str(data['appId']);
    final appName = _str(data['appName']);
    return FeatureSuggestionOffer(
      offerId: offerId,
      appId: appId,
      appName: appName.isNotEmpty ? appName : appId,
      groupId: groupId,
      title: title,
      pitch: _str(data['pitch']),
      showAfter: _date(data['showAfter']),
      expiresAt: _date(data['expiresAt']),
    );
  }

  /// The offer in a `feature_suggestions/{uid}` document's data.
  static FeatureSuggestionOffer? fromDocData(Map<String, dynamic>? doc) => fromData(doc?['offer']);
}

/// Whether `users/{uid}.notificationSettings` allows feature suggestions.
/// On unless `featureSuggestions` is exactly false.
bool featureSuggestionsEnabled(Object? notificationSettings) {
  if (notificationSettings is! Map) return true;
  return notificationSettings['featureSuggestions'] != false;
}

/// Whether the launcher should offer [offer] now: it is due ([now] is at or
/// after its showAfter and before its expiresAt), it belongs to the active
/// group, the person is signed in with an account and hasn't turned
/// suggestions off.
bool shouldShowFeatureSuggestion({
  required FeatureSuggestionOffer? offer,
  required DateTime now,
  required String? activeGroupId,
  required bool isGuest,
  required bool suggestionsEnabled,
}) {
  if (offer == null || isGuest || !suggestionsEnabled) return false;
  if (activeGroupId == null || activeGroupId.isEmpty || offer.groupId != activeGroupId) return false;
  final showAfter = offer.showAfter;
  if (showAfter != null && now.isBefore(showAfter)) return false;
  final expiresAt = offer.expiresAt;
  if (expiresAt == null || !now.isBefore(expiresAt)) return false;
  return true;
}

/// What the person did with an offer (`featureSuggestionRespond`'s action).
enum FeatureSuggestionAction {
  /// "Yes, add it": the server files the request into their queue.
  accept,

  /// "Not this one".
  decline,

  /// Closed without choosing.
  later,

  /// "Don't ask me again": the server also turns suggestions off.
  stop;

  String get wireName => name;
}

/// What `featureSuggestionRespond` returns.
class FeatureSuggestionResult {
  /// The filed request's id, for an accepted offer.
  final String? requestId;

  /// Where the request sits in the person's queue, for an accepted offer.
  final int? queuePosition;

  const FeatureSuggestionResult({this.requestId, this.queuePosition});

  factory FeatureSuggestionResult.fromData(Object? data) {
    if (data is! Map) return const FeatureSuggestionResult();
    final requestId = _str(data['requestId']);
    final position = data['queuePosition'];
    return FeatureSuggestionResult(
      requestId: requestId.isEmpty ? null : requestId,
      queuePosition: position is num ? position.toInt() : null,
    );
  }
}

/// A refused `featureSuggestionRespond`, with a message to show.
class FeatureSuggestionException implements Exception {
  /// The HttpsError code (`failed-precondition`, `unavailable`, ...).
  final String code;
  final String message;

  const FeatureSuggestionException(this.code, this.message);

  @override
  String toString() => 'FeatureSuggestionException($code): $message';
}

/// Reads a person's feature suggestion and sends their answer
/// (functions: `featureSuggestionRespond`). Widgets take an optional service
/// so tests can pass a fake; everything else uses [instance].
class FeatureSuggestionService {
  FeatureSuggestionService({
    @visibleForTesting FirebaseFirestore? firestore,
    @visibleForTesting FeatureSuggestionCall? call,
  })  : _firestore = firestore,
        _call = call;

  static FeatureSuggestionService instance = FeatureSuggestionService();

  final FirebaseFirestore? _firestore;
  final FeatureSuggestionCall? _call;

  // The launcher shows the prompt, so it carries the reads.
  FirebaseFirestore get _db => BluejayFirestore.forApp(launcherAppId, firestore: _firestore);

  /// The person's current offer, or null when there is none.
  Future<FeatureSuggestionOffer?> readOffer(String uid) async {
    final snap = await _db.collection('feature_suggestions').doc(uid).get();
    return FeatureSuggestionOffer.fromDocData(snap.data());
  }

  /// Whether the person allows feature suggestions
  /// (`users/{uid}.notificationSettings.featureSuggestions`, on by default).
  Future<bool> readEnabled(String uid) async {
    final snap = await _db.collection('users').doc(uid).get();
    return featureSuggestionsEnabled(snap.data()?['notificationSettings']);
  }

  /// Sends what the person did with offer [offerId].
  Future<FeatureSuggestionResult> respond(String offerId, FeatureSuggestionAction action) async {
    final data = <String, Object?>{'offerId': offerId, 'action': action.wireName};
    try {
      final call = _call;
      final result = call != null
          ? await call('featureSuggestionRespond', data)
          : await BluejayCallable.call('featureSuggestionRespond', data);
      return FeatureSuggestionResult.fromData(result);
    } on FirebaseFunctionsException catch (e) {
      final message = (e.message ?? '').trim();
      throw FeatureSuggestionException(e.code, message.isEmpty ? _fallbackMessage(e.code) : message);
    }
  }

  static String _fallbackMessage(String code) => switch (code) {
        'failed-precondition' || 'not-found' => 'This suggestion is no longer available.',
        'unauthenticated' => 'Sign in again to do this.',
        _ => 'Something went wrong. Try again.',
      };
}

String _str(Object? raw) => raw is String ? raw.trim() : '';

DateTime? _date(Object? raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  if (raw is String) return DateTime.tryParse(raw)?.toLocal();
  if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
  if (raw is Map) {
    final seconds = raw['_seconds'] ?? raw['seconds'];
    if (seconds is num) return DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  }
  return null;
}
