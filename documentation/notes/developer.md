# Notes — Developer Guide

## Overview

`packages/notes` is a small Firestore-backed app for plain-text note capture and group-local sharing. The package keeps its implementation deliberately thin:

- one app-scoped Firestore collection: `notes`
- one list screen: `NotesListScreen`
- one detail/editor screen: `NoteDetailScreen`
- one presentational widget file: `notes_widgets.dart`, built on the shared `bluejay_design` system
- one notification client: `NotificationService(appId: 'notes')`, which calls the shared `notificationsSend` callable

The editor keeps `ownerIds` synchronized with `sharedWithIds` on all create and share paths. `notes` is owner-scoped, so `ownerIds` is what decides who can read and edit a note.

## Package layout

```text
packages/notes/lib/
├── constants.dart          # APP_ID = 'notes'
├── notes_list_screen.dart  # owned + shared-with-me list
├── note_detail_screen.dart # create, edit, autosave, share, delete
├── note_autosave.dart      # NoteAutosaver: debounce timer for editor autosaves
└── notes_widgets.dart      # presentational widgets, dialogs, filter/format helpers
```

`notes_widgets.dart` has no Firestore or FirebaseAuth imports. The screens map documents onto `NoteSummary` values and pass callbacks in, so every widget renders in widget tests with fake data (`test/notes_widgets_test.dart`, plus golden-style screenshots in `test/screenshots_test.dart` written to the git-ignored `test/screenshots/out/`). The move onto the design system came with the platform-wide change in PR #3109; see [Platform changes](../platform_changes/developer.md).

Related integration points outside the package:

- `/home/runner/work/bluejay/bluejay/lib/routing/app_router.dart` registers route key `notes`
- `/home/runner/work/bluejay/bluejay/lib/notifications/notification_handlers.dart` registers `_NotesHandler`
- `shared_ui/UserSearchScreen` supplies group-member choices through `GroupMemberDirectory`; it reads `group_members`, not other users' private `users/{uid}` documents
- `/home/runner/work/bluejay/bluejay/packages/shared_services/lib/notification_service.dart` submits the note-share notification request to `notificationsSend`
- `/home/runner/work/bluejay/bluejay/pubspec.yaml` includes `documentation/notes/` as a Flutter asset

## Dependencies

| Dependency | Why it is used |
|---|---|
| `shared_services/scoped_collection.dart` | Group-scoped reads and auto-injected permission fields on create/set |
| `shared_services/notification_service.dart` | Calls `notificationsSend` to create note-share notifications server-side |
| `shared_ui/user_search_screen.dart` | Multi-select picker, backed by `GroupMemberDirectory` |
| `shared_services/group_member_directory.dart` | Reads group-visible member records and supplies recipient UIDs and emails |
| `cloud_firestore` | Firestore reads, writes, streams, and `Timestamp` |
| `firebase_auth` | Current user identity passed in from the launcher |
| `bluejay_design` | Page shell, cards, filter bar, state views, skeletons, status pills, confirm dialogs, and snackbars |
| `shared_ui/initials_avatar.dart` | Recipient avatars in the editor's sharing line |
| `intl` | Formats `lastEdited` in `formatEdited` (cards and editor) |

## Routing and launcher integration

The launcher route key is the same as the app ID:

```dart
'notes': (user) => NotesListScreen(currentUser: user!),
```

Notifications use the same slug. `_NotesHandler` matches `appId == 'notes'`, reads `context['noteId']`, and pushes `NoteDetailScreen(currentUser: user, noteId: noteId)`.

## Firestore model

Notes uses a single `ScopedCollection` declared at file scope in both screens:

```dart
final _notes = ScopedCollection(
  collection: 'notes',
  appId: APP_ID,
);
```

### Stored fields

| Field | Source | Notes |
|---|---|---|
| `groupId` | `ScopedCollection.add/set` | Active group at write time |
| `appId` | `ScopedCollection.add/set` | Always `notes` |
| `creatorId` | `ScopedCollection.add/set` | Current Firebase Auth UID |
| `ownerIds` | Caller + `ScopedCollection.add/set` | Must include creator and every shared recipient |
| `title` | Notes package | Optional string |
| `content` | Notes package | Optional string |
| `lastEdited` | Notes package | `Timestamp.now()` on create/update |
| `sharedWithIds` | Notes package | Recipient UIDs |
| `sharedWithEmails` | Notes package | Recipient emails captured at share time |

There is no `createdAt`, archive flag, tag list, or subcollection model.

## List screen behavior

`NotesListScreen` runs one live query:

```dart
_notes.queryOwned().snapshots()
```

`ScopedCollection.queryOwned()` is the group-scoped `query` plus `ownerIds array-contains <signed-in uid>`; with no signed-in user it matches nothing. Because `ownerIds` holds the creator and every recipient, this one query returns both the notes you created and the notes shared with you. It is also the list shape the owner-scoped rules accept: Firestore rules are not filters, so a list query that does not constrain `ownerIds` (or `creatorId`) to the caller is rejected for anyone below the Notes `:admin` tier.

Each snapshot is sorted client-side by `lastEdited` descending and emitted through a broadcast `StreamController<List<QueryDocumentSnapshot>>`. No composite index is needed. PR #3130 replaced the earlier pair of listeners (`creatorId ==` and `sharedWithIds array-contains`, merged and de-duplicated client-side) with this single owner-scoped query; see [Platform changes](../platform_changes/developer.md).

A listener error is forwarded to the stream controller with `addError`, so the screen shows an error state instead of an endless spinner. `_retry()` cancels the subscription and calls `_setupStreams()` again.

### Rendering

The screen is a `BjPage` titled **My Notes** with an extended **New note** FAB. `BjSnapshotView` picks one of four states from the stream:

| State | Widget |
|---|---|
| Waiting for the first snapshot | `NotesSkeleton`: a search-bar placeholder and six card-shaped skeletons |
| Stream error | Error view titled "Couldn't load your notes", with retry wired to `_retry` |
| No documents | `NotesEmpty`: "Create your first note" with a **New note** button |
| Documents | `NotesBoard` over `docs.map(_summaryFrom)` |

`_summaryFrom` builds a `NoteSummary` per document:

| `NoteSummary` field | Derived from |
|---|---|
| `id` | document ID |
| `title`, `content` | `title` / `content`, defaulting to `''` |
| `lastEdited` | `lastEdited` `Timestamp`, as `DateTime` |
| `sharedWithMe` | `creatorId != currentUser.uid` |
| `sharedCount` | `sharedWithIds` entries other than the current user |

`NotesBoard` holds the search text and a `NotesFilter` (`all`, `mine`, `shared`) in local state and applies `filterNotes()`: `mine` drops `sharedWithMe` notes, `shared` keeps only them, and the query is a trimmed, case-insensitive substring match over title and content. The **Shared with me** chip is hidden unless at least one note has `sharedWithMe`. Matches render as fixed-height (196 px) `NoteCard`s in `BjResponsiveGrid` (minimum tile width 240, up to four columns), under a section header with the match count. Filtering is in memory over the already-loaded list; it issues no extra queries.

`NoteCard` shows `displayTitle` (`(Untitled)` when blank), up to five lines of content (or "No text yet"), `formatEdited(lastEdited)`, and a pill: **Shared with you** when `sharedWithMe`, otherwise **Shared · N** when `sharedCount > 0`. `formatEdited` returns `Today <time>`, `Yesterday`, or `DateFormat.yMMMd()`.

## Detail screen behavior

`NoteDetailScreen` serves four roles:

- create a new note
- load and edit an existing note
- share a note with additional recipients
- delete a note

### Dirty tracking and exit guard

The screen keeps `_initialTitle` and `_initialContent` snapshots. `_isDirty` becomes true whenever either controller differs from that saved baseline.

`PopScope` is the single exit gate for both system and app-bar back navigation:

- not dirty: pop immediately
- dirty: `showNoteUnsavedDialog` asks "Save your changes?" and returns a `NoteExitAction` (**Keep editing** = `cancel`, **Discard** = `discard`, **Save and exit** = `saveAndExit`)
- saving: back navigation is disabled via `canPop: !_isDirty && !_isSaving`

Once an autosave (below) has written the current text the note is no longer dirty, so leaving pops without a prompt. An autosave in flight does not block back navigation; only `_isSaving` does.

### Autosave

Edits to an existing note are written in place without leaving the editor (PR #3290). A new note (`widget.noteId == null`) is never autosaved, so no document is created until the user taps **Save** or **Share**.

`NoteAutosaver` (`note_autosave.dart`) holds the timing and has no Firestore dependency, so `test/note_autosave_test.dart` drives it with fake time:

| Member | Behavior |
|---|---|
| `schedule()` | Restarts a quiet-period timer (`delay`, default 2 seconds); when it fires, `flush()` runs |
| `flush()` | Cancels the timer and runs `save` now. Only one save runs at a time: a flush that arrives while one is in flight runs once more after it finishes |
| `cancel()` / `dispose()` | Drops the pending timer and any queued re-run. A save already in flight still completes |
| `isScheduled` | Whether a save is waiting on the timer |

`NoteDetailScreen` wires it up as follows:

- both text controllers listen with `_onTextChanged`, which updates the dirty state and calls `schedule()` when the note exists, has finished loading, and is dirty
- an `AppLifecycleListener(onHide:)` calls `flush()` when the app or browser tab goes to the background, where a refresh, tab close, or app kill would otherwise lose the pending edits
- `_saveNote()`, the **Discard** exit action, and a confirmed delete call `cancel()`

The `save` callback is `_autosave()`. It returns without writing when the note is new, a manual save is running, nothing is dirty, or both fields are empty (a note cleared to empty is left to the **Save** button's delete prompt). Otherwise it sets `_isAutosaving`, updates `title`, `content`, and `lastEdited` through `_notes.update(...)`, then moves the baseline (`_initialTitle`, `_initialContent`) to the text it wrote and `_lastEdited` to the new timestamp. Text typed while the write was in flight differs from that baseline, so it stays dirty and its own timer is already running. The sharing fields are not part of the payload, so `ownerIds` is not re-sent.

Autosave failures are logged with `debugPrint` and show no snackbar: the pill goes back to **Unsaved changes**, and nothing retries until the next edit, app hide, or manual save. A failing **Save** reports the error.

Because each autosave moves the baseline, **Discard** in the exit dialog drops only the edits made since the last autosave; it does not restore the note to how it was when opened.

### Save behavior

`_saveNote()` handles three branches:

1. **new empty note** → pop without creating anything
2. **existing note cleared to empty** → `showBjConfirm` "Delete this empty note?" (**Delete note** / **Keep editing**) asks whether to delete it
3. **normal save** → create or update Firestore document

Successful saves call `_markSavedState()` before navigating away so a reopened screen starts with a clean baseline.

### Delete behavior

For any existing note, **Delete note** sits in the app bar's `BjOverflowMenu` (disabled while saving). Deletion is confirmed through a destructive `showBjConfirm` titled "Delete this note?" (naming the title when there is one) and then calls `_notes.doc(widget.noteId).delete()`.

Both delete confirmations list `noteDeleteConsequences(sharedCount:, createdByMe:)`: the text is deleted for good; when `sharedCount > 0`, that many recipients lose it; and when the caller is not the creator, the person who shared it loses it too. `sharedCount` counts `_sharedWithIds` other than the current user; `createdByMe` compares the loaded `creatorId` with the current UID.

### Editor layout

`NoteDetailScreen` renders `NoteEditorPage`, a `BjPage` titled "New Note" or "Edit Note" whose actions are a `BjBusyButton` **Save** (badged with a dot while dirty and not saving) and, for existing notes, the overflow menu. While loading, the body is `NoteEditorSkeleton`; otherwise it is `NoteEditorBody`, a card holding:

- `NoteSaveStatus`, a pill driven by `_saveState`: `saving` while `_isSaving` or `_isAutosaving`, else `unsaved` while dirty, else `isNew` for a note with no ID, else `saved`
- "Edited …" from `_lastEdited`, which `_loadNoteData` sets from the stored `lastEdited` and each successful autosave advances
- the title field and the body field (sentence capitalization, body autofocused)
- `NoteSharedWith`, which renders `_sharedWithEmails` as up to four overlapping `InitialsAvatar`s (names are the email local part) with "Only you", "Shared with a and b", or "Shared with a, b +N", plus a **Share** button wired to `_shareNote` (hidden while saving)

Errors and confirmations use `BjSnack` (`error`, `info`, `success`) snackbars.

### Share behavior

`_shareNote()` has two flows:

#### Share from a new unsaved note

1. Rejects completely empty notes with an info snackbar ("Add a title or some text before sharing.")
2. Creates the note first with empty sharing arrays and `ownerIds: [creatorId]`
3. Opens `UserSearchScreen`
4. If the picker returns no users, pops back out and leaves the note created but unshared
5. If users are chosen, updates `sharedWithIds`, `sharedWithEmails`, and `ownerIds`
6. Sends notifications to the newly chosen recipients

#### Share from an existing note

1. Opens `UserSearchScreen`, which loads the active group's `group_members` directory and returns typed `GroupMember` values; guests and `DRAFT` records are excluded
2. Excludes the current user and already-shared users
3. Appends newly selected users onto `_sharedWithIds` / `_sharedWithEmails`
4. Updates the note document with the combined arrays and recomputed `ownerIds`
5. Sends notifications only to the newly added users

Both flows confirm with a success snackbar, "Note shared with N person/people".

## `ownerIds` synchronization contract

`ownerIds` is written as the creator plus every explicitly shared recipient. `notes` is `ownerScoped`, so below the Notes `:admin` tier the rules let a member read, edit, and delete only notes whose `creatorId` is them or whose `ownerIds` contains them. `ownerIds` is therefore the enforced share list, and all create and membership-update paths must keep it synchronized with `sharedWithIds`.

Current code centralizes the mapping in:

```dart
List<String> _ownerIdsFor(List<String> sharedWithIds, {required String creatorId}) {
  return {creatorId, ...sharedWithIds}.toList();
}
```

Every write path that can affect note membership sends `ownerIds` in the same Firestore write:

- create during normal save
- update during normal save
- create during share-before-save
- update during share of an existing note

If a future change adds share removal, it must update `sharedWithIds`, `sharedWithEmails`, and `ownerIds` together in one write.

## Data and permissions

<!-- generated:data-permissions:start -->
<!-- Generated from security/collections.json and security/storage_paths.json by `node scripts/docs/nightly_docs_batch.js render-permissions`. Do not edit between these markers: change the policy table and re-render. -->

**Firestore** — policy from `security/collections.json`, enforced by the generic rule in `firestore.rules`. App tiers are the caller's `<groupId>:<appId>` entitlements (base, `:edit`, `:admin`, `:guest`); "own" docs are those whose `creatorId` is the caller or whose `ownerIds` contains them.

| Collection | Kind | Who reads | Who writes (client) | Notable flags |
|---|---|---|---|---|
| `notes` | tenant | Members of the doc's group with `notes`: `:admin` reads all; other tiers only docs they own | `:admin` any doc; other tiers only docs they own | `ownerScoped` |

- Every rule requires a signed-in `ACTIVE` account; tenant access also needs the doc's `groupId` in the caller's access index (and not in `denied_scopes`). ACTIVE platform admins read every collection (EX-ADMIN-1).
- Client creates of tenant docs must set `creatorId` to the caller and use an auto id, a UUID, the `groupId`, or a `{groupId}__…` key; `groupId`, `appId` and `creatorId` never change on update. "Admin SDK" writes come from Cloud Functions.
- Subcollections not listed follow their parent: readers of the parent read them, editors of the parent write them, and readers may add `comments` docs they author.

<!-- generated:data-permissions:end -->

## Security and authorization

`notes` is declared `ownerScoped: true` in `security/collections.json`:

- **Base, `:edit`, and `:guest` tiers**: a member reads, edits, and deletes only the notes they own (`creatorId` is them, or `ownerIds` contains them). Sharing a note adds the recipient to `ownerIds`, so the share list is the read and write boundary. Recipients can edit a shared note. Holding `:edit` does not grant access to other members' notes.
- **Notes `:admin`**: reads and writes every note in the group.
- **Platform admins**: read every note (EX-ADMIN-1).

Every list query must use `queryOwned()` (or filter `creatorId == uid`). Direct reads such as `_notes.doc(noteId).get()` from a notification deep link succeed only when the caller owns the note or holds Notes `:admin`.

## Notifications

Sharing submits the recipients and notification text to `NotificationService(appId: APP_ID)`, which calls the shared `notificationsSend` callable. The server validates the caller's app entitlement, restricts delivery to active members of the specified group, validates text and context, applies per-sender rate limits, and writes the notification documents.

Key behaviors:

- The client sends one request for all newly selected recipients, with active `groupId`, `appId: 'notes'`, and `recipientIds`
- The callable skips recipients who no longer belong to the group; it rejects a request when no recipients remain eligible
- The callable stamps `senderId`, `isRead: false`, and server `createdAt`
- `NotificationService` returns IDs for created notifications; Notes does not inspect skipped IDs
- failures are logged with `debugPrint`
- notification failure does not roll back note sharing

Notes supplies this sender-controlled payload:

```json
{
  "title": "alice shared a note with you",
  "body": "Project kickoff agenda",
  "appName": "Notes",
  "context": {
    "noteId": "<notes document id>"
  }
}
```

`NotificationService` adds `groupId`, `appId`, and `recipientIds` to the callable request. The stored notification also contains server-owned `recipientId`, `senderId`, `isRead`, and `createdAt` fields.

The notification context used by the app's deep-link handler is:

```json
{
  "noteId": "<notes document id>"
}
```

## Debugging notes

If Notes sharing appears broken, check these in order:

1. the note document contains expected `sharedWithIds`
2. the note document contains matching `ownerIds`
3. the recipient is in the same active group
4. the recipient has app access to `notes`
5. the share notification exists in `notifications`
6. the notification `context.noteId` matches a real note document ID, and the active group still grants access

If a recipient cannot see a shared note, inspect whether its `ownerIds` includes its creator and every UID in `sharedWithIds`. The migration `scripts/firestore_admin/migrations/2026-11-12_owner_scoped_owners.js` (dry-run by default) stamps missing `creatorId`/`ownerIds` fields.
