import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_services/change_request_grouping.dart';

// The request lifecycle (and its labels) is shared with Improve Apps, so a
// task and its request always describe progress the same way.
export 'package:shared_services/change_request_grouping.dart'
    show ChangeRequestState, changeRequestStateFromString, changeRequestStateLabel;

enum ProjectStatus { planned, active, onHold, completed }

enum BlockerStatus { todo, inProgress, done }

ProjectStatus projectStatusFromString(String? value) {
  switch (value) {
    case 'active':
      return ProjectStatus.active;
    case 'on_hold':
      return ProjectStatus.onHold;
    case 'completed':
      return ProjectStatus.completed;
    case 'planned':
    default:
      return ProjectStatus.planned;
  }
}

String projectStatusToString(ProjectStatus status) {
  switch (status) {
    case ProjectStatus.active:
      return 'active';
    case ProjectStatus.onHold:
      return 'on_hold';
    case ProjectStatus.completed:
      return 'completed';
    case ProjectStatus.planned:
      return 'planned';
  }
}

BlockerStatus blockerStatusFromString(String? value) {
  switch (value) {
    case 'in_progress':
      return BlockerStatus.inProgress;
    case 'done':
      return BlockerStatus.done;
    case 'todo':
    default:
      return BlockerStatus.todo;
  }
}

String blockerStatusToString(BlockerStatus status) {
  switch (status) {
    case BlockerStatus.inProgress:
      return 'in_progress';
    case BlockerStatus.done:
      return 'done';
    case BlockerStatus.todo:
      return 'todo';
  }
}

class ProjectRecord {
  final String id;
  final String title;
  final String description;
  final String goal;
  final ProjectStatus status;
  final DateTime? dueDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? ownerId;
  final List<String> memberIds;
  final List<String> tags;

  /// Bluejay appIds this project concerns (e.g. the app being built for a
  /// client). Drives the app choices when filing a change request from a task.
  final List<String> relatedAppIds;

  /// Groups the work is for, plus a groupId → display name snapshot taken
  /// when the project was saved — members of this project's group usually
  /// can't read other groups' docs, so the names can't be looked up live.
  final List<String> clientGroupIds;
  final Map<String, String> clientGroupNames;

  const ProjectRecord({
    required this.id,
    required this.title,
    required this.description,
    required this.goal,
    required this.status,
    required this.dueDate,
    required this.createdAt,
    required this.updatedAt,
    required this.ownerId,
    required this.memberIds,
    required this.tags,
    this.relatedAppIds = const [],
    this.clientGroupIds = const [],
    this.clientGroupNames = const {},
  });

  factory ProjectRecord.fromFirestore(DocumentSnapshot doc) =>
      ProjectRecord.fromMap(doc.id, doc.data() as Map<String, dynamic>? ?? {});

  factory ProjectRecord.fromMap(String id, Map<String, dynamic> data) {
    return ProjectRecord(
      id: id,
      title: (data['title'] as String? ?? '').trim(),
      description: (data['description'] as String? ?? '').trim(),
      goal: (data['goal'] as String? ?? '').trim(),
      status: projectStatusFromString(data['status'] as String?),
      dueDate: (data['dueDate'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      ownerId: data['ownerId'] as String?,
      memberIds: List<String>.from(data['memberIds'] ?? const []),
      tags: normalizeProjectTags(data['tags']),
      relatedAppIds: readStringList(data['relatedAppIds']),
      clientGroupIds: readStringList(data['clientGroupIds']),
      clientGroupNames: readStringMap(data['clientGroupNames']),
    );
  }

  bool isOwner(String userId) => ownerId == userId;

  bool get hasLinks => relatedAppIds.isNotEmpty || clientGroupIds.isNotEmpty;

  /// Display name for a client group: the saved snapshot, else the raw id.
  String clientGroupName(String groupId) {
    final name = (clientGroupNames[groupId] ?? '').trim();
    return name.isEmpty ? groupId : name;
  }
}

/// Non-empty, trimmed, de-duplicated strings from a Firestore list field.
/// Anything that isn't a list (or isn't a string inside one) is ignored
/// rather than thrown on, so a malformed doc still renders.
List<String> readStringList(Object? raw) {
  if (raw is! List) return const [];
  final seen = <String>{};
  final values = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final value = item.trim();
    if (value.isNotEmpty && seen.add(value)) values.add(value);
  }
  return values;
}

/// String → string entries from a Firestore map field, dropping any entry
/// whose key is empty or whose value isn't a string.
Map<String, String> readStringMap(Object? raw) {
  if (raw is! Map) return const {};
  final values = <String, String>{};
  raw.forEach((key, value) {
    final k = key.toString().trim();
    if (k.isEmpty || value is! String) return;
    values[k] = value.trim();
  });
  return values;
}

/// Pointer from a task to the Improve Apps request (bug_reports /
/// feature_requests doc) filed from it by `projectsCreateChangeRequest`.
class ChangeRequestRef {
  /// 'bug' or 'feature'.
  final String itemType;
  final String itemId;

  /// 'bug_reports' or 'feature_requests'.
  final String collection;

  const ChangeRequestRef({
    required this.itemType,
    required this.itemId,
    required this.collection,
  });

  bool get isBug => itemType == 'bug';

  /// Null unless [raw] is a map with a known itemType and a non-empty itemId.
  /// A missing or unknown collection falls back to the one implied by
  /// itemType.
  static ChangeRequestRef? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final itemType = raw['itemType'];
    final itemId = raw['itemId'];
    if (itemType != 'bug' && itemType != 'feature') return null;
    if (itemId is! String || itemId.trim().isEmpty) return null;
    final expectedCollection = itemType == 'bug' ? 'bug_reports' : 'feature_requests';
    final collection = raw['collection'];
    return ChangeRequestRef(
      itemType: itemType as String,
      itemId: itemId.trim(),
      collection: collection == 'bug_reports' || collection == 'feature_requests'
          ? collection as String
          : expectedCollection,
    );
  }
}

class ProjectTagRecord {
  final String id;
  final String key;
  final String label;

  const ProjectTagRecord({
    required this.id,
    required this.key,
    required this.label,
  });

  factory ProjectTagRecord.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final fallbackLabel = normalizeProjectTag(data['label'] as String?) ?? '';
    final key = normalizeProjectTag(data['key'] as String?)?.toLowerCase() ??
        projectTagKey(fallbackLabel);
    return ProjectTagRecord(
      id: doc.id,
      key: key,
      label: fallbackLabel.isEmpty ? key : fallbackLabel,
    );
  }
}

final RegExp _multiSpacePattern = RegExp(r'\s+');

String? normalizeProjectTag(String? rawTag) {
  if (rawTag == null) return null;
  final normalized = rawTag.trim().replaceAll(_multiSpacePattern, ' ');
  return normalized.isEmpty ? null : normalized;
}

String projectTagKey(String tag) {
  final normalized = normalizeProjectTag(tag);
  return (normalized ?? '').toLowerCase();
}

List<String> normalizeProjectTags(Object? rawTags) {
  if (rawTags != null && rawTags is! List) {
    return const [];
  }
  final seen = <String>{};
  final tags = <String>[];
  for (final rawTag in (rawTags as List<dynamic>? ?? const [])) {
    if (rawTag is! String) continue;
    final displayTag = normalizeProjectTag(rawTag);
    if (displayTag == null) continue;
    final key = projectTagKey(displayTag);
    if (seen.add(key)) {
      tags.add(displayTag);
    }
  }
  tags.sort((a, b) => projectTagKey(a).compareTo(projectTagKey(b)));
  return tags;
}

/// The natural key of a group tag's `projects_hub_tags` doc, stored under
/// `ScopedCollection.docForKey` (`{groupId}__{key}`).
String projectTagNaturalKey(String tag) =>
    Uri.encodeComponent(projectTagKey(tag));

class BlockerTaskRecord {
  final String id;
  final String projectId;
  final String title;
  final String description;
  final String? parentTaskId;
  final BlockerStatus status;
  final int priority;
  final DateTime? dueDate;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<TaskAttachment> attachments;

  /// Claude dispatch state. Server-written only — `agentQueuedAt`/`agentJobId`
  /// by the `projectsTriggerClaudeJob` callable, the rest by the dispatch
  /// worker that implements the job (see functions/_agentic_ticket_dispatch.js
  /// and .claude/skills/implement-claude-job/SKILL.md). This app never writes
  /// them.
  final DateTime? agentQueuedAt;
  final String? agentJobId;
  final DateTime? agentDispatchedAt;
  final String? agentDispatchError;
  final String? prUrl;
  final String? prState;

  /// Linked Improve Apps request and its mirrored state. Server-written only,
  /// by the `projectsCreateChangeRequest` callable and the request→task sync
  /// (which also mirrors [prUrl]/[prState] and marks the task done once the
  /// change is live). This app never writes them.
  final ChangeRequestRef? changeRequest;
  final ChangeRequestState? changeRequestState;

  const BlockerTaskRecord({
    required this.id,
    required this.projectId,
    required this.title,
    required this.description,
    required this.parentTaskId,
    required this.status,
    required this.priority,
    required this.dueDate,
    required this.createdAt,
    required this.updatedAt,
    required this.attachments,
    this.agentQueuedAt,
    this.agentJobId,
    this.agentDispatchedAt,
    this.agentDispatchError,
    this.prUrl,
    this.prState,
    this.changeRequest,
    this.changeRequestState,
  });

  factory BlockerTaskRecord.fromFirestore(DocumentSnapshot doc) =>
      BlockerTaskRecord.fromMap(doc.id, doc.data() as Map<String, dynamic>? ?? {});

  factory BlockerTaskRecord.fromMap(String id, Map<String, dynamic> data) {
    final rawAttachments = (data['attachments'] as List<dynamic>? ?? const []);
    return BlockerTaskRecord(
      id: id,
      projectId: data['projectId'] as String? ?? '',
      title: (data['title'] as String? ?? '').trim(),
      description: (data['description'] as String? ?? '').trim(),
      parentTaskId: data['parentTaskId'] as String?,
      status: blockerStatusFromString(data['status'] as String?),
      priority: (data['priority'] as num?)?.toInt() ?? 3,
      dueDate: (data['dueDate'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      attachments: rawAttachments
          .map((item) {
            if (item is Map<String, dynamic>) return item;
            if (item is Map) {
              return item.map((key, value) => MapEntry(key.toString(), value));
            }
            return null;
          })
          .whereType<Map<String, dynamic>>()
          .map(TaskAttachment.fromMap)
          .where((item) => item.url.trim().isNotEmpty)
          .toList(),
      agentQueuedAt: (data['agentQueuedAt'] as Timestamp?)?.toDate(),
      agentJobId: data['agentJobId'] as String?,
      agentDispatchedAt: (data['agentDispatchedAt'] as Timestamp?)?.toDate(),
      agentDispatchError: data['agentDispatchError'] as String?,
      prUrl: data['prUrl'] as String?,
      prState: data['prState'] as String?,
      changeRequest: ChangeRequestRef.tryParse(data['changeRequest']),
      changeRequestState: changeRequestStateFromString(data['changeRequestState']),
    );
  }

  bool get isDone => status == BlockerStatus.done;

  bool get hasDispatchError => (agentDispatchError ?? '').trim().isNotEmpty;

  /// Whether this task has been handed to Claude at all — queued, or already
  /// implemented by a dispatch worker.
  bool get hasAgentJob => agentQueuedAt != null || agentDispatchedAt != null;

  bool get hasChangeRequest => changeRequest != null;

  /// [changeRequestState] for display, treating a linked request whose state
  /// hasn't been mirrored yet (or is unrecognized) as just filed. Null when
  /// there's no change request.
  ChangeRequestState? get displayChangeRequestState =>
      hasChangeRequest ? (changeRequestState ?? ChangeRequestState.open) : null;

  /// [prUrl] only if it's an https github.com link. Task docs are
  /// group-writable, so an arbitrary URL here must never be rendered as a
  /// "View pull request" link.
  Uri? get pullRequestUri {
    final uri = Uri.tryParse((prUrl ?? '').trim());
    if (uri == null || uri.scheme != 'https' || uri.host.toLowerCase() != 'github.com') return null;
    return uri;
  }
}

int compareBlockerTaskPriority(BlockerTaskRecord a, BlockerTaskRecord b) {
  final priorityCompare = a.priority.compareTo(b.priority);
  if (priorityCompare != 0) return priorityCompare;
  return a.title.compareTo(b.title);
}

int compareActionableBlockerTasks(BlockerTaskRecord a, BlockerTaskRecord b) {
  final priorityCompare = a.priority.compareTo(b.priority);
  if (priorityCompare != 0) return priorityCompare;
  final aDue = a.dueDate;
  final bDue = b.dueDate;
  if (aDue == null && bDue == null) return a.title.compareTo(b.title);
  if (aDue == null) return 1;
  if (bDue == null) return -1;
  final dueCompare = aDue.compareTo(bDue);
  if (dueCompare != 0) return dueCompare;
  return a.title.compareTo(b.title);
}

class TaskAttachment {
  final String url;
  final String name;
  final String? path;
  final String? contentType;
  final int? sizeBytes;
  final DateTime? uploadedAt;

  const TaskAttachment({
    required this.url,
    required this.name,
    this.path,
    this.contentType,
    this.sizeBytes,
    this.uploadedAt,
  });

  factory TaskAttachment.fromMap(Map<String, dynamic> data) {
    return TaskAttachment(
      url: data['url'] as String? ?? '',
      name: (data['name'] as String? ?? '').trim(),
      path: data['path'] as String?,
      contentType: data['contentType'] as String?,
      sizeBytes: (data['sizeBytes'] as num?)?.toInt(),
      uploadedAt: (data['uploadedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'name': name,
      'path': path,
      'contentType': contentType,
      'sizeBytes': sizeBytes,
      'uploadedAt': uploadedAt == null ? null : Timestamp.fromDate(uploadedAt!),
    };
  }
}
