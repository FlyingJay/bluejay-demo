
# Bluejay Storage Permission System

This document describes how Firebase Storage files are isolated by group (tenant) in the
Bluejay platform, mirroring the Firestore permission model described in
`FIRESTORE_PERMISSIONS.md`.

---

## 1. Overview

### Relationship to Firestore Rules

The Storage rules mirror `firestore.rules` as closely as the Storage rules engine
allows:

| Concept | Firestore | Storage |
|---------|-----------|---------|
| Path | `{collection}/{id}` | `groups/{groupId}/apps/{appId}/{folder}/{file}` |
| Group isolation | `groupId` field in doc | `groupId` wildcard in path |
| App isolation | `appId` field in doc | `appId` wildcard in path |
| Access check | `inTenant()` then detail | `inTenant()` then entitlements (`grantTenant*`) |
| SDK wrapper | `ScopedCollection` | `ScopedStorage` |

### How Group Isolation Is Enforced

Every tenant-scoped file is stored under:

```
groups/{groupId}/apps/{appId}/{folder}/{file}
```

The `groupId` and `appId` wildcards come from the **storage path itself** (not
metadata), so the client cannot spoof them. The security rules extract them as
named captures and pass them to the tenant grants (`grantTenantRead`,
`grantTenantCreate`, `grantTenantUpdate`, `mayEditStored`), which read the same
access index document (`users/{uid}/metadata/access_index`) that the Firestore
rules use. The file's metadata must name the same `groupId` and `appId`.

---

## 2. Security Rules

`storage.rules` (plans/firestore-rules §4.11, T16) is generated from one
table: every object path belongs to one **path family** in
`security/storage_paths.json`, and the family says what it grants. Every
family is enforced in production (stage 6, 2026-11-06); stage 7 removed the
`open`/`enforced` switch, so the table and the rules in the repo are what
production runs. A path no family claims (`unmatched`) is denied.

`read`/`write` are `signedIn`, `none` or `block`. `signedIn` and `none` are
generic: `node security/generate.js` renders the signedIn reads into the
generated section of `storage.rules`, and `none` needs no rule at all.
`block` means the family's own hand-written match blocks (`matchBlocks`)
decide; `security/check_rules_exceptions.js` approves exactly the blocks the
table declares. To add a path family: add it to the table (with `what`,
`why`, `reviewed`), regenerate, and run the emulator suite
(`security/rules-tests`, `test/storage.test.js`).

### Rules per family

| Family | Paths | Read | Write |
|--------|-------|------|-------|
| `group_apps` (tenant) | `groups/{g}/apps/{a}/**` | `inTenant(g)` and any tier of `{g}:{a}`; a guest only their own files in the app's `guestWritableFolders`; ACTIVE platform admins (EX-ADMIN-1) | create: `inTenant(g)`, a member tier, or `:guest` in one of the app's `guestWritableFolders` (`storage_paths.json`: the first folder under the app), metadata `creatorId == uid`, `groupId == g`, `appId == a`. Overwrite/update/delete: `:edit`/`:admin` any file, base tier own files, `:guest` own files in `guestWritableFolders` only; `groupId`/`appId` stay equal to the path; `creatorId` stays or becomes the writer. A stored file in one of the app's `retainedFolders` (`storage_paths.json`, the first folder under the app) takes no client overwrite, update or delete at all: attachments regulated records point at (App Maker `app_request_media`, Improve Apps `bug_reports_media`/`feature_request_media`, Signatures `signature_documents`); only the Admin SDK removes one |
| `group_logo` | `groups/{g}/logo.jpg` | signed in | group admins of `g` (`adminIds`, or `{g}:groups:admin`), ACTIVE platform admins and developers, a group's creator at `groups/temp_{uid}/logo.jpg` |
| `group_logo_renditions` | `groups/{g}/logo_thumb.png`, `logo_print.png` | signed in | none (functions/app_icons.js) |
| `published` | `published/**` | signed in | none (T27's publicPublish) |
| `app_icons` | `app_icons/**` | signed in | ACTIVE platform admins and developers |
| `app_icons_thumbs` | `app_icons_thumbs/**` | signed in | none |
| `profile_pictures` (EX-PROFILE-PIC-1) | `profile_pictures/{uid}/{file}`; legacy flat `profile_pictures/{file}` | owner, users sharing a group, ACTIVE platform admins (get only); flat: signed in (get only) | `{uid}` only, metadata `creatorId == uid`; flat: none |
| `chat_images` | `chat_images/**` | signed in | none |
| `server_only` | `warehouse_private/**`, `blue_ji_docs_corpus/**` | none | none |
| `legacy_*` (M8) | `users/`, `shared_files/`, `public/`, `gallery_photos/`, `wood_shop/`, `photo_albums/`, `bug_reports_media/`, `feature_request_media/`, `recipe_photos/`, `qr_codes/`, `property_images/`, `naic_sight/` | none | none |
| `removed_apps` | `recorder_audio/`, `video_editor_temp/`, `video_editor_merged/` | none | none |
| `unmatched` | everything else | none | none |

What the target deliberately does **not** do: ownership never grants without
an entitlement in the path's group (D1), `visibility` metadata is never read
(D2: public files live under `published/`), and there is no clearance check
(metadata values are strings); stage 7's
`scripts/firestore_admin/migrations/2026-11-06_strip_visibility.js` removed
the leftover `visibility` key from object metadata (555 objects, run
2026-11-06). The legacy prefixes
grant nothing: M8
(`scripts/firestore_admin/migrations/2026-11-05_migrate_storage_legacy.js`)
moved them into `groups/{g}/apps/{appId}/{folder}/…`: each `legacy_*`
family's `migrate: { appId, folder }` names the app and the ScopedStorage
folder that app writes today, so a migrated file sits where a new upload
would. M8 runs in three steps: a dry run (default), `--confirm` (server-side
copy with ScopedStorage metadata and the source's download token, then a
backed-up rewrite of every Firestore URL/path that names a moved object),
and, once the apps are checked, `--delete-originals --confirm`. All three
ran in production on 2026-11-06 (191 objects copied and their originals
deleted, 84 Firestore docs rewritten).
`scripts/check_gateways.js` (`storage-closed-prefix`) keeps clients from
naming a closed prefix in `ScopedStorage.platform(root:)` or `refForPath`.

Stored token download URLs bypass the rules for anyone holding them; T17
and M9 (not built yet) are to replace them with short-lived signed URLs for
sensitive files (signatures, commercial-property documents, CE certificates).
`functions/storage_usage.js`' `storageGetFileDownloadUrl` already issues
signed URLs, but no client calls it yet.

### Deploying

`storage.rules` deploys with `firestore.rules`, through
`.github/workflows/deploy-rules.yml` (`services: storage` or `both`). Rules
that read the access index make a cross-service `firestore.get()`, so the
Firebase Storage service agent must hold
`roles/firebaserules.firestoreServiceAgent` (a one-time grant, done before the
stage 6 deploy; `security/RULES_ROLLBACK.md`). The workflow's preflight step
checks it before every Storage deploy.
`node security/tools/storage_rules_api_smoke.js` checks the rules' decisions
on the production rules engine (read-only).

---

## 3. The `ScopedStorage` SDK Class

`ScopedStorage` in `packages/shared_services/lib/scoped_storage.dart` is the
storage analogue of `ScopedCollection`. It automatically scopes every path and
injects the required permission metadata.

### Setup

Declare one `ScopedStorage` instance per storage folder at file level (outside
any class), just like `ScopedCollection`:

```dart
// lib/constants.dart
// ignore: constant_identifier_names
const APP_ID = 'my_app';

// lib/my_screen.dart
import 'package:shared_services/scoped_storage.dart';
import 'constants.dart';

final _photos = ScopedStorage(
  folder: 'my_photos',   // sub-folder within apps/{appId}/
  appId: APP_ID,
);
```

### API

| Method | Storage analogue of | Description |
|--------|--------------------|-|
| `upload(fileName, bytes)` | `ScopedCollection.add(data)` | Upload bytes; UUID prefix + metadata injected |
| `putBytes(ref, bytes, {...})` | — | Upload bytes to a ref from `ref`/`newRef`; metadata injected; returns the `UploadTask` (progress) |
| `ref(path)` | `ScopedCollection.doc(id)` | Reference to an existing file for reads/deletes |
| `newRef(fileName)` | `ScopedCollection.doc(newId)` | Reference with UUID prefix for caller-driven upload |
| `buildMetadata({...})` | — | SettableMetadata with permission fields injected |
| `list()` | `ScopedCollection.query` | List all files in this app's folder |
| `ScopedStorage.platform(root:, appId:, groupId:)` | — | Same API for a fixed platform-level path (profile pictures, app icons, group logos) |
| `ScopedStorage.refForPath(fullPath)` / `refFromURL(url)` | — | Reference to any existing object (a saved `storagePath` or download URL) for reads/deletes |

`ScopedStorage` is the only way to reach Firebase Storage from Dart:
`scripts/check_gateways.js` (blocking CI) fails on `FirebaseStorage.instance`
or a raw `putData`/`putFile` anywhere but the gateway files
(`scoped_storage.dart`, `platform_service_mobile.dart`,
`platform_service_web.dart`). `putBytes` and
`PlatformService.uploadImageFile`/`uploadGenericFile` require metadata from
`buildMetadata()` with a non-empty `creatorId`, `groupId` and `appId`; a
platform-wide file stamps `ScopedStorage.platformNoGroupId` (`~none`) as its
group. Usage Meter attributes stored bytes by that metadata
(`functions/usage_storage.js`), believing a claimed group only if the
creator is a member of it.

### Injected Metadata Fields

Every file uploaded through `ScopedStorage` automatically receives:

| Metadata key | Value |
|-------------|-------|
| `creatorId` | Current user UID (`FirebaseAuth.instance.currentUser.uid`) |
| `groupId` | Active group ID |
| `appId` | Constructor `appId` parameter |

There is no `visibility` key: no rule reads it (D2), and `buildMetadata()` drops
it even from `extraMetadata`. A file other groups must see is published: the
`publicPublish` callable copies a published doc's `fileFields` under
`published/`, read with `ScopedStorage.published(path)`.

### Usage Patterns

**Uploading bytes (web or any bytes-available case):**

```dart
final ref = await _photos.upload(
  'photo.jpg',
  bytes,
  contentType: 'image/jpeg',
);
final url = await ref.getDownloadURL();
```

**Uploading via PlatformService (mobile — avoids reading full file into memory):**

```dart
final storageRef = _photos.newRef('photo.jpg');
await platformService.uploadImageFile(
  storageRef,
  xFile,
  metadata: _photos.buildMetadata(contentType: 'image/jpeg'),
);
final url = await storageRef.getDownloadURL();
```

**Reading / deleting an existing file (URL from Firestore):**

```dart
// Use ScopedStorage.refFromURL() when you have a download URL
// (ScopedStorage.refForPath() for a saved full path).
await ScopedStorage.refFromURL(file.downloadUrl).delete();
```

**Listing files:**

```dart
final result = await _photos.list();
for (final item in result.items) {
  print(item.fullPath);
}
```

**Subfolder paths (e.g., per-album photos):**

```dart
// Bake the dynamic segment into `folder` when creating the instance.
final albumStorage = ScopedStorage(
  folder: 'album_photos/${widget.albumId}',
  appId: APP_ID,
);
final storageRef = albumStorage.ref(fileName);
```

---

## 4. Migrating a Package to `ScopedStorage`

Follow these steps when introducing Storage to a new package or migrating an
existing one:

### Step 1 — Verify `shared_services` dependency

```yaml
# pubspec.yaml
dependencies:
  shared_services:
    path: ../shared_services
```

### Step 2 — Declare a `ScopedStorage` instance

```dart
// At file level, outside any class:
final _myFiles = ScopedStorage(folder: 'my_folder', appId: APP_ID);
```

### Step 3 — Replace direct `FirebaseStorage` calls

| Old (❌ do not use in packages/) | New (✅) |
|----------------------------------|----------|
| `FirebaseStorage.instance.ref('my_folder/$fileName')` | `_myFiles.newRef(fileName)` |
| `storageRef.putData(bytes)` | `await _myFiles.upload(fileName, bytes)` |
| `storageRef.putData(bytes, SettableMetadata(...))` | `await _myFiles.putBytes(storageRef, bytes, contentType: ...)` |
| `platformService.uploadImageFile(ref, file)` | `platformService.uploadImageFile(ref, file, metadata: _myFiles.buildMetadata())` |
| `FirebaseStorage.instance.refFromURL(url)` | `ScopedStorage.refFromURL(url)` |

### Platform-level paths (`ScopedStorage.platform`)

These keep their fixed, non-group paths (storage.rules match the path), but
still upload through `ScopedStorage.platform(...)` so every object carries
`creatorId`/`groupId`/`appId` metadata:

- **Profile pictures** (`profile_pictures/{uid}/{file}`) — platform-wide user
  avatars, written only by that uid (`appId: 'me'`, group `~none`).
- **Group logos** (`groups/{groupId}/logo.jpg`) — written by the group's
  admins (`appId: 'groups'`, `groupId:` the group).
- **App icons** (`app_icons/**`) — managed by platform admins
  (`appId: 'app-manager'`, group `~none`).
- **Chat images** (`chat_images/**`) — legacy, read-only; new uploads use
  `groups/{groupId}/apps/chat/images/**`.

---

## 5. Summary of Current Implementations

Every `ScopedStorage(folder:, appId:)` in `packages/` (files live under
`groups/{groupId}/apps/{appId}/{folder}/`):

| Package | Folder | Notes |
|---------|--------|-------|
| `ai_pipelines` | `{runId}` | Pipeline run artifacts |
| `app_maker` | `app_request_media` | Request attachments |
| `bug_reports` | `bug_reports_media` | Report screenshots |
| `chats` | `images` | Chat images (the `chat` app; a `guestWritableFolders` entry, so a portal client in a conversation attaches their own images) |
| `commercial_property` | `uploaded_documents` | Application documents |
| `continuing_education` | `certificates` | Course certificates |
| `cookbook` | `recipe_photos`, `recipe_step_photos` | Recipe images |
| `course_of_construction` | `property_images` | Property images |
| `feature_voting` | `feature_request_media` | Idea attachments |
| `gallery_app` | `gallery_photos` | Images |
| `naic_sight` | `naic_sight` | CSV processing inputs |
| `photo_albums` | `album_photos/{albumId}` | Per-album photos |
| `projects` | `projects_hub_task_files` | Task attachments |
| `qr_code` | `qr_codes` | Generated QR PNG exports |
| `rented_dwelling` | `property_images` | iClarify API image cache |
| `sell` | `wood_shop` | Product images (folder name kept from the retired Wood Shop Admin) |
| `shop_chat` | `product_request_chat_images` | Order chat images |
| `signatures` | `signature_documents` | Documents to sign |
| `storage` | `files` | General file sharing (public files are published, D2) |
| `storage` | `client_uploads` | Portal clients' uploads to the business (a `guestWritableFolders` entry: a client writes and reads only their own; `storageRegisterClientUpload` records each in `files`) |
| `town_square` | `town_square_media` | Board media |
| `vendor_market_core` | `listing_photos` | Listing photos (published copies under `published/`) |
