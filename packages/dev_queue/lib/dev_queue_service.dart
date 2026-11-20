import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_services/idempotency_key.dart';
import 'package:shared_services/scoped_collection.dart';

import 'constants.dart';
import 'dev_queue_metrics.dart';
import 'dev_queue_models.dart';
import 'package:shared_services/cloud_functions.dart';

/// Calls the callable [name] with [data] and returns its result data.
typedef DevQueueCall = Future<Object?> Function(String name, Map<String, Object?> data);

/// Refusals whose copy the design fixes (PHASE_2_DESIGN.md 4,
/// PHASE_2_5_DESIGN.md 8.1). Other refusals carry plain user copy from the
/// server, with a local fallback when it sends none.
const devQueueFixedCopyReasons = {
  'queue-changed',
  'started',
  'going-live',
  'already-reported',
  'too-late',
  'not-live',
  'already-closed',
  'managed',
};

/// A refused queue callable. [reason] is the server's `details.reason`
/// (`queue-changed`, `not-waiting`, `started`, `going-live`, ...) or the
/// HttpsError code when it gives none. [details] is the whole
/// `details` map (`already-reported` names the open item in `itemKey`).
class DevQueueException implements Exception {
  final String reason;
  final String serverMessage;
  final Map<String, Object?> details;

  const DevQueueException(this.reason, [this.serverMessage = '', this.details = const {}]);

  /// `details.itemKey`, when the refusal names an item.
  String? get itemKey {
    final key = details['itemKey'];
    return key is String && key.isNotEmpty ? key : null;
  }

  /// What the person reads in the snackbar.
  String get message {
    if (!devQueueFixedCopyReasons.contains(reason) && serverMessage.isNotEmpty) return serverMessage;
    switch (reason) {
      case 'queue-changed':
        return 'Your queue changed while you were moving things. Try again.';
      case 'started':
        return "We've already started on this, so it can't be edited now. You can ask for a tweak when "
            "it's ready to try, or withdraw it.";
      case 'going-live':
        return "This is already going live, so it can't be withdrawn.";
      case 'already-reported':
        return "You've already reported a problem with this. It's in your queue.";
      case 'too-late':
        return 'This went live more than 30 days ago. Report a problem from the app instead.';
      case 'not-live':
        return "This isn't live yet, so there's nothing to report. You can ask for a tweak when it's ready to try.";
      case 'already-closed':
        return 'This request is already closed.';
      case 'managed':
        return "Your workspace's team looks after this request, so it can't be changed here.";
      case 'not-waiting':
      case 'wrong-kind':
        return 'This request has moved on since you opened it. Pull down to refresh and try again.';
      case 'preview-changed':
        return 'There is a newer version to try. Open it, then approve or ask for a tweak.';
      case 'unauthenticated':
        return 'Sign in again to do this.';
      case 'permission-denied':
        return "You can't change this request.";
      default:
        return serverMessage.isNotEmpty ? serverMessage : 'Something went wrong. Try again.';
    }
  }

  @override
  String toString() => 'DevQueueException($reason): $message';
}

/// Reads a person's queue and calls the queue's callables
/// (functions/dev_queue.js). Widgets take an optional service so tests can
/// pass a fake; everything else uses [instance].
class DevQueueService {
  DevQueueService({
    @visibleForTesting FirebaseFirestore? firestore,
    @visibleForTesting DevQueueCall? call,
    @visibleForTesting String Function()? newKey,
  })  : _firestore = firestore,
        _call = call,
        _newKey = newKey ?? newIdempotencyKey;

  static DevQueueService instance = DevQueueService();

  final FirebaseFirestore? _firestore;
  final DevQueueCall? _call;
  final String Function() _newKey;

  late final ScopedCollection _items = ScopedCollection(
    collection: 'dev_queue_items',
    appId: APP_ID,
    // This service's own test seam passes the fake through.
    // ignore: invalid_use_of_visible_for_testing_member
    firestore: _firestore,
  );

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// The owner's active items in rank order (Now, Up next, the chip).
  /// Managed items are included here; [visibleQueue] drops them.
  Stream<List<DevQueueItem>> watchActive(String uid) {
    return _items
        .queryAsReader(uid)
        .where('active', isEqualTo: true)
        .orderBy('rank')
        .snapshots()
        .map((s) => s.docs.map(DevQueueItem.fromSnapshot).toList());
  }

  /// The owner's 30 most recently finished items, in every group (Shipped
  /// keeps the active group's: [shippedItems]).
  Stream<List<DevQueueItem>> watchFinished(String uid) {
    return _items
        .queryAsReader(uid)
        .where('active', isEqualTo: false)
        .orderBy('stateChangedAt', descending: true)
        .limit(30)
        .snapshots()
        .map((s) => s.docs.map(DevQueueItem.fromSnapshot).toList());
  }

  /// One item. Only its owner can read it; anyone else gets an error.
  Stream<DevQueueItem?> watchItem(String key) {
    return _items.doc(key).snapshots().map((s) => s.exists ? DevQueueItem.fromSnapshot(s) : null);
  }

  // ── Callables ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _invoke(String name, Map<String, Object?> data) async {
    try {
      final call = _call;
      final Object? result;
      if (call != null) {
        result = await call(name, data);
      } else {
        result = (await BluejayFunctions.instance.httpsCallable(name).call<Object?>(data)).data;
      }
      if (result is Map) return result.map((k, v) => MapEntry(k.toString(), v));
      return const {};
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final map = details is Map ? details.map((k, v) => MapEntry(k.toString(), v as Object?)) : <String, Object?>{};
      final reason = map['reason'] is String ? map['reason'] as String : '';
      throw DevQueueException(reason.isNotEmpty ? reason : e.code, e.message ?? '', map);
    }
  }

  /// Saves a new Up next order. [orderedKeys] must be every queued or failed,
  /// non-managed item of the caller, or the server refuses with
  /// `queue-changed`.
  Future<List<String>> reorder(List<String> orderedKeys) async {
    final result = await _invoke('devQueueReorder', {'orderedKeys': orderedKeys});
    final keys = result['orderedKeys'];
    return keys is List ? keys.map((k) => k.toString()).toList() : orderedKeys;
  }

  /// Answers a question. Pass the same [idempotencyKey] to retry the same
  /// answer; a fresh one is made when omitted.
  Future<Map<String, dynamic>> answer(String itemKey, String answer, {String? idempotencyKey}) {
    return _invoke('devQueueAnswer', {
      'itemKey': itemKey,
      'answer': answer.trim(),
      'idempotencyKey': idempotencyKey ?? _newKey(),
    });
  }

  Future<Map<String, dynamic>> approvePreview(String itemKey, String sha) {
    return _invoke('devQueueApprovePreview', {'itemKey': itemKey, 'sha': sha});
  }

  Future<Map<String, dynamic>> requestTweak(String itemKey, String sha, String text, {String? idempotencyKey}) {
    return _invoke('devQueueRequestTweak', {
      'itemKey': itemKey,
      'sha': sha,
      'text': text.trim(),
      'idempotencyKey': idempotencyKey ?? _newKey(),
    });
  }

  /// The managed groups the caller triages; empty for everyone else.
  Future<List<ManagedQueueGroup>> listManaged() async {
    return ManagedQueueGroup.listFromResult(await _invoke('devQueueListManaged', const {}));
  }

  /// Teammates' shipped requests and other groups' changes to [groupId]'s
  /// apps. The caller must be a member.
  Future<GroupShipped> groupShipped(String groupId) async {
    return GroupShipped.fromResult(await _invoke('devQueueGroupShipped', {'groupId': groupId}));
  }

  Future<void> sendToPipeline(String itemType, String itemId) async {
    await _invoke('devQueueSendToPipeline', {'itemType': itemType, 'itemId': itemId});
  }

  // ── Phase 2.5: edit, withdraw, regressions, sizing, metrics ──────────────

  /// The ticket fields the edit sheet prefills, read from the ticket doc
  /// (readable by its owner). Bug: `description`. Idea: `title` and
  /// `description`. App: `title` and `summary`, returned as `description`.
  Future<DevTicketText> readTicketText(String itemType, String itemId) async {
    final collection = devQueueTicketCollection(itemType);
    if (collection == null || itemId.isEmpty) return const DevTicketText();
    final ref = ScopedCollection(
      collection: collection,
      appId: itemType == 'app' ? 'app-maker' : 'improve-apps',
      // ignore: invalid_use_of_visible_for_testing_member
      firestore: _firestore,
    ).doc(itemId);
    final data = (await ref.get()).data() ?? const <String, dynamic>{};
    String text(String field) => data[field] is String ? (data[field] as String).trim() : '';
    switch (itemType) {
      case 'bug':
        return DevTicketText(description: text('description'));
      case 'app':
        return DevTicketText(title: text('title'), description: text('summary'));
      default:
        return DevTicketText(title: text('title'), description: text('description'));
    }
  }

  /// Edits a queued request (`devQueueEditRequest`). Pass only the fields
  /// that changed. Refuses with `started` once work began and
  /// `nothing-changed` for the same text.
  Future<Map<String, dynamic>> editRequest(String itemKey, {String? title, String? description}) {
    return _invoke('devQueueEditRequest', {
      'itemKey': itemKey,
      if (title != null) 'title': title.trim(),
      if (description != null) 'description': description.trim(),
    });
  }

  /// Withdraws a request (`devQueueWithdraw`). A started one refuses with
  /// `already-started` unless [confirmStarted].
  Future<Map<String, dynamic>> withdraw(String itemKey, {bool confirmStarted = false}) {
    return _invoke('devQueueWithdraw', {
      'itemKey': itemKey,
      if (confirmStarted) 'confirmStarted': true,
    });
  }

  /// Reports that a live item broke something (`devQueueReportRegression`).
  /// Returns the new regression item's key; a repeat with the same
  /// [idempotencyKey] returns the same key.
  Future<String?> reportRegression(String itemKey, String description, {String? idempotencyKey}) async {
    final result = await _invoke('devQueueReportRegression', {
      'itemKey': itemKey,
      'description': description.trim(),
      'idempotencyKey': idempotencyKey ?? _newKey(),
    });
    final key = result['itemKey'];
    return key is String && key.isNotEmpty ? key : null;
  }

  /// Sets a request's size (`devQueueSetSize`, platform admins). [targetDate]
  /// goes with Large only.
  Future<Map<String, dynamic>> setSize(String itemKey, String size, {DateTime? targetDate}) {
    return _invoke('devQueueSetSize', {
      'itemKey': itemKey,
      'size': size,
      if (size == 'L' && targetDate != null) 'targetDate': formatIsoDay(targetDate),
    });
  }

  /// Throughput and stalls (`devQueueMetrics`, platform admins).
  Future<DevQueueMetrics> metrics({int weeks = 8}) async {
    return DevQueueMetrics.fromResult(await _invoke('devQueueMetrics', {'weeks': weeks.clamp(1, 26)}));
  }

  /// A fresh idempotency key, for a box that keeps one per draft.
  String newKey() => _newKey();
}

/// The ticket collection for an item type, or null for one with no ticket
/// the requester edits.
String? devQueueTicketCollection(String itemType) {
  switch (itemType) {
    case 'bug':
      return 'bug_reports';
    case 'feature':
      return 'feature_requests';
    case 'app':
      return 'app_requests';
    default:
      return null;
  }
}

/// The text of a ticket as the edit sheet shows it.
class DevTicketText {
  final String title;
  final String description;

  const DevTicketText({this.title = '', this.description = ''});
}

/// `YYYY-MM-DD` for [day]'s local date.
String formatIsoDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
