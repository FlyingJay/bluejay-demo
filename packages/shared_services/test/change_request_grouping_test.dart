import 'package:flutter_test/flutter_test.dart';
import 'package:shared_services/change_request_grouping.dart';

ChangeRequestSummary _bug(
  String id, {
  String appId = 'rented-dwelling',
  Map<String, dynamic> extra = const {},
}) =>
    ChangeRequestSummary.fromData(
      itemType: 'bug',
      itemId: id,
      data: {
        'description': 'Bug $id\nmore detail',
        'relatedAppId': appId,
        ...extra,
      },
    );

void main() {
  group('change request state labels', () {
    test('maps every server state to its label', () {
      const labels = {
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

  group('ParentRequestRef.fromData', () {
    test('parses the server-written parentRequest', () {
      final ref = ParentRequestRef.fromData({
        'itemType': 'feature',
        'itemId': 'p1',
        'collection': 'feature_requests',
        'title': ' Faster exports ',
        'state': 'in_review',
        'prUrl': 'https://github.com/x/y/pull/1',
      })!;
      expect(ref.itemType, 'feature');
      expect(ref.itemId, 'p1');
      expect(ref.title, 'Faster exports');
      expect(ref.state, ChangeRequestState.inReview);
      expect(ref.chipLabel, 'Part of: Faster exports · In review');
    });

    test('unknown state displays as filed; missing title stays readable', () {
      final ref = ParentRequestRef.fromData({'itemId': 'p1', 'state': '?'})!;
      expect(ref.state, ChangeRequestState.open);
      expect(ref.chipLabel, 'Part of: a combined request · Filed');
    });

    test('null without a map or an itemId', () {
      expect(ParentRequestRef.fromData(null), isNull);
      expect(ParentRequestRef.fromData('p1'), isNull);
      expect(ParentRequestRef.fromData({'title': 'x'}), isNull);
      expect(ParentRequestRef.fromData({'itemId': '  '}), isNull);
    });
  });

  group('linkedChangeRequestCount', () {
    test('counts unique bug and idea links only', () {
      expect(
        linkedChangeRequestCount([
          {'collection': 'bug_reports', 'id': 'b1'},
          {'collection': 'feature_requests', 'id': 'f1'},
          {'collection': 'bug_reports', 'id': 'b1'},
          {'collection': 'projects_tasks', 'id': 't1'},
          {'collection': 'bug_reports', 'id': ''},
          'junk',
        ]),
        2,
      );
    });

    test('zero for missing or non-list values', () {
      expect(linkedChangeRequestCount(null), 0);
      expect(linkedChangeRequestCount({'collection': 'bug_reports'}), 0);
      expect(linkedChangeRequestCount([
        {'collection': 'projects_tasks', 'id': 't1'},
      ]), 0);
    });

    test('labels', () {
      expect(combinedRequestsLabel(1), 'Combines 1 request');
      expect(combinedRequestsLabel(3), 'Combines 3 requests');
    });
  });

  group('ChangeRequestSummary.fromData', () {
    test('bug title is the first description line; resolved from isFixed', () {
      final bug = _bug('b1', extra: {
        'isFixed': true,
        'relatedAppName': 'Rented Dwelling',
        'groupName': 'Acme',
      });
      expect(bug.title, 'Bug b1');
      expect(bug.isResolved, isTrue);
      expect(bug.appLabel, 'Rented Dwelling');
      expect(bug.groupLabel, 'Acme');
      expect(bug.toRef(), {'itemType': 'bug', 'itemId': 'b1'});
    });

    test('idea uses its title; resolved from isCompleted or isClosed', () {
      final idea = ChangeRequestSummary.fromData(
        itemType: 'feature',
        itemId: 'f1',
        data: {'title': 'Dark mode', 'isCompleted': true, 'groupId': 'g1'},
      );
      expect(idea.title, 'Dark mode');
      expect(idea.isResolved, isTrue);
      expect(idea.groupLabel, 'g1');
      final closed = ChangeRequestSummary.fromData(
        itemType: 'feature',
        itemId: 'f2',
        data: {'isClosed': true},
      );
      expect(closed.isResolved, isTrue);
      expect(closed.title, 'Untitled idea');
    });

    test('reads parentRequest and linkedRecords', () {
      final child = _bug('b1', extra: {
        'parentRequest': {'itemType': 'feature', 'itemId': 'p1'},
      });
      expect(child.parentRequest?.itemId, 'p1');
      expect(child.isParent, isFalse);
      final parent = _bug('b2', extra: {
        'linkedRecords': [
          {'collection': 'bug_reports', 'id': 'b1'},
        ],
      });
      expect(parent.isParent, isTrue);
      expect(parent.combinedCount, 1);
    });
  });

  group('groupingIneligibilityReason', () {
    test('an open, unparented request about an app is selectable', () {
      expect(groupingIneligibilityReason(_bug('b1')), isNull);
      expect(
        groupingIneligibilityReason(_bug('b1'),
            selectedAppId: 'rented-dwelling', selectedCount: 3),
        isNull,
      );
    });

    test('blocks requests already in a parent', () {
      final child = _bug('b1', extra: {
        'parentRequest': {'itemId': 'p1'},
      });
      expect(groupingIneligibilityReason(child),
          'Already part of another request');
    });

    test('blocks parents, resolved requests and app-less requests', () {
      final parent = _bug('b1', extra: {
        'linkedRecords': [
          {'collection': 'feature_requests', 'id': 'f1'},
        ],
      });
      expect(groupingIneligibilityReason(parent), isNotNull);
      expect(groupingIneligibilityReason(_bug('b2', extra: {'isClosed': true})),
          isNotNull);
      expect(groupingIneligibilityReason(_bug('b3', appId: '')), isNotNull);
    });

    test('limits a selection to one app', () {
      expect(
        groupingIneligibilityReason(_bug('b1', appId: 'commercial-property'),
            selectedAppId: 'rented-dwelling', selectedCount: 1),
        contains('different app'),
      );
    });

    test('caps the selection size', () {
      expect(
        groupingIneligibilityReason(_bug('b1'),
            selectedAppId: 'rented-dwelling',
            selectedCount: maxGroupedChangeRequests),
        isNotNull,
      );
    });

    test('selectionAppId is the first selected request\'s app', () {
      expect(selectionAppId(const []), isNull);
      expect(selectionAppId([_bug('b1', appId: 'a'), _bug('b2', appId: 'a')]),
          'a');
    });
  });

  group('parentCandidatesFor', () {
    final parentA = _bug('p1', extra: {
      'linkedRecords': [
        {'collection': 'bug_reports', 'id': 'x'},
      ],
    });
    final resolvedParent = _bug('p2', extra: {
      'isFixed': true,
      'linkedRecords': [
        {'collection': 'bug_reports', 'id': 'y'},
      ],
    });
    final otherAppParent = _bug('p3', appId: 'other', extra: {
      'linkedRecords': [
        {'collection': 'bug_reports', 'id': 'z'},
      ],
    });
    final taskLinkedOnly = _bug('p4', extra: {
      'linkedRecords': [
        {'collection': 'projects_tasks', 'id': 't'},
      ],
    });

    test('open parents about the same app, deduplicated', () {
      final candidates = parentCandidatesFor(
        [parentA, resolvedParent, otherAppParent, taskLinkedOnly, _bug('b1'),
          parentA],
        appId: 'rented-dwelling',
      );
      expect(candidates.map((c) => c.itemId), ['p1']);
    });

    test('excludes selected requests', () {
      expect(
        parentCandidatesFor([parentA],
            appId: 'rented-dwelling', selected: [parentA]),
        isEmpty,
      );
    });
  });

  group('payloads and messages', () {
    final children = [_bug('b1'), _bug('b2')];

    test('new parent payload', () {
      expect(
        newParentGroupingPayload(
          children: children,
          groupId: 'steward-group',
          title: ' Rebuild exports ',
          description: '',
        ),
        {
          'children': [
            {'itemType': 'bug', 'itemId': 'b1'},
            {'itemType': 'bug', 'itemId': 'b2'},
          ],
          'newParent': {
            'groupId': 'steward-group',
            'title': 'Rebuild exports',
            'description': '',
          },
        },
      );
    });

    test('existing parent payload', () {
      final parent = ChangeRequestSummary.fromData(
        itemType: 'feature',
        itemId: 'p1',
        data: {'title': 'Parent'},
      );
      expect(
        existingParentGroupingPayload(children: children, parent: parent),
        {
          'children': [
            {'itemType': 'bug', 'itemId': 'b1'},
            {'itemType': 'bug', 'itemId': 'b2'},
          ],
          'parent': {'itemType': 'feature', 'itemId': 'p1'},
        },
      );
    });

    test('success messages say a new parent from bugs is an idea', () {
      expect(
        groupingSuccessMessage(
            count: 2, createdNewParent: true, sourceItemType: 'bug'),
        contains('idea'),
      );
      expect(
        groupingSuccessMessage(
            count: 2, createdNewParent: true, sourceItemType: 'bug'),
        contains('Ideas'),
      );
      expect(
        groupingSuccessMessage(
            count: 1,
            createdNewParent: false,
            sourceItemType: 'feature',
            parentTitle: 'Parent'),
        'Added 1 request to "Parent".',
      );
    });
  });
}
