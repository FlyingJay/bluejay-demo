import 'package:flutter_test/flutter_test.dart';
import 'package:projects/models.dart';
import 'package:projects/projects_access.dart';

void main() {
  group('ProjectRecord links', () {
    test('missing fields default to empty', () {
      final project = ProjectRecord.fromMap('p1', {'title': 'Project'});

      expect(project.relatedAppIds, isEmpty);
      expect(project.clientGroupIds, isEmpty);
      expect(project.clientGroupNames, isEmpty);
      expect(project.hasLinks, isFalse);
    });

    test('parses apps, client groups and name snapshots', () {
      final project = ProjectRecord.fromMap('p1', {
        'relatedAppIds': ['rented-dwelling', ' rented-dwelling ', 'quotes'],
        'clientGroupIds': ['globex'],
        'clientGroupNames': {'globex': ' Globex '},
      });

      expect(project.relatedAppIds, ['rented-dwelling', 'quotes']);
      expect(project.clientGroupIds, ['globex']);
      expect(project.clientGroupNames, {'globex': 'Globex'});
      expect(project.hasLinks, isTrue);
      expect(project.clientGroupName('globex'), 'Globex');
    });

    test('tolerates malformed values', () {
      final project = ProjectRecord.fromMap('p1', {
        'relatedAppIds': 'rented-dwelling',
        'clientGroupIds': ['g1', 42, null, '', 'g2'],
        'clientGroupNames': {'g1': 7, 'g2': 'Group Two', '': 'Nameless'},
      });

      expect(project.relatedAppIds, isEmpty);
      expect(project.clientGroupIds, ['g1', 'g2']);
      expect(project.clientGroupNames, {'g2': 'Group Two'});
      expect(project.clientGroupName('g1'), 'g1');
      expect(project.clientGroupName('g2'), 'Group Two');

      expect(ProjectRecord.fromMap('p1', {'clientGroupNames': ['g1']}).clientGroupNames, isEmpty);
    });
  });

  group('BlockerTaskRecord change requests', () {
    test('no change request by default', () {
      final task = BlockerTaskRecord.fromMap('t1', {'title': 'Configure AWS SES'});

      expect(task.changeRequest, isNull);
      expect(task.changeRequestState, isNull);
      expect(task.hasChangeRequest, isFalse);
      expect(task.displayChangeRequestState, isNull);
    });

    test('parses the change request and its state', () {
      final task = BlockerTaskRecord.fromMap('t1', {
        'changeRequest': {'itemType': 'bug', 'itemId': 'b1', 'collection': 'bug_reports'},
        'changeRequestState': 'in_review',
        'prUrl': 'https://github.com/bluejayorg/bluejay/pull/7',
        'prState': 'open',
      });

      expect(task.hasChangeRequest, isTrue);
      expect(task.changeRequest!.itemType, 'bug');
      expect(task.changeRequest!.itemId, 'b1');
      expect(task.changeRequest!.collection, 'bug_reports');
      expect(task.changeRequest!.isBug, isTrue);
      expect(task.changeRequestState, ChangeRequestState.inReview);
      expect(task.pullRequestUri, Uri.parse('https://github.com/bluejayorg/bluejay/pull/7'));
    });

    test('derives a missing or unknown collection from itemType', () {
      expect(
        ChangeRequestRef.tryParse({'itemType': 'feature', 'itemId': 'f1'})!.collection,
        'feature_requests',
      );
      expect(
        ChangeRequestRef.tryParse({'itemType': 'bug', 'itemId': 'b1', 'collection': 'users'})!.collection,
        'bug_reports',
      );
    });

    test('ignores malformed change requests', () {
      expect(ChangeRequestRef.tryParse(null), isNull);
      expect(ChangeRequestRef.tryParse('bug_reports/b1'), isNull);
      expect(ChangeRequestRef.tryParse({'itemType': 'task', 'itemId': 'x'}), isNull);
      expect(ChangeRequestRef.tryParse({'itemType': 'bug'}), isNull);
      expect(ChangeRequestRef.tryParse({'itemType': 'bug', 'itemId': '  '}), isNull);
      expect(ChangeRequestRef.tryParse({'itemType': 'bug', 'itemId': 3}), isNull);

      final task = BlockerTaskRecord.fromMap('t1', {
        'changeRequest': ['bug', 'b1'],
        'changeRequestState': 'in_review',
      });
      expect(task.hasChangeRequest, isFalse);
      expect(task.displayChangeRequestState, isNull);
    });

    test('unknown or missing state on a linked task displays as filed', () {
      final linked = {'itemType': 'feature', 'itemId': 'f1'};
      final unknown = BlockerTaskRecord.fromMap('t1', {'changeRequest': linked, 'changeRequestState': 'weird'});
      final missing = BlockerTaskRecord.fromMap('t2', {'changeRequest': linked});

      expect(unknown.changeRequestState, isNull);
      expect(unknown.displayChangeRequestState, ChangeRequestState.open);
      expect(missing.displayChangeRequestState, ChangeRequestState.open);
    });

    test('maps every server state to its label', () {
      final labels = {
        'open': 'Filed',
        'queued': 'Queued',
        'in_review': 'In review',
        'merged': 'Deploying',
        'resolved': 'Live',
        'closed': 'Closed',
      };
      labels.forEach((raw, label) {
        final state = changeRequestStateFromString(raw);
        expect(state, isNotNull, reason: raw);
        expect(changeRequestStateLabel(state!), label);
      });
      expect(changeRequestStateFromString('inReview'), isNull);
      expect(changeRequestStateFromString(null), isNull);
    });
  });

  group('canCreateChangeRequest', () {
    final unlinked = BlockerTaskRecord.fromMap('t1', {});
    final linked = BlockerTaskRecord.fromMap('t2', {
      'changeRequest': {'itemType': 'feature', 'itemId': 'f1'},
    });

    test('allowed for anyone who can create in the group, not just admins', () {
      final member = ProjectsAccess.fromData({
        'status': 'ACTIVE',
        'entitlements': ['group-1:projects'],
      });

      expect(member.canCreateChangeRequest('group-1', unlinked), isTrue);
      expect(member.canCreateChangeRequest('group-2', unlinked), isFalse);
      expect(member.canCreateChangeRequest(null, unlinked), isFalse);
    });

    test('hidden once the task already has a change request', () {
      final admin = ProjectsAccess.fromData({'status': 'ACTIVE', 'roles': ['admin']});

      expect(admin.canCreateChangeRequest('group-1', unlinked), isTrue);
      expect(admin.canCreateChangeRequest('group-1', linked), isFalse);
    });

    test('denied for inactive users and disabled groups', () {
      expect(
        ProjectsAccess.fromData({
          'status': 'INACTIVE',
          'entitlements': ['group-1:projects:admin'],
        }).canCreateChangeRequest('group-1', unlinked),
        isFalse,
      );
      expect(
        ProjectsAccess.fromData({
          'status': 'ACTIVE',
          'entitlements': ['group-1:projects:admin'],
          'denied_scopes': ['group-1'],
        }).canCreateChangeRequest('group-1', unlinked),
        isFalse,
      );
    });
  });
}
