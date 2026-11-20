import 'package:flutter_test/flutter_test.dart';
import 'package:projects/models.dart';
import 'package:projects/projects_access.dart';

void main() {
  group('ProjectsAccess', () {
    test('grants group view and create for base entitlement', () {
      final access = ProjectsAccess.fromData({
        'status': 'ACTIVE',
        'entitlements': ['group-1:projects'],
      });

      expect(access.canViewGroup('group-1'), isTrue);
      expect(access.canCreateInGroup('group-1'), isTrue);
      expect(access.canEditGroup('group-1'), isFalse);
    });

    test('grants edit for edit entitlement', () {
      final access = ProjectsAccess.fromData({
        'status': 'ACTIVE',
        'entitlements': ['group-1:projects:edit'],
      });

      expect(access.canViewGroup('group-1'), isTrue);
      expect(access.canEditGroup('group-1'), isTrue);
    });

    test('denies disabled groups', () {
      final access = ProjectsAccess.fromData({
        'status': 'ACTIVE',
        'entitlements': ['group-1:projects:admin'],
        'denied_scopes': ['group-1'],
      });

      expect(access.canViewGroup('group-1'), isFalse);
      expect(access.canEditGroup('group-1'), isFalse);
    });
  });

  group('project tags', () {
    test('normalizes and deduplicates tags case-insensitively', () {
      expect(
        normalizeProjectTags([' Urgent ', 'urgent', 'Q3', 'q3 ', '', 4]),
        ['Q3', 'Urgent'],
      );
    });

    test('creates stable natural keys from normalized tag keys', () {
      expect(projectTagNaturalKey(' Urgent Work '), 'urgent%20work');
    });
  });

  group('blocker task sorting', () {
    BlockerTaskRecord task({
      required String id,
      required String title,
      required int priority,
      DateTime? dueDate,
    }) {
      return BlockerTaskRecord(
        id: id,
        projectId: 'project-1',
        title: title,
        description: '',
        parentTaskId: null,
        status: BlockerStatus.todo,
        priority: priority,
        dueDate: dueDate,
        createdAt: null,
        updatedAt: null,
        attachments: const [],
      );
    }

    test('sorts lower priority numbers first', () {
      final tasks = [
        task(id: 'p5', title: 'Low', priority: 5),
        task(id: 'p1', title: 'High', priority: 1),
        task(id: 'p3', title: 'Medium', priority: 3),
      ]..sort(compareBlockerTaskPriority);

      expect(tasks.map((task) => task.priority), [1, 3, 5]);
    });

    test('sorts actionable tasks by priority then due date', () {
      final tasks = [
        task(id: 'later', title: 'Later high priority', priority: 1, dueDate: DateTime(2026, 2, 1)),
        task(id: 'low', title: 'Low priority', priority: 4, dueDate: DateTime(2026, 1, 1)),
        task(id: 'sooner', title: 'Sooner high priority', priority: 1, dueDate: DateTime(2026, 1, 1)),
      ]..sort(compareActionableBlockerTasks);

      expect(tasks.map((task) => task.id), ['sooner', 'later', 'low']);
    });
  });

  group('coding agent dispatch', () {
    test('only active platform admins see legacy agent dispatch status', () {
      expect(
        ProjectsAccess.fromData({'status': 'ACTIVE', 'roles': ['admin']}).canViewLegacyAgentDispatch,
        isTrue,
      );
      expect(
        ProjectsAccess.fromData({'status': 'INACTIVE', 'roles': ['admin']}).canViewLegacyAgentDispatch,
        isFalse,
      );
      expect(
        ProjectsAccess.fromData({
          'status': 'ACTIVE',
          'roles': ['developer'],
          'entitlements': ['group-1:projects:admin'],
        }).canViewLegacyAgentDispatch,
        isFalse,
      );
    });

    test('only exposes https github.com pull request links', () {
      BlockerTaskRecord withPrUrl(String? prUrl) => BlockerTaskRecord(
            id: 'task-1',
            projectId: 'project-1',
            title: 'Task',
            description: '',
            parentTaskId: null,
            status: BlockerStatus.todo,
            priority: 3,
            dueDate: null,
            createdAt: null,
            updatedAt: null,
            attachments: const [],
            prUrl: prUrl,
          );

      expect(
        withPrUrl('https://github.com/bluejayorg/bluejay/pull/12').pullRequestUri,
        Uri.parse('https://github.com/bluejayorg/bluejay/pull/12'),
      );
      expect(withPrUrl('http://github.com/bluejayorg/bluejay/pull/12').pullRequestUri, isNull);
      expect(withPrUrl('https://github.com.evil.example/pull/12').pullRequestUri, isNull);
      expect(withPrUrl('javascript:alert(1)').pullRequestUri, isNull);
      expect(withPrUrl(null).pullRequestUri, isNull);
    });
  });
}
