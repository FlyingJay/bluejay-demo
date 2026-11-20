import 'constants.dart';
import 'models.dart';

class ProjectsAccess {
  final Set<String> roles;
  final Set<String> entitlements;
  final Set<String> deniedScopes;
  final String status;

  const ProjectsAccess({
    this.roles = const {},
    this.entitlements = const {},
    this.deniedScopes = const {},
    this.status = 'INACTIVE',
  });

  factory ProjectsAccess.fromData(Map<String, dynamic>? data) {
    Set<String> readStringSet(Object? raw) {
      if (raw is! List) return const {};
      return raw.whereType<String>().toSet();
    }

    return ProjectsAccess(
      roles: readStringSet(data?['roles']),
      entitlements: readStringSet(data?['entitlements']),
      deniedScopes: readStringSet(data?['denied_scopes']),
      status: data?['status'] as String? ?? 'INACTIVE',
    );
  }

  bool get isPlatformAdmin => roles.contains('admin');

  /// Who sees the legacy Claude dispatch status (agentQueuedAt /
  /// agentDispatchedAt / agentDispatchError) on tasks that were sent straight
  /// to the agent via `projectsTriggerClaudeJob`, before tasks went through
  /// Improve Apps change requests. Active global admins only — the same people
  /// that callable admitted (isActivePlatformAdmin in
  /// functions/_agentic_ticket_dispatch.js). The app no longer calls it.
  bool get canViewLegacyAgentDispatch => isPlatformAdmin && status == 'ACTIVE';

  bool canViewGroup(String? groupId) {
    if (isPlatformAdmin) return true;
    if (!_isGroupActive(groupId)) return false;
    final scope = _scope(groupId!);
    return entitlements.contains(scope) ||
        entitlements.contains('$scope:edit') ||
        entitlements.contains('$scope:admin');
  }

  bool canCreateInGroup(String? groupId) => canViewGroup(groupId);

  /// "Create change request" on [task]: anyone who can create in the group —
  /// mirrors the server-side gate on `projectsCreateChangeRequest` — and only
  /// once per task (the callable rejects a second one with
  /// failed-precondition).
  bool canCreateChangeRequest(String? groupId, BlockerTaskRecord task) =>
      canCreateInGroup(groupId) && !task.hasChangeRequest;

  bool canEditGroup(String? groupId) {
    if (isPlatformAdmin) return true;
    if (!_isGroupActive(groupId)) return false;
    final scope = _scope(groupId!);
    return entitlements.contains('$scope:edit') ||
        entitlements.contains('$scope:admin');
  }

  bool _isGroupActive(String? groupId) {
    return status == 'ACTIVE' &&
        groupId != null &&
        groupId.isNotEmpty &&
        !deniedScopes.contains(groupId);
  }

  String _scope(String groupId) => '$groupId:$APP_ID';
}
