/// Client-side helpers for grouping Improve Apps change requests (bug_reports
/// / feature_requests docs) under a parent request — the Dart side of the
/// `changeRequestsGroup` callable in functions/change_requests.js.
///
/// Server-written fields this reads:
/// - on a child: `parentRequest: {itemType, itemId, collection, title,
///   state, prUrl}`, where `state` mirrors the parent's progress;
/// - on a parent: `linkedRecords: [{collection, id}]`, whose bug_reports /
///   feature_requests entries are the requests it combines (other
///   collections, e.g. a Projects task, are links of a different kind).
library;

/// Firestore collection → callable `itemType` for the request kinds that
/// can be grouped.
const Map<String, String> groupableChangeRequestCollections = {
  'bug_reports': 'bug',
  'feature_requests': 'feature',
};

/// The most requests one `changeRequestsGroup` call accepts (MAX_CHILDREN in
/// functions/change_requests.js).
const int maxGroupedChangeRequests = 20;

/// Lifecycle of a change request as the server derives it
/// (deriveChangeRequestState in functions/_change_request_links.js).
enum ChangeRequestState { open, queued, inReview, merged, resolved, closed }

/// Null for a missing or unrecognized value.
ChangeRequestState? changeRequestStateFromString(Object? value) {
  switch (value) {
    case 'open':
      return ChangeRequestState.open;
    case 'queued':
      return ChangeRequestState.queued;
    case 'in_review':
      return ChangeRequestState.inReview;
    case 'merged':
      return ChangeRequestState.merged;
    case 'resolved':
      return ChangeRequestState.resolved;
    case 'closed':
      return ChangeRequestState.closed;
    default:
      return null;
  }
}

/// Short, client-facing label for [state].
String changeRequestStateLabel(ChangeRequestState state) {
  switch (state) {
    case ChangeRequestState.open:
      return 'Filed';
    case ChangeRequestState.queued:
      return 'Queued';
    case ChangeRequestState.inReview:
      return 'In review';
    case ChangeRequestState.merged:
      return 'Deploying';
    case ChangeRequestState.resolved:
      return 'Live';
    case ChangeRequestState.closed:
      return 'Closed';
  }
}

/// A child request's pointer to the parent it was grouped under.
class ParentRequestRef {
  final String itemType;
  final String itemId;
  final String title;

  /// The parent's progress; an unknown or missing value displays as
  /// [ChangeRequestState.open].
  final ChangeRequestState state;

  const ParentRequestRef({
    required this.itemType,
    required this.itemId,
    required this.title,
    this.state = ChangeRequestState.open,
  });

  /// Null unless [raw] is a map naming a parent `itemId`.
  static ParentRequestRef? fromData(Object? raw) {
    if (raw is! Map) return null;
    final itemId = _trimmed(raw['itemId']);
    if (itemId.isEmpty) return null;
    return ParentRequestRef(
      itemType: _trimmed(raw['itemType']),
      itemId: itemId,
      title: _trimmed(raw['title']),
      state: changeRequestStateFromString(raw['state']) ??
          ChangeRequestState.open,
    );
  }

  /// `Part of: <title> · <state>` for a card chip.
  String get chipLabel {
    final name = title.isEmpty ? 'a combined request' : title;
    return 'Part of: $name · ${changeRequestStateLabel(state)}';
  }
}

/// How many bug_reports / feature_requests docs a parent's `linkedRecords`
/// combines (duplicates counted once). Zero means it isn't a parent.
int linkedChangeRequestCount(Object? linkedRecords) {
  if (linkedRecords is! List) return 0;
  final seen = <String>{};
  for (final entry in linkedRecords) {
    if (entry is! Map) continue;
    final collection = _trimmed(entry['collection']);
    final id = _trimmed(entry['id']);
    if (id.isEmpty ||
        !groupableChangeRequestCollections.containsKey(collection)) {
      continue;
    }
    seen.add('$collection/$id');
  }
  return seen.length;
}

/// "Combines N requests" for a parent card chip.
String combinedRequestsLabel(int count) =>
    'Combines $count ${count == 1 ? 'request' : 'requests'}';

/// What the grouping UI needs to know about one bug or idea.
class ChangeRequestSummary {
  /// `bug` or `feature`.
  final String itemType;
  final String itemId;
  final String title;
  final String relatedAppId;
  final String appLabel;
  final String groupLabel;
  final bool isResolved;
  final ParentRequestRef? parentRequest;
  final int combinedCount;

  const ChangeRequestSummary({
    required this.itemType,
    required this.itemId,
    required this.title,
    required this.relatedAppId,
    this.appLabel = '',
    this.groupLabel = '',
    this.isResolved = false,
    this.parentRequest,
    this.combinedCount = 0,
  });

  /// Reads a bug_reports (`itemType` 'bug') or feature_requests ('feature')
  /// doc. A bug's title is the first line of its description, as the server
  /// derives it.
  factory ChangeRequestSummary.fromData({
    required String itemType,
    required String itemId,
    required Map<String, dynamic> data,
  }) {
    final isBug = itemType == 'bug';
    final title = isBug
        ? _firstLine(data['description'])
        : (_trimmed(data['title']).isNotEmpty
            ? _trimmed(data['title'])
            : _firstLine(data['description']));
    // A deleted ticket (soft delete, ScopedCollection.isSoftDeleted) counts
    // as closed.
    final resolved = data['deletedAt'] != null ||
        data['isClosed'] == true ||
        (isBug ? data['isFixed'] == true : data['isCompleted'] == true);
    return ChangeRequestSummary(
      itemType: itemType,
      itemId: itemId,
      title: title.isNotEmpty
          ? title
          : (isBug ? 'Untitled bug report' : 'Untitled idea'),
      relatedAppId: _trimmed(data['relatedAppId']),
      appLabel: _firstNonEmpty(data['relatedAppName'], data['relatedAppId']),
      groupLabel: _firstNonEmpty(data['groupName'], data['groupId']),
      isResolved: resolved,
      parentRequest: ParentRequestRef.fromData(data['parentRequest']),
      combinedCount: linkedChangeRequestCount(data['linkedRecords']),
    );
  }

  bool get isParent => combinedCount > 0;

  /// The `{itemType, itemId}` reference the callable takes.
  Map<String, String> toRef() => {'itemType': itemType, 'itemId': itemId};
}

/// The app every request in [selected] is about, or null when nothing is
/// selected.
String? selectionAppId(Iterable<ChangeRequestSummary> selected) {
  for (final item in selected) {
    return item.relatedAppId;
  }
  return null;
}

/// Why [item] can't be added to a grouping selection whose requests are all
/// about [selectedAppId] (null when nothing is selected yet), or null when
/// it can. [selectedCount] enforces [maxGroupedChangeRequests].
String? groupingIneligibilityReason(
  ChangeRequestSummary item, {
  String? selectedAppId,
  int selectedCount = 0,
}) {
  if (item.parentRequest != null) return 'Already part of another request';
  if (item.isParent) return 'Already combines other requests';
  if (item.isResolved) return 'Already resolved or closed';
  if (item.relatedAppId.isEmpty) return 'Not about a specific app';
  if (selectedAppId != null && item.relatedAppId != selectedAppId) {
    return 'About a different app — combine one app at a time';
  }
  if (selectedCount >= maxGroupedChangeRequests) {
    return 'Up to $maxGroupedChangeRequests requests can be combined at once';
  }
  return null;
}

/// Open parents about [appId] that [selected] could be added to, excluding
/// any request that is itself selected.
List<ChangeRequestSummary> parentCandidatesFor(
  Iterable<ChangeRequestSummary> items, {
  required String appId,
  Iterable<ChangeRequestSummary> selected = const [],
}) {
  final selectedIds = selected.map((s) => '${s.itemType}/${s.itemId}').toSet();
  final seen = <String>{};
  return items
      .where((item) =>
          item.isParent &&
          !item.isResolved &&
          item.relatedAppId == appId &&
          !selectedIds.contains('${item.itemType}/${item.itemId}') &&
          seen.add('${item.itemType}/${item.itemId}'))
      .toList();
}

/// Payload for creating a new parent idea in [groupId] combining [children].
Map<String, dynamic> newParentGroupingPayload({
  required Iterable<ChangeRequestSummary> children,
  required String groupId,
  required String title,
  String description = '',
}) {
  return {
    'children': children.map((c) => c.toRef()).toList(),
    'newParent': {
      'groupId': groupId,
      'title': title.trim(),
      'description': description.trim(),
    },
  };
}

/// Payload for adding [children] to the existing [parent].
Map<String, dynamic> existingParentGroupingPayload({
  required Iterable<ChangeRequestSummary> children,
  required ChangeRequestSummary parent,
}) {
  return {
    'children': children.map((c) => c.toRef()).toList(),
    'parent': parent.toRef(),
  };
}

/// Success message after grouping [count] requests from the [sourceItemType]
/// ('bug' / 'feature') list. A new parent is always an idea, which a bug
/// list doesn't show — so say where it went.
String groupingSuccessMessage({
  required int count,
  required bool createdNewParent,
  required String sourceItemType,
  String parentTitle = '',
}) {
  final noun = count == 1 ? 'request' : 'requests';
  if (!createdNewParent) {
    final target = parentTitle.isEmpty ? 'the request' : '"$parentTitle"';
    return 'Added $count $noun to $target.';
  }
  if (sourceItemType == 'bug') {
    return 'Combined $count $noun into a new idea — find it in Ideas.';
  }
  return 'Combined $count $noun into a new idea.';
}

String _trimmed(Object? value) => value is String ? value.trim() : '';

String _firstLine(Object? value) {
  final text = _trimmed(value);
  if (text.isEmpty) return '';
  final line = text.split('\n').first.trim();
  return line.length > 120 ? '${line.substring(0, 117)}…' : line;
}

String _firstNonEmpty(Object? preferred, Object? fallback) {
  final first = _trimmed(preferred);
  return first.isNotEmpty ? first : _trimmed(fallback);
}
