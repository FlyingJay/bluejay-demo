# Notes — Interfaces

## Overview

Notes has three cross-component data boundaries: the `notes` collection, the group member directory used by the share picker, and the `notificationsSend` callable that creates notification documents.

```text
NotesListScreen / NoteDetailScreen
  ├── ScopedCollection('notes', appId: 'notes')   -> Firestore notes/{noteId}
  ├── UserSearchScreen                           -> group_members/{groupId}__{uid}
  └── NotificationService(appId: 'notes')
        -> notificationsSend callable
        -> Firestore notifications/{notificationId}
```

Notes has no REST endpoint, Storage object, or device-local persistence. Its notification path uses a shared Cloud Function; member lookup uses a shared service.

## Group member picker input

The share flow calls `UserSearchScreen` in multi-select mode. The picker reads the active group's `group_members` directory through `GroupMemberDirectory.group()`; it does not read other users' private `users/{uid}` documents.

Effective directory query:

```text
group_members where groupId == <activeGroupId>
```

The result is cached per group for five minutes and sorted by the displayed label. The picker removes guest and `DRAFT` entries, excludes the current user, and for existing notes excludes UIDs already in `sharedWithIds`. Search matches display name and email username; when the term includes `@`, it matches the full email.

### Directory record shape

```json
{
  "groupId": "group_abc123",
  "uid": "uid_bob",
  "role": "member",
  "email": "bob@example.com",
  "displayName": "Bob",
  "photoURL": "",
  "status": "ACTIVE",
  "isGuest": false,
  "guestName": "",
  "guestEmail": "",
  "joinedAt": "<Timestamp|null>",
  "lastActiveAt": "<Timestamp|null>"
}
```

`groupId` and `uid` identify the member. The remaining fields may be absent in older records; `GroupMember.fromMap` normalizes them to empty strings, `member`/`ACTIVE`, `false`, or `null` as appropriate. The picker returns one `GroupMember` for single-select or `List<GroupMember>` for multi-select; Notes uses each selected member's `uid` and `email`.

## Firestore persistence

### Collection: `notes`

The list query is built from `ScopedCollection.queryOwned()`, which filters by the active `groupId` and by `ownerIds array-contains <signed-in uid>`. `notes` is owner-scoped, so below the Notes `:admin` tier the rules allow reads, updates, and deletes only on notes the caller owns (`creatorId` or `ownerIds`).

All creates use `ScopedCollection.add`, which automatically injects:

- `groupId`
- `appId`
- `creatorId`
- `ownerIds` (defaulting to `[creatorId]` unless explicitly supplied)

Updates and deletes use `.doc(id)` directly, so the existing stored permission fields on the document matter.

### Document schema: `notes/{noteId}`

```json
{
  "groupId": "group_abc123",
  "appId": "notes",
  "creatorId": "uid_alice",
  "ownerIds": ["uid_alice", "uid_bob", "uid_carol"],
  "title": "Project kickoff agenda",
  "content": "1. Introductions\n2. Timeline review\n3. Action items",
  "lastEdited": "2026-09-03T00:00:00Z",
  "sharedWithIds": ["uid_bob", "uid_carol"],
  "sharedWithEmails": ["bob@example.com", "carol@example.com"]
}
```

### Field reference

| Field | Type | Required on stored doc | Writer | Notes |
|---|---|---|---|---|
| `groupId` | `String` | Yes | `ScopedCollection` | Active group ID at create time |
| `appId` | `String` | Yes | `ScopedCollection` | Always `notes` |
| `creatorId` | `String` | Yes | `ScopedCollection` | Author UID |
| `ownerIds` | `List<String>` | Yes | Notes code + `ScopedCollection` | Equals `{creatorId, ...sharedWithIds}`; the rules use it as the share list |
| `title` | `String` | No | Notes code | Empty string allowed |
| `content` | `String` | No | Notes code | Empty string allowed |
| `lastEdited` | `Timestamp` | Yes for created notes | Notes code | Set with `Timestamp.now()` on create, on each save, and on each autosave |
| `sharedWithIds` | `List<String>` | Yes for created notes | Notes code | Recipient UIDs |
| `sharedWithEmails` | `List<String>` | Yes for created notes | Notes code | Emails copied from selected `GroupMember` records |

### Write contracts

#### 1. Create via normal save (`_saveNote`, new non-empty note)

```json
{
  "title": "Optional title",
  "content": "Plain text body",
  "lastEdited": "Timestamp.now()",
  "sharedWithIds": [],
  "sharedWithEmails": [],
  "ownerIds": ["<currentUserUid>"]
}
```

Stored result after `ScopedCollection.add` injection:

```json
{
  "groupId": "<activeGroupId>",
  "appId": "notes",
  "creatorId": "<currentUserUid>",
  "ownerIds": ["<currentUserUid>"],
  "title": "Optional title",
  "content": "Plain text body",
  "lastEdited": "Timestamp.now()",
  "sharedWithIds": [],
  "sharedWithEmails": []
}
```

#### 2. Update via normal save (`_saveNote`, existing non-empty note)

```json
{
  "title": "Updated title",
  "content": "Updated body",
  "lastEdited": "Timestamp.now()",
  "sharedWithIds": ["uid_bob"],
  "sharedWithEmails": ["bob@example.com"],
  "ownerIds": ["<creatorId>", "uid_bob"]
}
```

Important: because `.update()` does not auto-recompute permission fields, Notes explicitly re-sends `ownerIds` on save.

#### 3. Update via autosave (`_autosave`, existing non-empty note)

Sent through `_notes.update(_notes.doc(noteId), ...)` two seconds after the last edit, or when the app or tab is hidden:

```json
{
  "title": "Current title",
  "content": "Current body",
  "lastEdited": "Timestamp.now()"
}
```

`sharedWithIds`, `sharedWithEmails`, and `ownerIds` are not in the payload and keep their stored values. No write is sent for a new note, an unchanged note, or a note whose title and body are both empty.

#### 4. Create during share-before-save (`_shareNote`, new unsaved note)

Initial create payload:

```json
{
  "title": "Draft title",
  "content": "Draft body",
  "lastEdited": "Timestamp.now()",
  "sharedWithIds": [],
  "sharedWithEmails": [],
  "ownerIds": ["<currentUserUid>"]
}
```

Follow-up membership update after picker selection:

```json
{
  "sharedWithIds": ["uid_bob", "uid_carol"],
  "sharedWithEmails": ["bob@example.com", "carol@example.com"],
  "ownerIds": ["<currentUserUid>", "uid_bob", "uid_carol"]
}
```

#### 5. Update during share of an existing note

```json
{
  "sharedWithIds": ["existing_uid", "new_uid"],
  "sharedWithEmails": ["existing@example.com", "new@example.com"],
  "ownerIds": ["<creatorId>", "existing_uid", "new_uid"]
}
```

#### 6. Delete existing note

Operation:

```text
_notes.doc(noteId).delete()
```

There is no soft-delete marker, archive state, or tombstone payload.

### Non-write outcomes

#### New empty note save

No Firestore write occurs. The screen simply pops.

#### Existing note saved after clearing all content

The app first asks for confirmation. If the user confirms, the interface becomes the delete operation above.

#### Share cancelled after creating a new note

The note document remains stored with empty sharing arrays and creator-only `ownerIds`.

## Firestore read/query interfaces

### List query: notes the current user owns

```text
_notes.queryOwned().snapshots()
```

Effective server-side shape:

```text
groupId == <activeGroupId> AND ownerIds array-contains <currentUserUid>
```

Because `ownerIds` holds the creator and every recipient, this returns both the user's own notes and notes shared with them. With no signed-in user the query matches nothing. Firestore rules are not filters: a list query without the `ownerIds` (or `creatorId == uid`) constraint is rejected for callers below Notes `:admin`.

### Read by known document ID

```text
_notes.doc(noteId).get()
```

This path is used when opening an existing note and when a notification deep-link provides `noteId`. It succeeds only when the caller owns the note or holds Notes `:admin`.

### Client-side post-processing contract

On each snapshot the list screen:

1. sorts descending by `lastEdited`
2. emits a `List<QueryDocumentSnapshot>` through a broadcast stream

A listener error is forwarded into the same stream with `addError`; the list renders an error state, and retry cancels and re-opens the listener.

Sorting comparator details:

- if both docs have `lastEdited`, later timestamp sorts first
- if either timestamp is null, comparator returns `0`

## Notification request, response, and stored document

Sharing calls `NotificationService.addForRecipients` once for all newly added recipients. The Notes client does not write `notifications` directly.

Notes supplies:

```dart
await _notifications.addForRecipients(recipientIds, {
  'title': '$senderName shared a note with you',
  'body': displayTitle,
  'appName': 'Notes',
  'context': {'noteId': noteId},
});
```

`NotificationService` constructs this `notificationsSend` callable request, using the active group unless an explicit group ID is supplied:

```json
{
  "groupId": "group_abc123",
  "appId": "notes",
  "recipientIds": ["uid_bob", "uid_carol"],
  "title": "alice shared a note with you",
  "body": "Project kickoff agenda",
  "appName": "Notes",
  "context": {
    "noteId": "note_xyz789"
  }
}
```

The client trims and deduplicates recipient IDs. The callable requires a signed-in sender with the app entitlement in the group (or platform-admin access), validates and bounds text and context, applies per-sender rate limits, and writes notifications only for recipients who still belong to that group. Recipients outside the group are skipped; a request with no eligible recipients is rejected.

Request constraints relevant to Notes:

- `recipientIds` must contain 1–100 valid UIDs. The callable skips group outsiders, and fails if none of the requested recipients belong to the group.
- `title` is required and limited to 200 characters; `body` is limited to 2,000 and `appName` to 80. The server trims and truncates overlong text.
- `context` must be a plain JSON map no larger than 8 KB and no deeper than four levels. Notes sends only the `noteId` string.
- The callable rejects unknown request fields. Notes does not send an action URL or coalescing fields.
- Sender limits are 60 calls per minute, 600 per hour, and 3,000 per day.

### Callable response

```json
{
  "ids": ["notification_abc", "notification_def"],
  "skippedRecipientIds": ["uid_left_group"]
}
```

`NotificationService` converts `ids` to document references. Notes does not inspect `skippedRecipientIds`; callable failures are caught and logged by Notes after the note share has already been saved.

### Stored schema: `notifications/{notificationId}`

```json
{
  "groupId": "group_abc123",
  "appId": "notes",
  "recipientId": "uid_bob",
  "senderId": "uid_alice",
  "title": "alice shared a note with you",
  "body": "Project kickoff agenda",
  "appName": "Notes",
  "isRead": false,
  "createdAt": "<server Timestamp>",
  "context": {
    "noteId": "note_xyz789"
  }
}
```

| Field | Type | Required | Source | Notes |
|---|---|---|---|---|
| `groupId` | `String` | Yes | Callable | Active group context |
| `appId` | `String` | Yes | Callable | Always `notes` |
| `recipientId` | `String` | Yes | Callable | One document per eligible recipient |
| `senderId` | `String` | Yes | Callable | Authenticated sender UID |
| `title` | `String` | Yes | Notes code | `"<senderName> shared a note with you"` |
| `body` | `String` | Yes | Notes code | Note title, or `Untitled Note` when blank |
| `appName` | `String` | Yes | Notes code | Always `Notes` |
| `isRead` | `bool` | Yes | Callable | Always `false` on create |
| `createdAt` | `Timestamp` | Yes | Callable | Server timestamp |
| `context.noteId` | `String` | Yes | Notes code | Shared note document ID |

### Notification generation rules

- `senderName` is the part of the current user's email before `@`
- if the sender email is null, `senderName` falls back to `Someone`
- if the note title is blank, `body` falls back to `Untitled Note`
- the callable validates bounded text and a small plain-JSON context, and rate-limits each sender
- the server may skip recipients no longer in the group; Notes does not surface the skipped-ID list
- notification errors are caught and logged after the share write; a failed notification does not roll back sharing

## Notification input / deep-link contract

`lib/notifications/notification_handlers.dart` registers `_NotesHandler` with this behavior:

```text
if appId == 'notes' and context.noteId is a String:
  push NoteDetailScreen(currentUser: user, noteId: context.noteId)
```

Required payload shape:

```json
{
  "noteId": "<notes document id>"
}
```

No additional routing keys are read.

## In-memory screen state interfaces

### `NotesListScreen`

```json
{
  "subscription": "StreamSubscription on _notes.queryOwned().snapshots()",
  "output": "Stream<List<QueryDocumentSnapshot>> (sorted by lastEdited; errors forwarded via addError)"
}
```

Each document is mapped to a `NoteSummary` (in `notes_widgets.dart`) before rendering:

```json
{
  "id": "note_xyz789",
  "title": "Project kickoff agenda",
  "content": "1. Goals\n2. Timeline",
  "lastEdited": "DateTime? from lastEdited",
  "sharedWithMe": false,
  "sharedCount": 2
}
```

| Field | Type | Source |
|---|---|---|
| `id` | `String` | Document ID |
| `title` | `String` | `title`, default `''`; `displayTitle` is `(Untitled)` when empty |
| `content` | `String` | `content`, default `''` |
| `lastEdited` | `DateTime?` | `lastEdited` `Timestamp` |
| `sharedWithMe` | `bool` | `creatorId != currentUser.uid` |
| `sharedCount` | `int` | `sharedWithIds` entries other than the current user |

`NotesBoard` keeps the search text and a `NotesFilter` (`all`, `mine`, `shared`) in widget state; neither is persisted or sent to Firestore.

### `NoteDetailScreen`

```json
{
  "title": "TextEditingController.text",
  "content": "TextEditingController.text",
  "isLoading": true,
  "isSaving": false,
  "isAutosaving": false,
  "isDirty": false,
  "sharedWithIds": ["uid_bob"],
  "sharedWithEmails": ["bob@example.com"],
  "initialTitle": "Title as last loaded, saved, or autosaved",
  "initialContent": "Content as last loaded, saved, or autosaved",
  "creatorId": "uid_alice",
  "lastEdited": "DateTime? loaded from lastEdited and advanced by each autosave, shown as 'Edited …'"
}
```

The screen also owns a `NoteAutosaver` (`note_autosave.dart`):

```json
{
  "save": "Future<void> Function() (the screen passes _autosave)",
  "delay": "Duration, default 2 seconds",
  "isScheduled": "bool, true while the quiet-period timer is active"
}
```

| Method | Effect |
|---|---|
| `schedule()` | Restart the quiet-period timer; `flush()` runs when it fires |
| `flush()` | Cancel the timer and run `save` now; a call made during a running save queues exactly one re-run |
| `cancel()` | Drop the pending timer and any queued re-run |
| `dispose()` | Same as `cancel()` |

## Interfaces that do not exist

Notes currently has none of the following:

- no HTTP endpoints
- no file uploads
- no background jobs owned by the Notes package
- no analytics/event bus payloads defined in-package
- no local cache or offline draft file format
