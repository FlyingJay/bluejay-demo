import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_services/cloud_functions.dart';

import 'automations_models.dart';

/// Everything the Automations app and [AutomationsPanel] read and change.
/// Rules are server data (`automations`, `automation_runs`), so the client
/// never reads Firestore for them: every call goes through the
/// `automations*` callables (functions/automations.js), which check who may
/// see and manage what. Screens take an instance so tests can pass a fake.
class AutomationsApi {
  const AutomationsApi();

  Future<AutomationsCatalog> catalog(String groupId) async =>
      AutomationsCatalog.fromData(await _guard(() => BluejayCallable.call('automationsCatalog', {'groupId': groupId})));

  /// The group's rules and built-ins; [appId] narrows both to one app.
  Future<AutomationsListing> list(String groupId, {String? appId}) async =>
      AutomationsListing.fromData(await _guard(() => BluejayCallable.call('automationsList', {
            'groupId': groupId,
            if (appId != null && appId.isNotEmpty) 'appId': appId,
          })));

  /// Creates a rule (no [ruleId]) or replaces one. Returns the rule's id.
  /// Throws [AutomationsException] with [AutomationsException.problems]
  /// when the server finds the rule invalid.
  Future<String> save(String groupId, Map<String, dynamic> rule, {String? ruleId}) async {
    final data = await _guard(() => BluejayCallable.call('automationsSave', {
          'groupId': groupId,
          if (ruleId != null && ruleId.isNotEmpty) 'ruleId': ruleId,
          'rule': rule,
        }));
    return data is Map ? '${data['ruleId'] ?? ''}' : '';
  }

  Future<void> delete(String groupId, String ruleId) =>
      _guard(() => BluejayCallable.call('automationsDelete', {'groupId': groupId, 'ruleId': ruleId}));

  Future<bool> setEnabled(String groupId, String ruleId, bool enabled) async {
    final data = await _guard(() => BluejayCallable.call('automationsSetEnabled', {
          'groupId': groupId,
          'ruleId': ruleId,
          'enabled': enabled,
        }));
    return data is Map && data['enabled'] is bool ? data['enabled'] as bool : enabled;
  }

  /// Turns a built-in on or off and/or changes its adjustable fields.
  Future<BuiltInAutomation> setBuiltIn(
    String groupId,
    String builtInId, {
    bool? enabled,
    Map<String, dynamic>? adjust,
  }) async {
    final data = await _guard(() => BluejayCallable.call('automationsSetBuiltIn', {
          'groupId': groupId,
          'builtInId': builtInId,
          if (enabled != null) 'enabled': enabled,
          if (adjust != null) 'adjust': adjust,
        }));
    return BuiltInAutomation.fromData(data);
  }

  Future<AutomationRunsPage> runs(
    String groupId, {
    String? ruleId,
    String? status,
    int limit = 25,
    String? startAfter,
  }) async =>
      AutomationRunsPage.fromData(await _guard(() => BluejayCallable.call('automationsRuns', {
            'groupId': groupId,
            if (ruleId != null && ruleId.isNotEmpty) 'ruleId': ruleId,
            if (status != null && status.isNotEmpty) 'status': status,
            'limit': limit,
            if (startAfter != null && startAfter.isNotEmpty) 'startAfter': startAfter,
          })));

  /// The group's members, for choosing who a step tells (read-only).
  Future<List<AutomationMember>> members(String groupId) async {
    final data = await _guard(() => BluejayCallable.call('automationsMembers', {'groupId': groupId}));
    final rows = data is Map ? data['members'] : null;
    return [for (final m in (rows is List ? rows : const [])) AutomationMember.fromData(m)]
      ..removeWhere((m) => m.uid.isEmpty);
  }

  /// Queues a failed run to run again (it runs a moment later). Returns
  /// its new status, `queued`.
  Future<String> retry(String groupId, String runId) async {
    final data = await _guard(() => BluejayCallable.call('automationsRetry', {'groupId': groupId, 'runId': runId}));
    return data is Map ? '${data['status'] ?? ''}' : '';
  }

  static Future<Object?> _guard(Future<Object?> Function() call) async {
    try {
      return await call();
    } on FirebaseFunctionsException catch (e) {
      throw AutomationsException.fromFunctions(e);
    }
  }
}

/// A callable error with its code, a message to show and, for a rule the
/// server refused, the list of problems (`details.problems`). Every
/// callable failure surfaces as one of these, as Group Admin's
/// `GroupAdminException` does.
class AutomationsException implements Exception {
  final String code;
  final String message;
  final List<String> problems;
  const AutomationsException(this.code, this.message, {this.problems = const []});

  factory AutomationsException.fromFunctions(FirebaseFunctionsException e) {
    final authored = _authoredCodes.contains(e.code) && (e.message ?? '').trim().isNotEmpty;
    return AutomationsException(
      e.code,
      authored ? e.message!.trim() : _fallbackFor(e.code),
      problems: problemsFromDetails(e.details),
    );
  }

  bool get isPermissionDenied => code == 'permission-denied' || code == 'unauthenticated';

  @override
  String toString() => message;
}

/// Codes whose message the automations callables write for the user.
const _authoredCodes = {
  'invalid-argument',
  'failed-precondition',
  'not-found',
  'already-exists',
  'permission-denied',
  'resource-exhausted',
  'out-of-range',
};

String _fallbackFor(String code) => switch (code) {
      'unavailable' || 'deadline-exceeded' => 'Couldn\'t reach Bluejay. Check your connection and try again.',
      'unauthenticated' => 'Sign in again to continue.',
      _ => _somethingWrong,
    };

const _somethingWrong = 'Something went wrong. Check your connection and try again.';
const _managersOnly = 'Only group admins and app admins can change automations.';

/// The `problems` list in a callable error's details, as strings.
List<String> problemsFromDetails(Object? details) {
  final list = details is Map ? details['problems'] : (details is List ? details : null);
  return [for (final p in (list is List ? list : const [])) if (p != null) '$p'];
}

/// Whether [error] means the caller may not manage automations here.
bool isAutomationsPermissionDenied(Object? error) {
  if (error is AutomationsException) return error.isPermissionDenied;
  if (error is FirebaseFunctionsException) return error.code == 'permission-denied' || error.code == 'unauthenticated';
  return false;
}

/// A plain sentence for an error from these callables.
String automationsErrorMessage(Object? error) {
  if (isAutomationsPermissionDenied(error)) return _managersOnly;
  if (error is AutomationsException) {
    return error.problems.isNotEmpty ? 'Some parts of this automation need fixing.' : error.message;
  }
  if (error is FirebaseFunctionsException) return AutomationsException.fromFunctions(error).message;
  return _somethingWrong;
}
