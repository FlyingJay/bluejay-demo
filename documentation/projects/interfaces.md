# Projects — Interfaces

## Overview

Projects is a Flutter feature backed by scoped Firestore reads/writes, Firebase Storage attachments, and callable Cloud Functions. Its data boundary is:

- inbound launcher navigation from `AppRouter`,
- inbound authenticated/active-group context from shared services,
- Firestore reads and writes against three scoped collections plus app-attributed reads of shared collections,
- callable request/response to `projectsListClientGroups`, `projectsCreateChangeRequest`, and the legacy `projectsTriggerClaudeJob`,
- server-side change-request status synchronization and task-completion notification,
- client-side status/tag filtering and derived next-action computation on dashboard snapshots.

There is no Projects REST endpoint or local on-device persistence layer. The linked change-request lifecycle is handled by Firestore triggers outside the package, which update task documents and may create a notification when a task becomes done. The `projectsOnTaskWritten` trigger alerts the project's group when a task is added or closed.

### Schema notation used below

- `Timestamp` = Firestore timestamp stored in a document.
- `"<serverTimestamp>"` = `FieldValue.serverTimestamp()` sentinel at write time.
- `null` = field omitted or intentionally cleared.

---

## Launcher and widget interfaces

### Route registration

**Source:** `lib/routing/app_router.dart`

```dart
'projects': (user) => ProjectsDashboardScreen(currentUser: user)
```

**Shared-place route** (`lib/routing/shared_place_routes.dart`, called from `AppRouter._resolveScreen`): when the launch args carry `project`, the router opens the dashboard on that project instead:

```dart
if (appId == 'projects' && args[projectArg] != null) {
  return ProjectsDashboardScreen(
    currentUser: user,
    initialProjectId: args[projectArg],
    initialTaskId: args[taskArg],
  );
}
```

### Launch args and shared place

**Source:** `packages/projects/lib/constants.dart`, `packages/projects/lib/project_detail_screen.dart`

| Arg | Constant | Value |
|---|---|---|
| `project` | `projectArg` | `projects_hub_projects` document ID to open |
| `task` | `taskArg` | `projects_hub_blockers` document ID to highlight in that project; ignored without `project` |

```dart
Map<String, String> projectPlaceArgs(String projectId, {String? taskId})
// {"project": projectId}, plus "task": taskId when taskId is non-null and non-empty
```

`ProjectPlace({required ProjectRecord project, BlockerTaskRecord? task, required Widget child})` wraps a shared `PlaceMarker`, so `CurrentPlace.here()` reports it to Chat's "Link to where I am" as a `SharedPlace` with:

```json
{
  "appId": "projects",
  "appName": "Projects",
  "args": {"project": "project ID", "task": "task ID (only when a task is marked)"},
  "title": "task title, or the project title when no task is marked"
}
```

The group fields of the `SharedPlace` come from the active group; see [Platform changes](../platform_changes/developer.md) (PR #3364) for the full shape. The detail page is marked with the linked task once it has been found, and the task form sheet is marked with the task being edited.

### `ProjectsDashboardScreen`

```dart
ProjectsDashboardScreen({
  Key? key,
  fire_auth.User? currentUser,
  String? initialProjectId,
  String? initialTaskId,
})
```

- `currentUser == null` renders a `BjPage` with a locked login-required state.
- `currentUser.uid` is used for owner checks during project create/edit writes.
- `initialProjectId` (from the `project` launch arg) is looked up in the streamed projects, waiting past a cache-only snapshot that lacks it. Found, it pushes `ProjectDetailScreen` with `initialTaskId`; not found (deleted, another group's, or not visible to the viewer), the list stays with the snackbar "That project isn't available. It may have been deleted, or you can't see it." It is resolved once.

### `ProjectDetailScreen`

```dart
ProjectDetailScreen({
  Key? key,
  required fire_auth.User currentUser,
  required ProjectRecord project,
  required ProjectsAccess access,
  String? initialTaskId,
})
```

- `project` is passed from the dashboard card tap, or from a shared-place launch.
- `initialTaskId` (from the `task` launch arg) is resolved once against the task stream, waiting past a cache-only snapshot that lacks it. Found, the task card gets an accent border and is scrolled into view, and **Hide completed** is turned off if the task is done; missing, the snackbar "That task isn't in this project any more." is shown.
- `access` is the same `ProjectsAccess` instance already resolved on the dashboard; it drives task add/edit/delete/toggle visibility in this screen.
- When the user can view the active group, the `BjPage` header shows a notification bell that reads and writes the user's own `projects_hub_projects/{projectId}/notification_prefs/{uid}` doc (see [Notifications / events emitted by Projects](#notifications--events-emitted-by-projects)).

---

## Shared-service interfaces consumed by Projects

### `ProjectsAccess`

Resolved from `users/{uid}/metadata/access_index` through the shared `AccessIndexBuilder` (`packages/shared_services/lib/access_index_builder.dart`).

```dart
ProjectsAccess.fromData(Map<String, dynamic>? data)
```

**Input document shape:**

```json
{
  "status": "ACTIVE | INACTIVE",
  "roles": ["admin", "..."],
  "entitlements": ["groupId:projects", "groupId:projects:edit", "groupId:projects:admin", "..."],
  "denied_scopes": ["groupId", "..."]
}
```

**Derived permission methods:**

| Method | Returns true when |
|---|---|
| `isPlatformAdmin` | `roles` contains `'admin'` |
| `canViewGroup(groupId)` | platform admin, OR status ACTIVE + groupId not denied + entitlement `groupId:projects` (or `:edit`/`:admin`) |
| `canCreateInGroup(groupId)` | same as `canViewGroup` |
| `canEditGroup(groupId)` | platform admin, OR status ACTIVE + groupId not denied + entitlement `groupId:projects:edit` or `:admin` |

The dashboard reads this document with `AccessIndexBuilder(uid: user.uid, appId: 'projects')`, which subscribes to the session-wide shared access-index listener (`AccessIndex.snapshots`) and starts from its latest value (`AccessIndex.current`), so a cached index renders without a waiting frame. Reads by the shared listener are attributed to the platform app ID rather than Projects; see [Platform changes](../platform_changes/developer.md) (PR #3112). It supplies the client-side group-entitlement view. The legacy `projectsTriggerClaudeJob` callable separately obtains platform-role data through `getAccessIndex(uid)`, which derives trusted platform roles from Firebase Auth claims; it does not authorize from a client-supplied role or a direct read of the access-index document.

**Dashboard UI capability map:**

| UI element | Required permission |
|---|---|
| See the projects list | `canViewGroup` |
| **New project** FAB | `canCreateInGroup` |
| **Edit project** menu item | `canEditGroup` |
| **Delete project** menu item | `canEditGroup` |
| **Duplicate project** menu item | `canCreateInGroup` |
| **Add blocker** FAB (detail screen) | `canCreateInGroup` |
| Task overflow menu: **Edit**, **Add blocker beneath this task**, **Delete** | `canEditGroup` |
| Task checkbox completion | `canEditGroup` |

### `ScopedCollection`

Projects instantiates three scoped collections:

```dart
ScopedCollection(collection: 'projects_hub_projects', appId: 'projects')
ScopedCollection(collection: 'projects_hub_tags',     appId: 'projects')
ScopedCollection(collection: 'projects_hub_blockers', appId: 'projects')
```

#### Read contract

Every `.query` for these single-app Projects collections is transformed to:

```text
collection.where('groupId', isEqualTo: activeGroupId)
```

If there is no active group, the query becomes:

```text
collection.where('groupId', isEqualTo: '__no_active_group__')
```

#### Write contract

Every `.add()` injects:

```json
{
  "groupId": "<activeGroupId>",
  "appId": "projects",
  "creatorId": "<currentUserUid>",
  "ownerIds": ["<currentUserUid>"]
}
```

unless `ownerIds` is explicitly provided in the caller payload.

The generated Firestore rules independently enforce group/app authorization and permission-field invariants. `ScopedCollection` supplies scoped query and write metadata, but rules remain the authorization boundary for direct document reads, updates, and deletes.

### `BluejayFirestore`

The Projects package uses `BluejayFirestore.forApp('projects')` for shared/root collections and batch operations that are not backed by a `ScopedCollection`, including:

```text
groups/{groupId}
apps (ordered by name)
project and task delete batches
```

These are attributed to the Projects app for usage accounting. `ScopedCollection` also uses the shared metered Firestore gateway internally, while continuing to inject `groupId` on scoped queries and permission fields on adds. Billable Firestore reads, writes, and deletes are recorded by the shared gateway; reads served from cache are free. This metering does not alter the returned Firebase types or saved document payloads.

### `ScopedStorage`

Projects instantiates one scoped storage instance for task file attachments:

```dart
ScopedStorage(folder: 'projects_hub_task_files', appId: 'projects')
```

Files are stored at `groups/{groupId}/apps/projects/projects_hub_task_files/{path}`. The enforced `group_apps` Storage policy checks the caller’s group/app entitlement and the object’s `groupId`, `appId`, and creator metadata. The 10 MB limit and extension-to-MIME mapping are still client-side checks.

#### Upload contract

```text
_taskFileStorage.upload(name, bytes, contentType: contentType)
  → Future<Reference>
```

After upload, the download URL is obtained with:

```text
ref.getDownloadURL() → Future<String>
```

The resulting URL is stored in the `attachments` array of the blocker task document.

**Maximum file size:** `10 * 1024 * 1024` bytes (10 MB). Files exceeding this limit are skipped and the task form shows `Skipped N file(s) over 10 MB.`.

**Content-type mapping** (from `_contentTypeForExtension`):

| Extension | MIME type |
|---|---|
| `pdf` | `application/pdf` |
| `png` | `image/png` |
| `jpg`, `jpeg` | `image/jpeg` |
| `gif` | `image/gif` |
| `webp` | `image/webp` |
| `txt` | `text/plain` |
| `csv` | `text/csv` |
| `doc` | `application/msword` |
| `docx` | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` |
| `xls` | `application/vnd.ms-excel` |
| `xlsx` | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` |
| (other) | `application/octet-stream` |

---

## Firestore persistence models

### Collection: `projects_hub_projects`

**Scoped through:** `ScopedCollection(collection: 'projects_hub_projects', appId: 'projects')`

#### Persisted document shape

```json
{
  "title": "Website relaunch",
  "description": "Coordinate copy, QA, and deployment.",
  "goal": "Launch the new marketing site before conference week.",
  "tags": ["urgent", "q3"],
  "status": "active",
  "dueDate": "Timestamp | null",
  "relatedAppIds": ["commercial-property"],
  "clientGroupIds": ["client_group_123"],
  "clientGroupNames": {"client_group_123": "Client group"},
  "ownerId": "uid_owner",
  "memberIds": ["uid_owner", "uid_teammate"],
  "createdAt": "Timestamp",
  "updatedAt": "Timestamp",
  "groupId": "group_123",
  "appId": "projects",
  "creatorId": "uid_owner",
  "ownerIds": ["uid_owner"]
}
```

#### Read model: `ProjectRecord`

```json
{
  "id": "<document id>",
  "title": "String",
  "description": "String",
  "goal": "String",
  "tags": ["String"],
  "relatedAppIds": ["String"],
  "clientGroupIds": ["String"],
  "clientGroupNames": {"groupId": "display name"},
  "status": "planned | active | on_hold->onHold | completed",
  "dueDate": "DateTime | null",
  "createdAt": "DateTime | null",
  "updatedAt": "DateTime | null",
  "ownerId": "String | null",
  "memberIds": ["String"]
}
```

`relatedAppIds`, `clientGroupIds`, and `clientGroupNames` are read as trimmed, de-duplicated string collections/maps. Missing or malformed optional values become empty collections.

#### Dashboard stream queries

```text
// Access control stream (shared session-wide listener on
// users/{uid}/metadata/access_index):
AccessIndexBuilder(uid: user.uid, appId: 'projects', builder: ...)
  → AccessIndex.snapshots(user.uid, appId: 'projects'),
    initialData: AccessIndex.current(user.uid)

// Group tags stream:
_projectTags.query.snapshots()
  → where('groupId', isEqualTo: activeGroupId)  [injected by ScopedCollection]

// Projects stream (all group projects; visibility gated by access_index entitlement):
_projects.query.snapshots()
  → where('groupId', isEqualTo: activeGroupId)  [injected by ScopedCollection]
```

**Inbound filter:** `groupId == activeGroupId` is applied by `ScopedCollection` for all three streams. Project visibility is determined by `ProjectsAccess.canViewGroup(activeGroupId)` — there is no per-document `memberIds` filter on the stream.

**Returned snapshot shape:**

```json
{
  "docs": [
    {
      "id": "projectDocId",
      "data": "projects_hub_projects document"
    }
  ]
}
```

#### Create-project write payload

The dialog constructs this application payload before `ScopedCollection.add()` injects scoped fields:

```json
{
  "title": "Website relaunch",
  "goal": "Launch the new marketing site before conference week.",
  "description": "Coordinate copy, QA, and deployment.",
  "tags": ["urgent", "q3"],
  "status": "planned | active | on_hold | completed",
  "dueDate": "Timestamp | null",
  "ownerId": "<currentUser.uid>",
  "memberIds": ["<currentUser.uid>"],
  "relatedAppIds": ["commercial-property"],
  "clientGroupIds": ["client_group_123"],
  "clientGroupNames": {"client_group_123": "Client group"},
  "updatedAt": "<serverTimestamp>",
  "createdAt": "<serverTimestamp>"
}
```

#### Edit-project update payload

```json
{
  "title": "Website relaunch",
  "goal": "Updated goal text",
  "description": "Updated description",
  "tags": ["backend", "migration"],
  "status": "on_hold",
  "dueDate": null,
  "ownerId": "existingOwnerUid",
  "memberIds": ["existingMemberUids..."],
  "relatedAppIds": ["commercial-property"],
  "clientGroupIds": ["client_group_123"],
  "clientGroupNames": {"client_group_123": "Client group"},
  "updatedAt": "<serverTimestamp>"
}
```

#### Duplicate-project UI contract

Project card menu selection (shown when the user has create and/or edit access):

```json
{
  "menuAction": "duplicate",
  "sourceProjectId": "existingProjectDocId"
}
```

Runtime behavior:

```text
BjMenuAction('Duplicate project').onSelected
  -> _showProjectForm(access: access, duplicateFrom: project)
  -> ProjectFormSheet pre-fills from source project
  -> save follows create path because project == null
```

Duplicate save payload before scoped-field injection:

```json
{
  "title": "Copied from source project title unless edited",
  "goal": "Copied from source project goal unless edited",
  "description": "Copied from source project description unless edited",
  "tags": ["copied", "from-source"],
  "status": "planned | active | on_hold | completed",
  "dueDate": "Timestamp | null",
  "ownerId": "<currentUser.uid>",
  "memberIds": ["<currentUser.uid>"],
  "relatedAppIds": ["commercial-property"],
  "clientGroupIds": ["client_group_123"],
  "clientGroupNames": {"client_group_123": "Client group"},
  "updatedAt": "<serverTimestamp>",
  "createdAt": "<serverTimestamp>"
}
```

Important exclusions:

- no existing `memberIds` beyond the duplicating user are copied,
- no `projects_hub_blockers` documents are read or cloned,
- no task attachments are copied because they only exist on blocker-task documents.

#### Delete-project operation

```text
1. Query blockers where projectId == project.id (count only; null if the read fails)
2. showBjConfirm listing the consequences, including the task count
3. On confirm, query blockers where projectId == project.id again
4. Batch delete every blocker doc reference
5. Batch delete _projects.doc(project.id)
6. Commit once
```

---

### Collection: `projects_hub_tags`

**Scoped through:** `ScopedCollection(collection: 'projects_hub_tags', appId: 'projects')`

Group-wide reusable tag records. One document exists per unique normalized tag key per group. These drive the autocomplete suggestions in the project create/edit form.

#### Document ID format

```
{groupId}__{percentEncodedLowercaseTagKey}
```

Examples:
- `group-123__urgent`
- `group-123__urgent%20work`

The app normalizes each tag key to lowercase, percent-encodes it with `projectTagNaturalKey`, and passes it to `ScopedCollection.docForKey`, which adds the active group prefix. `projects_hub_tags` declares `naturalKeyIds: true` in `security/collections.json`.

`getForKey`/`setForKey` use only the canonical ID; the M4 rekey moved every record from the former `{groupId}:{key}` ID. That migration changed document IDs only; the tag `key`, `label`, and project `tags` values remain unchanged.

#### Persisted document shape

```json
{
  "key": "urgent work",
  "label": "Urgent Work",
  "createdAt": "Timestamp",
  "updatedAt": "Timestamp",
  "groupId": "group-123",
  "appId": "projects",
  "creatorId": "uid_owner",
  "ownerIds": ["uid_owner"]
}
```

- `key`: lowercase normalized form used for deduplication matching.
- `label`: display-friendly form from the first user who created the tag.
- Subsequent projects using a tag with the same `key` reuse the existing `label` rather than creating a new document.

#### Read model: `ProjectTagRecord`

```json
{
  "id": "<document id>",
  "key": "String — lowercase normalized key",
  "label": "String — display label (falls back to key if label is empty)"
}
```

#### Dashboard tag stream query

```text
_projectTags.query.snapshots()
  → where('groupId', isEqualTo: activeGroupId)  [injected by ScopedCollection]
```

Tags are sorted by `key` ascending in the dashboard filter strip and in the project form suggestions.

#### `_ensureGroupTags` write (upsert)

Called before every project create or edit when the project carries one or more tags. For each normalized tag:

1. Compute the natural key with `projectTagNaturalKey(tag)`.
2. Read with `_projectTags.getForKey(key)`, which checks the canonical ID.
3. If missing, write with `_projectTags.setForKey(key, ..., SetOptions(merge: true))`:

```json
{
  "key": "normalized_key",
  "label": "Display Label",
  "createdAt": "<serverTimestamp>",
  "updatedAt": "<serverTimestamp>"
}
```

This ensures every tag used in any project is always represented in the group tag catalogue.

#### Tag form suggestions read

The project form (`ProjectFormSheet`) shows up to 12 existing group tags as ActionChip suggestions. The suggestion list is filtered by the in-progress text input:

```text
tag.label.toLowerCase().contains(query.toLowerCase())
```

Tapping a suggestion chip sets the text field and immediately adds the tag.

---

### Collection: `projects_hub_blockers`

**Scoped through:** `ScopedCollection(collection: 'projects_hub_blockers', appId: 'projects')`

#### Persisted document shape

```json
{
  "projectId": "projectDocId",
  "title": "Set up deployment workflow",
  "description": "Needs repository secrets and release checklist.",
  "parentTaskId": null,
  "status": "todo",
  "priority": 4,
  "dueDate": "Timestamp | null",
  "attachments": [
    {
      "url": "https://firebasestorage.googleapis.com/...",
      "name": "screenshot.png",
      "path": "groups/<groupId>/apps/projects/projects_hub_task_files/<filename>",
      "contentType": "image/png",
      "sizeBytes": 204800,
      "uploadedAt": "Timestamp | null"
    }
  ],
  "changeRequest": {
    "itemType": "bug | feature",
    "itemId": "linked request document ID",
    "collection": "bug_reports | feature_requests"
  },
  "changeRequestState": "open | queued | in_review | merged | resolved | closed",
  "changeRequestSyncedAt": "Timestamp",
  "relatedAppId": "app ID selected when filing the request",
  "prUrl": "server-mirrored pull request URL, when available",
  "prState": "server-mirrored pull request state, when available",
  "closedBy": "uid of the user who last marked the task done (client-written; deleted when the server completes the task)",
  "createdAt": "Timestamp",
  "updatedAt": "Timestamp",
  "groupId": "group_123",
  "appId": "projects",
  "creatorId": "uid_owner",
  "ownerIds": ["uid_owner"]
}
```

`attachments` is an array of attachment map objects. Missing or null on legacy documents is read as `[]`. Items with an empty `url` are discarded on read.

The server also writes `changeRequestSyncedAt` as the last linked-request synchronization timestamp. `BlockerTaskRecord` does not expose that timestamp as a model property.

Server-written Claude dispatch fields (never written by the app; see `projectsTriggerClaudeJob` below): `agentQueuedAt` (Timestamp) and `agentJobId` (String) at queue time, then `agentDispatchedAt` (Timestamp), `agentDispatchSource` (`claude` | `claude-local`), `prUrl`, `prState` (`open | merged | closed`), `prNumber`, and `prSyncedAt` once a dispatch worker opens the PR. `agentDispatchError` (String, ≤500 chars) records a failed queue or implementation attempt and is deleted on success. `BlockerTaskRecord` reads `agentQueuedAt`, `agentJobId`, `agentDispatchedAt`, `agentDispatchError`, `prUrl`, and `prState`.

#### Read model: `BlockerTaskRecord`

```json
{
  "id": "<document id>",
  "projectId": "String",
  "title": "String",
  "description": "String",
  "parentTaskId": "String | null",
  "status": "todo | in_progress->inProgress | done",
  "priority": "int (fallback: 3)",
  "dueDate": "DateTime | null",
  "createdAt": "DateTime | null",
  "updatedAt": "DateTime | null",
  "attachments": [
    {
      "url": "String",
      "name": "String",
      "path": "String | null",
      "contentType": "String | null",
      "sizeBytes": "int | null",
      "uploadedAt": "DateTime | null"
    }
  ],
  "changeRequest": {
    "itemType": "bug | feature",
    "itemId": "String",
    "collection": "bug_reports | feature_requests"
  },
  "changeRequestState": "ChangeRequestState | null",
  "prUrl": "String | null",
  "prState": "String | null",
  "agentQueuedAt": "DateTime | null",
  "agentJobId": "String | null",
  "agentDispatchedAt": "DateTime | null",
  "agentDispatchError": "String | null"
}
```

#### `TaskAttachment` model

```json
{
  "url": "String — Firebase Storage download URL (required; empty strings filtered out at read)",
  "name": "String — original filename trimmed (falls back to 'Attachment' in UI)",
  "path": "String | null — full Firebase Storage object path",
  "contentType": "String | null — MIME type derived from extension at upload",
  "sizeBytes": "int | null — size in bytes from file picker",
  "uploadedAt": "Timestamp | null — stored as Firestore Timestamp; written as local DateTime at upload"
}
```

#### Detail-screen stream query

```text
_projectTasks.query.where('projectId', isEqualTo: widget.project.id).snapshots()
```

#### Dashboard next-action query

```text
_blockers.query.where('projectId', isEqualTo: projectId).get()
```

#### Create-task write payload

```json
{
  "projectId": "projectDocId",
  "title": "Set up deployment workflow",
  "description": "Needs repository secrets and release checklist.",
  "parentTaskId": null,
  "status": "todo | in_progress | done",
  "priority": 1,
  "dueDate": "Timestamp | null",
  "attachments": [
    {
      "url": "https://firebasestorage.googleapis.com/...",
      "name": "diagram.png",
      "path": "groups/<groupId>/apps/projects/projects_hub_task_files/<filename>",
      "contentType": "image/png",
      "sizeBytes": 51200,
      "uploadedAt": "Timestamp"
    }
  ],
  "updatedAt": "<serverTimestamp>",
  "createdAt": "<serverTimestamp>"
}
```

`attachments` is always written as an array; an empty array is written when no files are attached.

#### Edit-task update payload

```json
{
  "projectId": "projectDocId",
  "title": "Set up deployment workflow",
  "description": "Updated details",
  "parentTaskId": "optionalParentTaskId | null",
  "status": "todo | in_progress | done",
  "priority": 5,
  "dueDate": "Timestamp | null",
  "attachments": [
    {
      "url": "https://firebasestorage.googleapis.com/...",
      "name": "diagram.png",
      "path": "groups/<groupId>/apps/projects/projects_hub_task_files/<filename>",
      "contentType": "image/png",
      "sizeBytes": 51200,
      "uploadedAt": "Timestamp"
    }
  ],
  "updatedAt": "<serverTimestamp>",
  "closedBy": "currentUser.uid  // only when this edit moves the task from not-done to done"
}
```

The `attachments` array is always fully replaced on edit; removing a file from the form removes it from the next write. Files already in Firebase Storage are **not** deleted from the bucket when removed from the attachment list.

#### Parent-selection validation rules

When editing a task, the available `parentTaskId` options are filtered so the dropdown excludes:

- the task itself,
- every descendant returned by `_getDescendants(task.id, availableParents)`.

This is the feature’s current client-side cycle-prevention contract.

#### Checkbox toggle update payload

```json
{
  "status": "done | todo",
  "closedBy": "currentUser.uid  // only when status is done",
  "updatedAt": "<serverTimestamp>"
}
```

The checkbox never writes `in_progress`. `closedBy` names the closer so `projectsOnTaskWritten` leaves them out of the "Task closed" alert; reopening a task does not remove it.

#### Delete-task batch behavior

```json
[
  {
    "update": {
      "doc": "each direct child of deleted task",
      "payload": {
        "parentTaskId": "deletedTask.parentTaskId"
      }
    }
  },
  {
    "delete": {
      "doc": "deleted task"
    }
  }
]
```

---

## Derived runtime interfaces

### Dashboard-local state

```json
{
  "_statusFilter": "ProjectStatus | null",
  "_tagFilters": ["String (normalized lowercase tag keys)"]
}
```

### Dashboard computed values

Computed in `ProjectsDashboardBody` (`project_widgets.dart`) from the streamed projects and group tags:

```json
{
  "availableTags": ["String"],
  "statusCounts": {"ProjectStatus": "int"},
  "totalCount": "int",
  "visible": ["ProjectRecord"],
  "nextAction": "BlockerTaskRecord | null"
}
```

`availableTags` (`availableProjectTags`) is computed from the union of:
- reusable group tag documents (`projects_hub_tags`), and
- tag values found on the streamed projects,
then deduplicated by normalized key and sorted by `projectTagKey`.

`statusCounts` and `totalCount` count every streamed project before filtering; they label the status chips (`All · N`, `Planned · N`, ...).

`visible` comes from `filterAndSortProjects(projects, status: _statusFilter, tagKeys: _tagFilters)`. When `_tagFilters` is non-empty, each project must satisfy:

```text
tagKeys.every(project.tags.map(projectTagKey).toSet().contains)
```

`nextAction` is computed from all blockers in the project using:

1. filter out done tasks,
2. require all direct children to be done,
3. sort by priority ascending (lower number first),
4. then due date ascending with `null` last,
5. then title ascending.

### Detail-screen computed values

`ProjectDetailBody` builds a `BlockerTree(tasks, hideCompleted: _hideCompletedTasks)` (`project_widgets.dart`):

```json
{
  "all": ["BlockerTaskRecord — the full snapshot"],
  "visible": ["BlockerTaskRecord"],
  "topLevel": ["BlockerTaskRecord — sorted by compareBlockerTaskPriority"],
  "actionable": ["BlockerTaskRecord — sorted by compareActionableBlockerTasks"],
  "doneCount": "int"
}
```

`ProjectSummaryHero` derives `progress = doneCount / tasks.length` (0 with no tasks). Each task card also receives `openChildCount`, the number of its direct children in `all` that are not done.

When `hideCompleted` is true, `visible` excludes `status == done`, and any remaining task whose parent is hidden is treated as a top-level node for rendering. `BlockerTree.childrenOf(taskId, tasks)` returns a task's direct children.

### Detail-screen visibility toggle input

```json
{
  "control": "FilterChip — label 'Hide completed', or 'Hide completed · N' when N tasks are done",
  "onSelected": "bool selected",
  "stateUpdate": "_hideCompletedTasks = selected"
}
```

This toggle only changes blocker-flow-map rendering (`visible`/`topLevel`). It does not change `actionable`, `doneCount`, or `progress`, which are derived from the full task snapshot.

### Task-form attachment upload state

```json
{
  "_uploading": "bool",
  "_attachments": ["TaskAttachment"]
}
```

- `_uploading` disables the **Add files** button and the **Create/Save task** button during upload.
- `_attachments` is the working list of attachments for the in-progress form. Populated from existing `task.attachments` on edit, empty on create.

### Attachment rendering computed values (per task card)

Computed by `TaskAttachmentsView` using the public helpers `isDisplayableAttachmentUrl` and `isImageAttachment` from `project_widgets.dart`:

```json
{
  "safeAttachments": ["TaskAttachment — trust-filtered: HTTPS + known Firebase Storage host only"],
  "imageAttachments": ["TaskAttachment — where isImageAttachment == true"],
  "fileAttachments":  ["TaskAttachment — where isImageAttachment == false"]
}
```

`safeAttachments.length != task.attachments.length` triggers the hidden-attachments warning banner.

### Render-safety interface for legacy cyclic data

`ProjectDetailBody._node(task, tree, visited)` carries one visited set through recursive rendering of the whole map and returns `SizedBox.shrink()` for a node it has already rendered.

---

## External APIs, functions, and emitted payloads

### Cloud Functions

#### `projectsTriggerClaudeJob` (callable, `functions/projects.js`)

Request: `{ "taskId": "<projects_hub_blockers doc id>" }`. Response: `{ "success": true, "itemType": "task", "itemId": "<taskId>", "jobId": "<claude_jobs doc id>" }`.

| Error code | When |
|---|---|
| `unauthenticated` | No signed-in user |
| `invalid-argument` | Missing `taskId` |
| `permission-denied` | Caller isn't an ACTIVE platform `admin` (checked before the task is inspected), or the task's `appId` isn't `projects` |
| `not-found` | Task doesn't exist |
| `failed-precondition` | Task has neither title nor description |
| `internal` | Writing the job to `claude_jobs` failed (also recorded as `agentDispatchError` on the task) |

The callable checks its platform-admin role through `getAccessIndex(uid)`, which uses trusted Firebase Auth claims. It appends a `claude_jobs` document with `status: "pending"`, `itemType: "task"`, `itemId`, `collection: "projects_hub_blockers"`, and a `ticket` map holding the task title, a composed description (task description, status/priority/due, project context, parent chain, sub-tasks), normalized `attachments`, `groupId`, `submitterId` (the task's `creatorId`), and no `appId`. An open (`pending`/`claimed`) job for the same task is refreshed in place rather than duplicated.

The callable is exported through the shared `_metered_functions` gateway in `functions/projects.js`, which runs it in the function usage context and attributes its module-level usage to Projects. Its request, response, and error contract remain the same.

#### `projectsCreateChangeRequest` (callable, `functions/projects.js`)

Files one Improve Apps bug or feature from a task, links the new request to that task, and relies on the regular ticket-created trigger for agent dispatch.

Request:

```json
{
  "taskId": "projects_hub_blockers document ID",
  "itemType": "bug | feature",
  "relatedAppId": "existing apps document app ID",
  "stepsToReproduce": "Required for bug: at least 20 characters after trimming and collapsing whitespace",
  "expectedBehavior": "Optional bug field",
  "actualBehavior": "Optional bug field"
}
```

`taskId`, `itemType`, and `relatedAppId` are required. The client supplies only the bug reproduction fields in addition to those selectors; title, task description, attachments, and project context are read from Firestore. The server trims reproduction strings before storing; empty optional fields are omitted. Bug reproduction fields are optional when reading legacy bug reports.

Response: `{ "success": true, "itemType": "bug | feature", "itemId": "new request document ID" }`.

| Error code | When |
|---|---|
| `unauthenticated` | No signed-in user |
| `invalid-argument` | Missing task/app selector, invalid item type, or missing/too-short bug reproduction steps |
| `not-found` | Task or selected app does not exist |
| `permission-denied` | Task is outside Projects or the caller lacks Projects read entitlement for the task's group |
| `failed-precondition` | Task has no title or description, or already has a linked request |

The created request document uses `bug_reports` for bugs and `feature_requests` for features. Its shared fields include:

```json
{
  "description": "Task description and Projects origin context",
  "timestamp": "Timestamp",
  "attachments": ["TaskAttachment maps from the task"],
  "imageUrls": ["URLs from image attachments"],
  "upvotedBy": [],
  "downvotedBy": [],
  "voteCount": 0,
  "isClosed": false,
  "relatedAppId": "selected app ID",
  "relatedAppName": "app display name",
  "clientGroupIds": ["project client group IDs"],
  "linkedRecords": [{"collection": "projects_hub_blockers", "id": "task ID"}],
  "sourceProjectId": "project ID",
  "groupId": "task group ID",
  "appId": "improve-apps",
  "creatorId": "caller UID",
  "ownerIds": ["caller UID"],
  "lastModifiedBy": "caller UID",
  "lastModifiedAt": "<serverTimestamp>"
}
```

`lastModifiedBy` / `lastModifiedAt` are the `auditStamp(uid)` fields from `functions/_audit_trail.js`: `bug_reports` and `feature_requests` are on the audit trail, and the stamp makes the create's `audit_events` entry name the caller. See [Platform changes](../platform_changes/developer.md) (PR #3064).

Bug documents additionally store `reporterId`, `reporterEmail`, `stepsToReproduce`, and optional `expectedBehavior`/`actualBehavior`; bug descriptions have no title field, so the task title is included in the description. Feature documents use `requesterId`, `requesterEmail`, `title` (task title or `"Untitled request"`), and `isCompleted: false`. Both include caller email when available.

Creating the request fires the regular Improve Apps ticket-created dispatch path. The resulting agent job and review/live tracking belong to that shared pipeline; Projects consumes the mirrored task state rather than managing a separate job for the linked request.

On successful creation, the same Firestore transaction writes the following fields to the task:

```json
{
  "changeRequest": {
    "itemType": "bug | feature",
    "itemId": "new request document ID",
    "collection": "bug_reports | feature_requests"
  },
  "changeRequestState": "open",
  "relatedAppId": "selected app ID",
  "updatedAt": "<serverTimestamp>"
}
```

#### `projectsListClientGroups` (callable, `functions/projects.js`)

Admin-only lookup for project client-group options.

Request: `{ "appIds": ["app ID", "..."] }`. The server trims, de-duplicates, and limits the input to 30 IDs; an empty/invalid list returns `{ "groups": [] }`.

Response:

```json
{
  "groups": [
    {"id": "group document ID", "name": "group name or ID fallback"}
  ]
}
```

Groups are selected when `installedApps` contains any requested app ID and are sorted by display name. Errors are `unauthenticated` without a signed-in caller and `permission-denied` unless the caller is an active platform admin.

#### Related app options read by the client

The form reads `groups/{activeGroupId}` for `installedApps` (falling back to the legacy `accessibleAppIds` field) and reads the root `apps` collection ordered by `name`. It returns app options with `{ "id": "appId or apps document ID", "name": "app name or ID", "installed": true }`; saved links to apps that are no longer installed remain available for display and editing.

### Change-request lifecycle and emitted notification

`changeRequestLinksSyncBug` and `changeRequestLinksSyncFeature` in `functions/change_requests.js` watch writes to linked requests. The request's `linkedRecords` entry is `{ "collection": "projects_hub_blockers", "id": "task ID" }`. For a task link, the sync updates:

```json
{
  "changeRequestState": "open | queued | in_review | merged | resolved | closed",
  "prUrl": "HTTPS GitHub pull request URL, or field deleted when empty",
  "prState": "open | merged | closed, or field deleted when empty",
  "changeRequestSyncedAt": "<serverTimestamp>"
}
```

The state comes from the request's resolution first, then pull-request state, then queued agent state, otherwise open. A request becoming `resolved` marks its linked task `done` (if not already done). A merely `closed` request leaves the task's status unchanged.

When that completion changes a task and the task creator differs from the request submitter, the server writes one idempotent `notifications/{notificationId}` document for the creator:

```json
{
  "recipientId": "task creator UID",
  "title": "Task completed",
  "body": "\"<task title or Your task>\" is done — its change request is complete.",
  "appName": "Projects",
  "appId": "projects",
  "groupId": "task group ID",
  "context": {"projectId": "project ID", "taskId": "task ID"},
  "isRead": false,
  "createdAt": "<serverTimestamp>"
}
```

The deterministic ID is `projects_task_done_<taskId>_<itemType>_<requestId>_<recipientId>`. The shared notification-created trigger handles downstream in-app and optional push, SMS, or email delivery according to recipient settings. Already-done tasks and creators who submitted the request do not receive a duplicate completion notification.

### HTTP / external APIs

Projects exposes no REST/HTTP endpoints. The three callable Cloud Functions above are its server request/response interfaces.

### Notifications / events emitted by Projects

Projects client code does not write notifications or publish app-local events. Two server-side sources create them, and the shared notification service then delivers them:

- The linked-request lifecycle creates the task-completion notification documented above.
- `projectsOnTaskWritten` (Firestore trigger on `projects_hub_blockers/{taskId}`, `functions/_projects_task_notify.js`) alerts everyone on the project when a task is created ("New task in <project>") or its status moves to `done` ("Task closed in <project>"). Recipients are the project group's non-guest members who can read Projects (`appUserIdsInGroup` in `functions/_notify.js`), minus the actor (`creatorId` for a new task, `closedBy` for a closure) and anyone whose `projects_hub_projects/{projectId}/notification_prefs/{uid}` doc has `muted: true`. When the server closes a task, `closedBy` is cleared and the creator is skipped because they already get "Task completed". Notification ids are `projects_task_<added|closed>_<taskId>_<eventId>_<recipientId>`, with `appId: 'projects'` and `context: {projectId, taskId}`.

Each recipient gets one `notifications/{notificationId}` document, created with `create()` so a redelivered event is a no-op:

```json
{
  "recipientId": "recipient UID",
  "title": "New task in <project title> | Task closed in <project title>",
  "body": "<actor> added \"<task title>\" | <actor> closed \"<task title>\"",
  "appId": "projects",
  "appName": "Projects",
  "groupId": "task group ID",
  "context": {"projectId": "project ID", "taskId": "task ID"},
  "isRead": false,
  "createdAt": "<serverTimestamp>"
}
```

`<project title>` falls back to `a project` and `<task title>` to `Untitled task`. Without an actor name, the body reads `Someone added "<task title>"` or `Closed: "<task title>"`. The actor name is the actor's `users/{uid}` `displayName`, else `name`, else the local part of `email`.

The app writes two inputs for this trigger:

- `closedBy` (the caller's uid) on a task, together with a status change to `done`.
- `notification_prefs/{uid}` (`userId`, `muted`, `updatedAt`) from the project header's bell. This is a `selfKeyed` subcollection: any reader of the project may create, update or delete their own doc, and nobody else's.

### Local persistence

None. The feature does not store draft state in SharedPreferences, local files, or on-device databases.
