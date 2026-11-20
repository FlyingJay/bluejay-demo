/// Requests to Bluejay to delete data: a person's own account (the Profile
/// screen) or a group's data (Group Admin's Data & privacy section).
///
/// The `dataGovernance*` callables (functions/data_governance.js) keep one
/// open request per account and per group: asking again returns the open
/// one ([DeletionRequestResult.created] is false). Each new request is
/// filed as a ticket on Help Desk's Bluejay desk, where staff work it and
/// move its status along; the requester is notified when it changes.
///
/// ```dart
/// final result = await requestAccountDeletion(reason: reasonController.text);
/// BjSnack.info(context, result.created
///     ? 'Request sent. Bluejay will let you know when it is done.'
///     : 'You already asked: ${result.request.statusLabel}.');
/// ```
library;

import 'package:cloud_functions/cloud_functions.dart' show FirebaseFunctionsException;

import 'cloud_functions.dart';

/// What a deletion request asks to delete.
enum DeletionRequestScope {
  /// The requester's own account.
  account,

  /// A group's data; only its admins ask.
  group,
}

/// One deletion request, as the callables return it.
class DeletionRequest {
  final String requestId;
  final DeletionRequestScope scope;

  /// The group, for a [DeletionRequestScope.group] request.
  final String? groupId;
  final String groupName;

  /// `requested`, `in_progress`, `completed` or `declined`.
  final String status;

  /// Whether Bluejay is still to act on it (requested or in progress).
  final bool open;
  final String reason;

  /// Bluejay's note to the requester, if any.
  final String note;
  final String requesterUid;
  final String requesterName;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const DeletionRequest({
    required this.requestId,
    required this.scope,
    this.groupId,
    this.groupName = '',
    required this.status,
    required this.open,
    this.reason = '',
    this.note = '',
    this.requesterUid = '',
    this.requesterName = '',
    this.createdAt,
    this.updatedAt,
  });

  static DeletionRequest fromData(Map<Object?, Object?> m) {
    DateTime? at(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    String s(Object? v) => v is String ? v : '';
    return DeletionRequest(
      requestId: s(m['requestId']),
      scope: m['scope'] == 'group' ? DeletionRequestScope.group : DeletionRequestScope.account,
      groupId: m['groupId'] is String ? m['groupId'] as String : null,
      groupName: s(m['groupName']),
      status: s(m['status']).isEmpty ? 'requested' : s(m['status']),
      open: m['open'] != false,
      reason: s(m['reason']),
      note: s(m['note']),
      requesterUid: s(m['requesterUid']),
      requesterName: s(m['requesterName']),
      createdAt: at(m['createdAtMs']),
      updatedAt: at(m['updatedAtMs']),
    );
  }

  /// The status in words: "Requested", "In progress", "Completed", "Declined".
  String get statusLabel => switch (status) {
        'requested' => 'Requested',
        'in_progress' => 'In progress',
        'completed' => 'Completed',
        'declined' => 'Declined',
        _ => status,
      };
}

/// What asking for a deletion returned: the request, and whether this call
/// filed it ([created]) or found one already open.
class DeletionRequestResult {
  final bool created;
  final DeletionRequest request;

  const DeletionRequestResult({required this.created, required this.request});

  static DeletionRequestResult fromData(Object? data) {
    final m = data is Map ? data : const {};
    final request = m['request'];
    return DeletionRequestResult(
      created: m['created'] == true,
      request: DeletionRequest.fromData(request is Map ? request : const {}),
    );
  }
}

/// A callable failure, with a message fit to show the user.
class DeletionRequestException implements Exception {
  /// The callable error code (`permission-denied`, `unauthenticated`, ...).
  final String code;
  final String message;

  const DeletionRequestException(this.code, this.message);

  @override
  String toString() => message;
}

/// The deletion request callables. Screens take an instance so tests can
/// pass a fake. Each call names its callable literally through
/// [BluejayCallable.call] (the security tier audit reads only that form).
class DataDeletionRequestsApi {
  const DataDeletionRequestsApi();

  Future<Object?> _call(Future<Object?> pending) async {
    try {
      return await pending;
    } on FirebaseFunctionsException catch (e) {
      final message = (e.message ?? '').trim();
      throw DeletionRequestException(e.code, message.isEmpty ? _fallback(e.code) : message);
    }
  }

  static String _fallback(String code) => switch (code) {
        'permission-denied' => "You can't ask for that.",
        'unauthenticated' => 'Sign in to continue.',
        _ => "Couldn't send the request. Try again.",
      };

  /// Asks Bluejay to delete the signed-in person's account. Anonymous
  /// (guest) sessions are refused.
  Future<DeletionRequestResult> requestAccountDeletion({String? reason}) async =>
      DeletionRequestResult.fromData(await _call(BluejayCallable.call('dataGovernanceRequestDeletion', {
        'scope': 'account',
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      })));

  /// Asks Bluejay to delete [groupId]'s data. Only the group's admins may.
  Future<DeletionRequestResult> requestGroupDeletion(String groupId, {String? reason}) async =>
      DeletionRequestResult.fromData(await _call(BluejayCallable.call('dataGovernanceRequestDeletion', {
        'scope': 'group',
        'groupId': groupId,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      })));

  /// The signed-in person's open account deletion request, or null.
  Future<DeletionRequest?> openAccountRequest() async =>
      _requestFrom(await _call(BluejayCallable.call('dataGovernanceDeletionStatus', {'scope': 'account'})));

  /// [groupId]'s open deletion request, or null (the group's admins only).
  Future<DeletionRequest?> openGroupRequest(String groupId) async => _requestFrom(
      await _call(BluejayCallable.call('dataGovernanceDeletionStatus', {'scope': 'group', 'groupId': groupId})));

  static DeletionRequest? _requestFrom(Object? data) {
    final request = data is Map ? data['request'] : null;
    return request is Map ? DeletionRequest.fromData(request) : null;
  }
}

/// Asks Bluejay to delete the signed-in person's account
/// ([DataDeletionRequestsApi.requestAccountDeletion]).
Future<DeletionRequestResult> requestAccountDeletion({String? reason}) =>
    const DataDeletionRequestsApi().requestAccountDeletion(reason: reason);

/// The signed-in person's open account deletion request, or null
/// ([DataDeletionRequestsApi.openAccountRequest]).
Future<DeletionRequest?> openAccountDeletionRequest() => const DataDeletionRequestsApi().openAccountRequest();
