# Storage — Interfaces

## Overview

Storage is a group-scoped file-sharing feature built on Firestore metadata documents in `files` and file blobs in Firebase Storage under the app-scoped `files/` folder. It reads published file projections from `public_files`, app-level usage rollups from `storage_usage`, group admin data from `groups`, and sends share alerts through `notificationsSend`. Portal clients read server-written `client_files` copies and upload to the app-scoped `client_uploads/` folder. Group plans come from the `storageBillingStatus` / `storageBillingSetPlan` callables, backed by the server-only `storage_billing` collection. Platform Usage Meter separately records object attribution in `usage_storage_objects` and `usage_storage`, and usage metrics in `usage_daily`; these names are distinct from the Storage app's `storage_usage` collection.

## Firestore Documents

### `files/{fileId}`

Documents are written through `ScopedCollection(collection: 'files', appId: 'storage')`, so new writes also receive `groupId`, `appId`, `ownerIds`, and `creatorId` automatically. Client queries are filtered by active `groupId`; `appId` is written to documents and checked by Firestore rules, not added as a query filter by `ScopedCollection`.

| Field | Type | Required | Description |
|---|---|---|---|
| `downloadUrl` | `String` | Yes for current writes | Current uploads persist `''` for both public and private files. Legacy records may contain a URL; current public downloads resolve a URL from the published copy, while private downloads use the authenticated streaming endpoint. The signed-URL callable remains available to authorized callers. |
| `storagePath` | `String` | Yes | Canonical tenant Storage object path used for deletion and authorized private downloads. A published projection has a different `storagePath` for its copied object. |
| `fileName` | `String` | Yes | Original uploaded file name, including extension. |
| `displayName` | `String` | No | User-supplied friendly name shown in the UI. |
| `userId` | `String` | Yes | Owner/uploader UID. |
| `userEmail` | `String?` | No | Owner email used for display labels; may be null for auth providers/users without email. The Dart model converts a missing value to `''`. |
| `size` | `int` | Yes | File size in bytes. |
| `createdAt` | `Timestamp` | Yes | Client `Timestamp.now()` recorded after the object upload completes. |
| `isPublic` | `bool` | No | Publication flag. A `true` file is published (`publicPublish`, `publishWhen: {isPublic: true}`): its projection goes to `public_files/{groupId}__{fileId}` and the object is copied under `published/`, which any signed-in user may read. The `files` doc itself stays readable only inside its group. Missing values default to `true` when read for legacy compatibility. |
| `sharedWithIds` | `String[]` | Yes | UIDs explicitly shared on the file, whether it is public or private. |
| `sharedWithEmails` | `String[]` | Yes | Email snapshots for shared users when available; may have fewer entries than `sharedWithIds` if profiles do not include email. |
| `contentType` | `String?` | No | Written only by `storageRegisterClientUpload`, from the object's metadata. |
| `fromClient` | `bool` | No | Server field. `true` on a portal client's upload; set only by `storageRegisterClientUpload`. |
| `clientUploaderUid` | `String` | No | Server field. The uploading client's UID; set only by `storageRegisterClientUpload`. |
| `isFolder` | `bool` | No | `true` on a folder (`_storage_folders.js`): no stored object (`storagePath` and `downloadUrl` are `''`, `size` is `0`, `isPublic` is `false`). Folders are left out of the `storage_usage` totals. |
| `parentId` | `String` | No | The folder this item is in; absent at the top level. Written by its owner (upload, New folder, Move to folder). Only the folder owner's own items inherit a folder's sharing, so filing an item under someone else's folder id shares nothing. |
| `clientUids` | `String[]` | No | Server field. The portal clients this file is about: clients in `sharedWithIds` plus `clientUploaderUid`. Kept by the client-link triggers (`functions/_client_links.js`), which mirror the file to `client_files/{fileId}`. |

Example document:

```json
{
  "downloadUrl": "",
  "storagePath": "groups/group_123/apps/storage/files/uuid_budget.xlsx",
  "fileName": "budget.xlsx",
  "displayName": "Quarterly budget",
  "userId": "uid_alice",
  "userEmail": "alice@example.com",
  "size": 182044,
  "createdAt": "2026-11-05T13:20:00Z",
  "isPublic": false,
  "sharedWithIds": ["uid_bob"],
  "sharedWithEmails": ["bob@example.com"],
  "groupId": "group_123",
  "appId": "storage",
  "ownerIds": ["uid_alice"],
  "creatorId": "uid_alice"
}
```

A client upload's document (id `{groupId}__client_<first 32 hex chars of sha256(storagePath)>`, one per stored object):

```json
{
  "groupId": "group_123",
  "appId": "storage",
  "creatorId": "uid_client",
  "ownerIds": ["uid_client"],
  "userId": "uid_client",
  "userEmail": "client@example.com",
  "fileName": "receipt.pdf",
  "size": 48211,
  "contentType": "application/pdf",
  "storagePath": "groups/group_123/apps/storage/client_uploads/uuid_receipt.pdf",
  "downloadUrl": "",
  "isPublic": false,
  "sharedWithIds": [],
  "sharedWithEmails": [],
  "fromClient": true,
  "clientUploaderUid": "uid_client",
  "clientUids": ["uid_client"],
  "createdAt": "<server timestamp>"
}
```

`userEmail` is the membership's `clientEmail`. A `displayName` is stored only when the request sends one; the Storage client view does not.

### `client_files/{fileId}`

Server-written client-safe copy of a `files` doc, kept by the client-link triggers whenever `clientUids` is non-empty and deleted when it empties. Clients read it (`clientReaderListField: "clientUids"`); see the generated table in the [Developer Guide](developer.md#data-and-permissions). It holds the projected fields plus the tenant fields and `clientUids`. A member's file shared with a client:

```json
{
  "fileName": "Proposal.pdf",
  "displayName": "Proposal",
  "size": 182044,
  "createdAt": "2026-11-12T15:00:00Z",
  "groupId": "group_123",
  "appId": "storage",
  "creatorId": "uid_alice",
  "clientUids": ["uid_client"]
}
```

Projected fields, copied only when present on the source: `fileName`, `displayName`, `size`, `contentType`, `mimeType`, `createdAt`, `fromClient`, `clientUploaderUid`, `isFolder`. A shared folder gets a copy too (with `isFolder: true`); `loadClientFiles` leaves it out of the client's list, and each item in it has its own copy. The tenant fields are `groupId`, `appId` and `creatorId`. `storagePath`, owner and share fields are not copied. The copy uses the source document's id, which is the `fileId` the client sends to `storageDownloadFile`.

### `storage_billing/{groupId}`

Server-only (kind `server`, readable by its `payerId` and platform admins; on the audit trail under Storage). Written by `storageBillingSetPlan` and `storageBillingMonthlyOverage`; the app reads it only through `storageBillingStatus`.

| Field | Type | Description |
|---|---|---|
| `groupId`, `appId` | `String` | The group; always `"storage"`. |
| `plan` | `String` | `"free"` or `"pay_as_you_go"` (`"unlimited"` comes from config, never the doc). |
| `history` | `Array<{plan, atMs, by}>` | Plan changes, oldest first, last 100 kept; used to bill only the days on pay as you go. |
| `currency` | `String` | Price currency at the last change. |
| `payerId`, `payerEmail` | `String?` | The admin who turned on pay as you go; `null` on free. |
| `pricePerGiBMonth`, `freeTierGiB` | `number` | Price and free tier accepted with pay as you go. |
| `payGoSince` | `Timestamp` | When pay as you go was last turned on. |
| `lastBilledPeriod` | `String` | Last `YYYY-MM` billed. |
| `lastOverageGiBMonths` | `number` | That month's GiB-months above the free tier. |
| `createdAt`, `updatedAt` | `Timestamp` | Bookkeeping, plus the audit stamp. |

Optional platform config `platform_config/storage_billing`: `freeTierGiB` (default 50), `markup` (2), `cadPerUsd` (1.4), `pricePerGiBMonth` (overrides the derived price), `currency` (`"CAD"`), `unlimitedGroupIds` (`["bluejay"]`).

### `storage_usage/{usageDocId}`

`storage_usage` documents are read by the app and written by `onStorageFileWritten` in `functions/storage_usage.js`. The handler subtracts the old file contribution and adds the new one, so creates, updates, moves, and deletes adjust totals. It ignores documents without `appId: "storage"`.

| Field | Type | Required | Description |
|---|---|---|---|
| `groupId` | `String` | Yes | Active group ID for the usage rollup. |
| `appId` | `String` | Yes | Always `"storage"`. |
| `userId` | `String` | Yes | Either a real uploader UID or the sentinel `"__group_total__"`. |
| `kind` | `String` | Yes | `"user_total"` or `"group_total"`. |
| `totalBytes` | `int` | Yes | Aggregate size across tracked files. |
| `totalFiles` | `int` | Yes | Aggregate file count. |
| `ownerIds` | `String[]` | Yes | `[userId]` for per-user totals, `[]` for group totals. |
| `creatorId` | `String` | Yes | Always `"system"`. |
| `updatedAt` | `Timestamp` | Yes | Last server-side delta update. |

Example per-user rollup:

```json
{
  "groupId": "group_123",
  "appId": "storage",
  "userId": "uid_alice",
  "kind": "user_total",
  "totalBytes": 182044,
  "totalFiles": 1,
  "ownerIds": ["uid_alice"],
  "creatorId": "system",
  "updatedAt": "2026-11-05T13:21:00Z"
}
```

Example group rollup:

```json
{
  "groupId": "group_123",
  "appId": "storage",
  "userId": "__group_total__",
  "kind": "group_total",
  "totalBytes": 982044,
  "totalFiles": 7,
  "ownerIds": [],
  "creatorId": "system",
  "updatedAt": "2026-11-05T13:21:00Z"
}
```

### Platform-wide reads: `groups/*`

The app checks whether the current user is a group admin through `BluejayFirestore.forApp("storage")`, a metered raw Firestore gateway. It queries `groups` by the active `groupId`, limits to one document, and reads:

| Field | Type | Required | Description |
|---|---|---|---|
| `adminIds` | `String[]` | No | Group admin UIDs. Used to decide whether the group-wide storage usage banner should be shown. |

```json
{
  "collection": "groups",
  "where": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}],
  "limit": 1,
  "readFields": ["adminIds"]
}
```

### Group-member search: `group_members`

The share picker loads the active group's member directory through `GroupMemberDirectory.group(groupId)`, which queries `group_members` by `groupId` and caches the result for five minutes. It returns `GroupMember` values; the Storage screen sends only selected `uid` values to `storageShareFile`. The picker excludes guests, `DRAFT` accounts, the current user, and IDs already in `sharedWithIds`.

```json
{
  "collection": "group_members",
  "where": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}],
  "mode": "get",
  "cacheTtl": "5 minutes"
}
```

| Field | Type | Description |
|---|---|---|
| `groupId` | `String` | Group containing the directory member. |
| `uid` | `String` | Member UID returned as `GroupMember.uid`. |
| `role` | `String` | Group role; defaults to `member` in the client model. |
| `email` | `String` | Lower-cased sign-in email, or `''`. |
| `displayName` | `String` | Display name, or `''`. |
| `photoURL` | `String` | Profile image URL, or `''`. |
| `status` | `String` | Membership status; defaults to `ACTIVE` in the client model. |
| `isGuest` | `bool` | Guest marker. |
| `guestName`, `guestEmail` | `String` | Guest profile fields; guests are filtered from this picker. |
| `joinedAt`, `lastActiveAt` | `Timestamp?` | Optional membership timestamps. |

This directory is the client-facing source for another member's identity; the picker does not read other users' `users/{uid}` documents.

### Platform-wide reads: `users/{userId}` (Cloud Functions)

`storageShareFile` resolves recipient emails from the `users` collection before updating `sharedWithEmails`.

Fields used:

| Field | Type | Required | Description |
|---|---|---|---|
| `email` | `String` | No | Recipient email snapshot copied into file metadata when present. |

## Client Firestore Query Interfaces

The app's `files` and `storage_usage` reads use `ScopedCollection(..., appId: "storage")`. Its `.query` adds the active `groupId` equality filter (or a no-match sentinel when there is no active group). The app ID selects the metered Firestore context and is written by `add`/`set`; Firestore rules validate the stored `appId`. Results are ordinary Firestore `QuerySnapshot` objects containing `docs`, each tenant file document mapped by `SharedFile.fromFirestore`. The separate group-admin read uses `BluejayFirestore.forApp("storage")`, as described above.

### Public tab query

```json
{
  "collection": "public_files",
  "where": [{"field": "sourceGroupId", "op": "==", "value": "<activeGroupId>"}],
  "sort": "createdAt desc, client-side (no composite index)"
}
```

The tab reads the active group's published projections (`PublicCollection(source: 'files').whereSourceGroup(activeGroupId)`), maps them with `SharedFile.fromPublished`, and sorts by `createdAt` in memory. It downloads the published copy with `ScopedStorage.published(path)`. The UI has no sign-in prompt for this tab, but Firestore and Storage rules require a signed-in user for the public namespace.

### Published projection: `public_files/{sourceGroupId}__{sourceId}`

`files` declares `publishTo: "public_files"`, `publishWhen: {"isPublic": true}`, and the projection fields `fileName`, `displayName`, `size`, `contentType`, `createdAt`, and `storagePath`. The server writes those fields plus publication identity and bookkeeping; only the projected fields are copied from the source document. The `storagePath` in the projection points to the copied object, not the tenant source object.

```json
{
  "fileName": "budget.xlsx",
  "displayName": "Quarterly budget",
  "size": 182044,
  "storagePath": "published/group_123/storage/files/file_abc/uuid_budget.xlsx_<hash>",
  "createdAt": "2026-11-05T13:20:00Z",
  "sourceGroupId": "group_123",
  "sourceAppId": "storage",
  "sourceCollection": "files",
  "sourceId": "file_abc",
  "publishedBy": "uid_alice",
  "publishedAt": "<server timestamp>",
  "projectionVersion": "320cd8d27391"
}
```

Fields absent from the source projection are omitted. In particular, owner UID/email and share lists are not published. `publicPublish` copies configured file fields under `published/{groupId}/{appId}/{collection}/{sourceId}/`; a source-document trigger re-syncs the projection and copied object, or removes them when the source is deleted or no longer publishable.

### My Files tab query

```json
{
  "collection": "files",
  "where": [{"field": "userId", "op": "==", "value": "<currentUser.uid>"}],
  "orderBy": [{"field": "createdAt", "direction": "desc"}],
  "implicitWhere": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}]
}
```

The My Files and Shared queries each load the whole tab, folders included, once per refresh (`_query` caches the future by `_refreshKey`). Folder browsing happens in memory: `FolderTree.childrenOf` lists what the open folder holds, folders first by name and then files newest first. On Shared, an item whose `parentId` folder isn't in the result shows at the top level.

### Shared tab query

```json
{
  "collection": "files",
  "where": [{"field": "sharedWithIds", "op": "array-contains", "value": "<currentUser.uid>"}],
  "orderBy": [{"field": "createdAt", "direction": "desc"}],
  "implicitWhere": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}]
}
```

### From clients tab query

Shown only when `portalGivesApp(activeGroupDocId, "storage")` is true.

```json
{
  "collection": "files",
  "where": [{"field": "fromClient", "op": "==", "value": true}],
  "sort": "createdAt desc, client-side (no composite index)",
  "implicitWhere": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}]
}
```

### Client view query

`ScopedCollection("files").queryAsClient()` redirects to the client copy:

```json
{
  "collection": "client_files",
  "where": [
    {"field": "groupId", "op": "==", "value": "<activeGroupId>"},
    {"field": "clientUids", "op": "array-contains", "value": "<currentUser.uid>"}
  ],
  "sort": "createdAt desc, client-side"
}
```

The client view and the portal card both use it (`loadClientFiles`).

### Usage rollup queries

```json
[
  {
    "collection": "storage_usage",
    "where": [{"field": "userId", "op": "==", "value": "<currentUser.uid>"}],
    "limit": 1,
    "mode": "stream",
    "implicitWhere": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}]
  },
  {
    "collection": "storage_usage",
    "where": [{"field": "kind", "op": "==", "value": "group_total"}],
    "limit": 1,
    "mode": "stream (admins only)",
    "implicitWhere": [{"field": "groupId", "op": "==", "value": "<activeGroupId>"}]
  }
]
```

If a usage snapshot has no rollup document, the app performs a one-time `files` query in the active group and sums `size`; the user query adds `where userId == currentUser.uid`, while the admin group fallback scans the group files without a user filter. `totalFiles` is the number of returned documents that aren't folders (`isFolder: true` docs are skipped). These fallbacks are unpaged.

## Cloud Function Interfaces

### `storageShareFile`

**Type:** Callable (`onCall`)

Request (client currently sends the full desired recipient list, including existing recipients; the server trims, deduplicates, excludes the caller, and adds only new IDs):

```json
{
  "fileId": "file_abc",
  "userIds": ["uid_bob", "uid_cara"]
}
```

Response:

```json
{
  "success": true,
  "fileId": "file_abc",
  "addedUserIds": ["uid_bob", "uid_cara"]
}
```

Server-side checks:
- Caller must be authenticated.
- Caller must have active Storage read access in the file's stored `groupId`.
- Caller must own the file (`userId`).
- Each newly added target `userId` must be a Storage member of the same group, or an active portal client of it holding `{groupId}:storage:guest`. Otherwise the call fails with `permission-denied` ("You can only share with members of this group who use Storage, and clients your portal gives Storage."). The member UI sends a single client UID when sharing with a client.
- An empty/non-list `userIds`, or a list that yields no IDs, returns `invalid-argument`; re-sharing only existing recipients succeeds with an empty `addedUserIds`.

Side effects:
- Updates `files/{fileId}` with merged recipient arrays:

```json
{
  "sharedWithIds": ["<existing...>", "<new...>"],
  "sharedWithEmails": ["<existing...>", "<new emails if available...>"]
}
```

After the callable succeeds, the client calls `NotificationService.addForRecipients` once for the returned `addedUserIds`. That separate `notificationsSend` request is best-effort: if it fails, recipients remain in the file's share list and the client logs the error.

Sharing with a client also changes the file's `clientUids` (through the client-link trigger), which creates or updates `client_files/{fileId}` and notifies the client with title `"{group} shared a file with you"` (`"{group} shared a folder with you"` for a folder) and body `displayName`, else `fileName`, else `"Open it in your portal."`. No notice goes out for an item with a `parentId` (the folder's notice covers it) or for the client's own uploads.

### `storageRegisterClientUpload`

**Type:** Callable (`onCall`), called by the client view after uploading to `client_uploads/`.

Request:

```json
{
  "groupId": "group_123",
  "storagePath": "groups/group_123/apps/storage/client_uploads/uuid_receipt.pdf",
  "fileName": "receipt.pdf",
  "displayName": "Optional, not sent by the app"
}
```

Response:

```json
{ "success": true, "fileId": "group_123__client_<hash>", "created": true }
```

`created` is `false` when the object was already registered; the existing id is returned.

Server-side checks:
- Caller must be authenticated; `groupId`, `storagePath` and `fileName` are required (`invalid-argument`). `fileName` and `displayName` are trimmed to 200 characters.
- Caller's access index holds `{groupId}:storage:guest` and their membership is an active client membership (`permission-denied`, "Storage isn't open to you in this group.").
- `storagePath` is under `groups/{groupId}/apps/storage/client_uploads/` without `..` (`invalid-argument`), the object exists (`not-found`), and its `creatorId` metadata is the caller (`permission-denied`).

Side effect: creates the `files` document shown under [`files/{fileId}`](#filesfileid) (`isPublic: false`, `fromClient: true`).

### `storageCleanUpClientUploads`

**Type:** Scheduled (`17 4 * * *`, America/Toronto). For every group with an enabled portal, deletes `client_uploads/` objects older than 24 hours that have no registered `files` doc. Logs `{checked, deleted}`.

### `storageBillingStatus`

**Type:** Callable (`onCall`). Caller must be a member of the group or a platform admin (`permission-denied` otherwise; `not-found` for an unknown group).

Request:

```json
{ "groupId": "group_123" }
```

Response:

```json
{
  "groupId": "group_123",
  "plan": "free",
  "plans": ["free", "pay_as_you_go"],
  "usageBytes": 13421772800,
  "freeTierGiB": 50,
  "freeTierBytes": 53687091200,
  "uploadsAllowed": true,
  "price": {
    "pricePerGiBMonth": 0.0644,
    "currentPricePerGiBMonth": 0.0644,
    "currency": "CAD",
    "listUsdPerGiBMonth": 0.023,
    "markup": 2,
    "cadPerUsd": 1.4,
    "overridden": false
  },
  "estimatedMonthlyCost": 0,
  "canManage": true,
  "payerIsYou": false,
  "payerEmail": null,
  "hasPaymentMethod": true,
  "lastBilledPeriod": null
}
```

- `plan` is `"unlimited"` for groups in `unlimitedGroupIds`.
- `usageBytes` sums Usage Meter's `usage_storage` docs for the group and `appId: "storage"`.
- On pay as you go, `freeTierGiB` and `price.pricePerGiBMonth` are the values the payer accepted, and `price.currentPricePerGiBMonth` is today's price. `estimatedMonthlyCost` is today's usage above the free tier times that price, and is `0` on other plans.
- `canManage` is true for group admins and platform admins. `payerEmail` and `hasPaymentMethod` (the caller has a default Wallet card) are set only when `canManage`, otherwise `null`.

The client model `StoragePlanStatus.fromMap` reads `plan`, `usageBytes`, `freeTierGiB`, `uploadsAllowed`, `price.pricePerGiBMonth`, `price.currentPricePerGiBMonth`, `price.currency`, `estimatedMonthlyCost`, `canManage`, `payerIsYou`, `payerEmail` and `hasPaymentMethod`. It ignores the other fields.

### `storageBillingSetPlan`

**Type:** Callable (`onCall`), group admins or platform admins.

Request:

```json
{ "groupId": "group_123", "plan": "pay_as_you_go", "acceptedPricePerGiBMonth": 0.0644 }
```

`plan` is `"free"` or `"pay_as_you_go"`. `acceptedPricePerGiBMonth` is sent only for pay as you go. Any other key is `invalid-argument`.

Response: the same shape as `storageBillingStatus`, after the change.

Errors:
- `permission-denied`: not an admin ("Only this group's admins can change its storage plan.").
- `failed-precondition`: the group is unlimited; the accepted price isn't today's ("The storage price has changed. Review the new price and try again."); no default card ("Add a default card in Wallet before turning on pay as you go."); or, switching to free, the group stores more than the free tier.

Side effects: merges `storage_billing/{groupId}` (plan, appended `history` entry, payer and accepted price/free tier on pay as you go, or `payerId`/`payerEmail: null` on free). Choosing the current plan again changes nothing, except that pay as you go chosen by a different admin makes them the payer. When something changed, the other active group admins get a notification ("<group> now pays as it goes for storage" / "<group> is back on free storage") linking to the app.

### `storageBillingMonthlyOverage`

**Type:** Scheduled (`10 6 2 * *`, America/Toronto). Bills the previous UTC month for each non-unlimited `storage_billing` doc that was on pay as you go on at least one day of it. Daily bytes come from `usage_daily` docs with `gauge: "storage"` (`apps.storage.storageByteDays`). The overage is `Σ max(0, GiB that day − freeTierGiB) / daysInMonth` over the billable days, times the accepted price, rounded to cents. If the amount is at least 0.01 and there is a payer, it writes `billing_events/storage_overage_<groupId>_<YYYY-MM>`:

```json
{
  "userId": "uid_payer",
  "groupId": "group_123",
  "subAppId": "storage",
  "eventType": "usageUnit",
  "amount": 3.22,
  "currency": "CAD",
  "description": "Storage for \"Acme\" above the free 50 GB (2026-10): 50 GB-months at $0.0644/GB",
  "metadata": {
    "period": "2026-10",
    "sourceAppId": "storage",
    "overageGiBMonths": 50,
    "freeTierGiB": 50,
    "pricePerGiBMonth": 0.0644,
    "billableDays": 31
  },
  "category": "storage-overage"
}
```

plus the common billing-event fields from `billingEventFields` (`functions/_platform_invoicing.js`). It then sets `lastBilledPeriod` and `lastOverageGiBMonths` on the billing doc. A period already billed is skipped. Returns and logs `{period, billed, skipped, failed}`.

### `publicPublish`

**Type:** Callable (`onCall`), invoked through `PublicCollection.publish(fileId)` when the uploaded file has `isPublic: true`.

Request:

```json
{
  "collection": "files",
  "id": "file_abc"
}
```

Response:

```json
{
  "collection": "public_files",
  "id": "group_123__file_abc"
}
```

The caller must be authenticated and hold the `owner` publication tier on the source file in its own group. The server validates the source, copies its `storagePath` object into the published namespace, and writes the `public_files` projection. The client does not write the projection or published Storage object. The source write trigger keeps the projection synchronized and removes it and its copies if the source is deleted or no longer publishable.

### `storageDeleteFile`

**Type:** Callable (`onCall`)

Request:

```json
{
  "fileId": "file_abc"
}
```

Response:

```json
{
  "success": true,
  "fileId": "file_abc"
}
```

For a folder the response also has `deleted`, the number of items removed with it, the folder included.

Server-side checks:
- Caller must be authenticated.
- Caller must have active Storage read access in the file's stored `groupId`.
- Caller must own the file (`userId`).

Side effects:
- Deletes the Firebase Storage object resolved from `storagePath` (fallback for legacy records: `downloadUrl`); a missing object is tolerated. The source-document trigger also removes its published projection and copy if present.
- Deletes `files/{fileId}` metadata document.
- For a folder (`isFolder: true`): walks down through `parentId` in the same group and deletes every item the caller owns, each file's stored object first (only inside the group's own Storage folder, as for a single file), then the folders. Anyone else's item filed there loses its `parentId` and moves to the top level of their files.

### `onStorageFolderItemWritten`

**Type:** Firestore trigger on `files/{fileId}` writes (`functions/storage_usage.js`, logic in `functions/_storage_folders.js`).

- An item written with a new `parentId` (created in a folder, or moved into one) gets the folder's `sharedWithIds` it lacks, with their emails in `sharedWithEmails`, when the folder belongs to the item's owner in the same group.
- A folder whose `sharedWithIds` gained recipients adds them to every item its owner keeps directly in it. Each of those updates fires this trigger again, so sharing reaches folders inside folders.
- It only adds recipients (`arrayUnion`), so repeat deliveries change nothing. Recipients were checked once, when the folder was shared through `storageShareFile`; a client among them is linked to each item by the client-link triggers.
- Sharing is never removed: moving an item out of a shared folder keeps its recipients.

### `storageGetFileDownloadUrl`

**Type:** Callable (`onCall`)

Request:

```json
{
  "fileId": "file_abc"
}
```

Response (legacy public file with a non-empty source `downloadUrl`):

```json
{
  "success": true,
  "fileId": "file_abc",
  "downloadUrl": "https://firebasestorage.googleapis.com/...",
  "access": "public"
}
```

Response (private file):

```json
{
  "success": true,
  "fileId": "file_abc",
  "downloadUrl": "https://storage.googleapis.com/...",
  "access": "private_signed",
  "expiresAt": "<ISO-8601 timestamp five minutes after issuance>"
}
```

Server-side checks:
- Caller must be authenticated.
- Caller must have active Storage read access in the file's stored `groupId`, or be a portal client named in the file's `clientUids` who holds `{groupId}:storage:guest` (treated as private access).
- Private files require owner or explicit share access; a `fromClient` upload is open to every Storage member of the group.

The current UI does not use this signed-URL response to download private files. It uses `storageDownloadFile` below, which streams content with the authenticated request. This callable exists for callers that specifically need a time-limited link.

New public uploads store an empty source `downloadUrl`, so this callable returns `failed-precondition` for those records. The current public UI instead resolves the published copy from `public_files` and calls `getDownloadURL()` on that published Storage object.

### `storageDownloadFile`

**Type:** HTTP `GET`, using the Cloud Functions URL:
`https://northamerica-northeast2-{projectId}.cloudfunctions.net/storageDownloadFile?fileId={fileId}`

The app calls this URL directly. `https://bluejay.gg/files/download?fileId={fileId}` (a Hosting rewrite in `firebase.json`) reaches the same function, but Hosting ends rewritten requests after 60 seconds, which would cut off a large download. Every response carries `Cache-Control: private, no-store`.

Request headers:

The client sends `User.getIdToken()` as the `Authorization` bearer credential. The browser sends its page origin (for example, `https://bluejay.gg`).

The `Origin` header is optional; when present it must match an allowed production origin or the configured Firebase Hosting preview-origin pattern. `OPTIONS` returns `204`; methods other than `GET` return `405`.

The server validates the ID token, active Storage access in the file's stored group, and file access (owner, explicitly shared, or, for a `fromClient` upload, any Storage member of the group, for private files). A caller without Storage access is admitted when the file's `clientUids` names them and they hold `{groupId}:storage:guest`; the client view downloads this way. It streams the object bytes with `200`, the object's `Content-Type` (or `application/octet-stream`), and `Content-Disposition: attachment; filename*=UTF-8''{encodedName}`. The file name is the trimmed `displayName`, then `fileName`, then `fileId`. The current UI uses this endpoint for private downloads; public downloads use the `published/` copy instead.

Error response:

```json
{ "error": "A user-readable message" }
```

HTTP status mapping: `400` invalid argument, `401` unauthenticated, `403` permission denied or disallowed origin, `404` missing file/object, `412` missing required path/group state, `405` unsupported method, and `500` unexpected server failure. The endpoint can stream a source public file to a caller with access to its source group; it is not the path the UI uses for public files.

### `onStorageFileWritten` (Storage app quota summaries)

**Type:** Firestore trigger on `files/{fileId}`

#### Source document fields consumed

| Field | Type | Description |
|---|---|---|
| `appId` | `String` | Must equal `"storage"` or the document is ignored. |
| `groupId` | `String` | Required to compute rollup IDs. |
| `userId` | `String` | Required uploader UID for per-user totals. |
| `size` | `number` | File size delta applied to totals. |

#### Side effects

Writes or merges `storage_usage/{groupId}__{userId}` and `storage_usage/{groupId}____group_total__` documents with updated `totalBytes` and `totalFiles`.

There is no callable/HTTP request or response contract for this trigger.

### Usage Meter Storage interfaces

These are platform Usage Meter collections and are separate from the Storage app's `storage_usage` rollups.

#### Cloud Storage bucket events

`usageStorageOnObjectFinalized` consumes the bucket's `StorageObjectData` fields `{name, size, metadata, generation}` for finalized or overwritten generations. `usageStorageOnObjectDeleted` consumes the corresponding deleted generation. Empty names and folder placeholders ending in `/` are ignored. Both handlers catch and log errors; the scheduled recount reconciles missed trigger work.

The object path has priority for attribution:

1. `groups/{groupId}/apps/{appId}/...` supplies group and app; custom `creatorId` supplies the user.
2. Legacy `PATH_RULES` map older prefixes to their app and may identify user/group in the path.
3. If path data is incomplete, custom metadata claims are checked: claimed group must appear in the creator's access index, and claimed app must be registered.
4. Bounded Firestore lookups can fill missing owner/group fields. The nightly recount additionally scans configured back-references.
5. Missing dimensions use the sentinels `groupId: "~none"`, `uid: "~system"`, and `appId: "~unknown"`; attribution can be corrected by later recounts.

The default bucket region is `northamerica-northeast2`. `usageStorageNightlyRecount` runs at 23:40 UTC daily.

#### `usage_storage_objects/{sha1(objectName)}`

The server-side ledger records the generation and owner currently counted for an object. Finalize/delete event updates the ledger, owner totals, and upload metric in one Firestore transaction, making duplicate/out-of-order events idempotent.

```json
{
  "name": "groups/group_123/apps/storage/files/uuid_budget.xlsx",
  "generation": "1730812800000000",
  "size": 182044,
  "groupId": "group_123",
  "uid": "uid_alice",
  "appId": "storage",
  "exact": true,
  "upload": null,
  "deleted": false,
  "updatedAt": "<server timestamp>"
}
```

`upload` is either `null` or `{date, groupId, uid, appId}` while an inexact attribution may need its `storageUploads` count moved during recount. Deleted objects are represented by a tombstone with `size: 0`, `deleted: true`, and `upload: null`; `name`, `generation`, and `updatedAt` remain.

#### `usage_storage/{groupId}_{uid}_{appId}`

Each document stores the current total of object bytes and files for one attributed owner:

```json
{
  "groupId": "group_123",
  "uid": "uid_alice",
  "appId": "storage",
  "bytes": 182044,
  "files": 1,
  "creatorId": "~server",
  "ownerIds": [],
  "updatedAt": "<server timestamp>"
}
```

`bytes` and `files` are increment/decrement deltas committed with the ledger transaction. Empty total documents are deleted by recount. The records are server-owned and are not the `storage_usage` card's schema.

#### Server `usage_daily` upload event

Finalize events record one `storageUploads` metric in a server-owned daily usage document, attributed to the object's `(groupId, uid, appId)`. The nightly recount writes an absolute `storageByteDays` gauge for the same owner/app, equal to bytes held for the sampled day.

```json
{
  "date": "2026-11-05",
  "groupId": "group_123",
  "uid": "uid_alice",
  "appId": "usage-meter",
  "creatorId": "~server",
  "ownerIds": [],
  "source": "server",
  "apps": {
    "storage": {
      "storageUploads": 1
    }
  },
  "updatedAt": "<server timestamp>"
}
```

The shard suffix is part of the server document ID. The app does not read server-owned usage documents.

#### Server `usage_daily` storage gauge

The nightly recount writes an absolute `storageByteDays` sample for the attributed owner and app. It writes one gauge document per `(date, groupId, uid, gauge)` and removes stale documents for that date/gauge:

```json
{
  "date": "2026-11-05",
  "groupId": "group_123",
  "uid": "uid_alice",
  "appId": "usage-meter",
  "creatorId": "~server",
  "ownerIds": [],
  "source": "server",
  "gauge": "storage",
  "countsAsActive": false,
  "apps": {
    "storage": {
      "storageByteDays": 182044
    }
  },
  "updatedAt": "<server timestamp>"
}
```

#### Client `usage_daily` Firestore-operation metrics

`BluejayFirestore.forApp("storage")` and `ScopedCollection` attribute billable client Firestore activity to the Storage app. The metered query layer counts server-backed query reads, writes after success, and deletes; cache-served reads are free. The UI has live listeners only for usage summaries: each listener's initial result is counted once and later server events count changed documents, while metadata-only and later cache snapshots are skipped.

The client meter buffers counters and flushes increment-only merges every five minutes and at lifecycle/group changes. An example partial document for a signed-in user and active group is:

```json
{
  "date": "2026-11-05",
  "groupId": "group_123",
  "uid": "uid_alice",
  "appId": "usage-meter",
  "creatorId": "uid_alice",
  "ownerIds": ["uid_alice"],
  "apps": {
    "storage": {
      "fsReads": "<increment>",
      "fsWrites": "<increment>",
      "fsDeletes": "<increment>"
    }
  },
  "updatedAt": "<server timestamp>"
}
```

`fsReads`, `fsWrites`, and `fsDeletes` are present only when nonzero. The actual values are Firestore increment transforms; the document ID is `{date}_{groupId}_{uid}`. This client-owned document is distinct from the server-owned event and gauge documents above.

#### `usageStorageRecount` admin callable

Request:

```json
{ "dryRun": true }
```

`dryRun` is optional and defaults to `false`. Only platform admins may call it. Success returns a summary; dry-run mode only reports it, while a normal run reconciles the ledger and writes the gauge:

```json
{
  "date": "2026-11-05",
  "dryRun": true,
  "objects": 100,
  "bytes": 2048000,
  "bySource": {
    "scoped-path": { "objects": 80, "bytes": 1800000 },
    "path-rule": { "objects": 20, "bytes": 248000 }
  },
  "unattributed": {
    "user": { "objects": 1, "bytes": 42 },
    "group": { "objects": 1, "bytes": 42 },
    "app": { "objects": 1, "bytes": 42 }
  },
  "owners": 8
}
```

Non-dry-run responses also contain integer counts `reconciled`, `removed`, and `emptied`. A failed recount returns a callable `internal` error with a generic message; the underlying exception is logged server-side.

## Callable Error Interface

Callable failures return Firebase callable errors (`HttpsError`) with `code` and `message`. Common codes used by this feature:

- `unauthenticated`
- `invalid-argument`
- `not-found`
- `permission-denied`
- `failed-precondition`
- `internal`

## External API Interfaces

The feature calls its own Cloud Functions HTTP endpoint for authenticated streaming downloads and uses platform plugins for file selection and upload/download behavior; it does not call a third-party business API.

### File picker and platform upload

The upload action calls `FilePicker.platform.pickFiles()` with the plugin defaults (single selection). It returns `null` or a `FilePickerResult` containing `files: List<PlatformFile>`. The screen uses `files.single`:

| `PlatformFile` value | Use |
|---|---|
| `name: String` | Original filename, Storage object suffix, Firestore `fileName`, and default display-name stem. |
| `size: int` | Persisted as Firestore `files.size` and included in Storage usage totals. |
| `bytes: Uint8List?` | Required by the web upload branch; a missing byte buffer causes upload failure. |
| `path: String?` | Used by the mobile `PlatformService.uploadGenericFile` implementation. |
| `extension: String?` | Used by the mobile helper to infer content type; otherwise it uses `application/octet-stream`. |

After the upload dialog returns an `UploadDetails` record (`({String name, bool isPublic})`; the trimmed name becomes `displayName`), the web flow uploads bytes with `ScopedStorage.putBytes()` and listens to `UploadTask.snapshotEvents`. The mobile flow passes the picked file and metadata to `PlatformService.uploadGenericFile()`; progress is shown as complete when its future returns. Both return `Future<void>` from the platform helper. The screen writes the tenant metadata document with `downloadUrl: ''`; if public, it then calls `publicPublish` to create the projection and copy.

### Client upload limits

The client view uploads to `ScopedStorage(folder: 'client_uploads', appId: 'storage')` with `contentType` from `MimeTypeHelper.detect(fileName)`. On web it uses `putBytes`; on mobile it passes metadata from `buildMetadata(contentType:)` to `uploadGenericFile`. Before uploading, `clientUploadProblem(fileName, size)` applies the same limits as the Storage rules (`guestUploadLimits.storage`): at most 25 MiB (`kClientUploadMaxBytes`), with type `image/*`, `application/pdf`, `text/plain`, `text/csv`, `application/msword`, `application/vnd.ms-excel` or `application/vnd.openxmlformats-officedocument.*`.

### Firebase Storage object metadata

Uploaded files are created through `ScopedStorage(folder: 'files', appId: 'storage')`. `buildMetadata` sets permission fields from the authenticated user, active group and app constant; `requireUploadMetadata` rejects missing or blank `creatorId`, `groupId`, or `appId`.

| Metadata key | Type | Required | Description |
|---|---|---|---|
| `creatorId` | `String` | Yes | Current user UID. |
| `groupId` | `String` | Yes | Active group ID. |
| `appId` | `String` | Yes | Always `"storage"`. |
| `contentType` | `String?` | No | MIME type when the platform upload helper provides it. |

Example storage metadata:

```json
{
  "creatorId": "uid_alice",
  "groupId": "group_123",
  "appId": "storage"
}
```

## SharedPreferences / Local Persistence

This feature does not use `SharedPreferences` or other local persistence.

## Internal State / In-Memory Models

`SharedFile` and `StorageUsageSummary` are defined in `packages/storage/lib/src/models.dart` and re-exported from `package:storage/file_sharing_screen.dart`.

### `SharedFile`

`SharedFile.fromFirestore` uses the tenant document ID as `id` and applies backward-compatible defaults: absent/null strings become `''`, absent/null size becomes `0`, missing `createdAt` becomes `Timestamp.now()`, missing `isPublic` becomes `true`, and missing share arrays become empty lists. Missing `displayName` remains `null`. `SharedFile.fromPublished` uses `sourceId` as `id`, sets `isPublic: true`, and reads the copied `storagePath`; uploader and share fields are absent because they are not published. The `isPublishedCopy` getter is true when `storagePath` is a published-copy path (`ScopedStorage.isPublishedPath`); downloads and copied links for such files read the copy directly.

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | `String` | Yes | Firestore document ID. |
| `downloadUrl` | `String` | Yes | `''` for all new records; older records may contain a URL. |
| `storagePath` | `String` | Yes | Stored object path; missing legacy values deserialize to `''`. |
| `fileName` | `String` | Yes | Original file name. |
| `userId` | `String` | Yes | Owner UID. |
| `userEmail` | `String` | Yes | Owner email; missing values deserialize to `''`. |
| `displayName` | `String?` | No | Friendly display name. |
| `size` | `int` | Yes | Size in bytes. |
| `createdAt` | `Timestamp` | Yes | Upload time; missing values deserialize to `Timestamp.now()`. |
| `isPublic` | `bool` | Yes | Visibility flag. |
| `sharedWithIds` | `String[]` | Yes | Explicit share UIDs. |
| `sharedWithEmails` | `String[]` | Yes | Explicit share emails. |
| `fromClient` | `bool` | Yes | `data['fromClient'] == true`. |
| `clientUploaderUid` | `String?` | No | Uploading client's UID. |

### `StoragePlanStatus`

Defined in `packages/storage/lib/src/storage_plan.dart`; built by `StoragePlanStatus.fromMap` from the `storageBillingStatus` / `storageBillingSetPlan` response.

| Field | Type | Source |
|---|---|---|
| `plan` | `String` | `plan`, default `"free"`; constants `free`, `payAsYouGo`, `unlimited` |
| `usageBytes` | `int` | `usageBytes`, default `0` |
| `freeTierGb` | `double` | `freeTierGiB` |
| `uploadsAllowed` | `bool` | `uploadsAllowed != false` |
| `pricePerGbMonth` | `double` | `price.pricePerGiBMonth` |
| `currentPricePerGbMonth` | `double` | `price.currentPricePerGiBMonth`, else `price.pricePerGiBMonth` |
| `currency` | `String` | `price.currency`, default `"CAD"` |
| `estimatedMonthlyCost` | `double` | `estimatedMonthlyCost` |
| `canManage` | `bool` | `canManage == true` |
| `payerIsYou` | `bool` | `payerIsYou == true` |
| `payerEmail` | `String?` | `payerEmail` |
| `hasPaymentMethod` | `bool?` | `hasPaymentMethod` |

Getters: `freeTierBytes` (`freeTierGb × 1024³`), `isFree` / `isPayAsYouGo` / `isUnlimited`, `freeTierShare` (`usageBytes / freeTierBytes`, may exceed 1), and `allowsUpload(bytes)` (true unless free and `usageBytes + bytes > freeTierBytes`). Missing numbers read as `0`.

### `StorageUsageSummary`

| Field | Type | Required | Description |
|---|---|---|---|
| `totalBytes` | `int` | Yes | Summed bytes. |
| `totalFiles` | `int` | Yes | Summed file count. |

### UI state

| Field | Type | Description |
|---|---|---|
| `_isUploading` | `bool` | Whether an upload is in progress. |
| `_uploadProgress` | `double` | `0.0..1.0` upload progress. |
| `_refreshKey` | `int` | Forces tab refreshes after mutations. |
| `_portalGivesStorage` | `bool` | Whether the group's portal gives clients Storage (adds the From clients tab and the client share option). |
| `_plan` | `StoragePlanStatus?` | The group's plan; `null` until loaded or if it can't be read. |

## Notification Payloads

For each share, the client calls `NotificationService.addForRecipients` once with the newly added recipient UIDs and this sender-controlled payload (for a folder the title is `"alice shared a folder with you"` and `context.fileId` is the folder's id):

```json
{
  "title": "alice shared a file with you",
  "body": "Quarterly budget",
  "appName": "File Storage",
  "context": {
    "fileId": "file_abc"
  }
}
```

The service sends one `notificationsSend` callable request for the batch. It includes the active `groupId`, `appId: "storage"`, and `recipientIds`; the server validates the sender entitlement and recipient group membership, rate-limits the sender, and returns `{ "ids": ["<notificationId>", ...], "skippedRecipientIds": ["<uid>", ...] }`. Storage uses the returned IDs to form `DocumentReference`s and does not write notification documents directly.

Request:

```json
{
  "groupId": "group_123",
  "appId": "storage",
  "recipientIds": ["uid_bob"],
  "title": "alice shared a file with you",
  "body": "Quarterly budget",
  "appName": "File Storage",
  "context": {
    "fileId": "file_abc"
  }
}
```

Response:

```json
{
  "ids": ["notification_xyz"],
  "skippedRecipientIds": []
}
```

The server persists one document per eligible recipient:

| Field | Type | Required | Description |
|---|---|---|---|
| `recipientId` | `String` | Yes | Shared-to user UID. |
| `title` | `String` | Yes | `"<sharer> shared a file with you"`, or `"<sharer> shared a folder with you"` for a folder. |
| `body` | `String` | Yes | `displayName` if present, else `fileName`. |
| `appName` | `String` | Yes | Always `"File Storage"`. |
| `isRead` | `bool` | Yes | Starts as `false`. |
| `createdAt` | `Timestamp` | Yes | Server timestamp. |
| `context.fileId` | `String` | Yes | Shared file document ID. |
| `senderId` | `String` | Yes | UID of the sharing user, set by the server. |
| `groupId` | `String` | Yes | Active group, set by the server after entitlement validation. |
| `appId` | `String` | Yes | `"storage"`, set by the server. |

Example payload:

```json
{
  "recipientId": "uid_bob",
  "title": "alice shared a file with you",
  "body": "Quarterly budget",
  "appName": "File Storage",
  "isRead": false,
  "createdAt": "<server timestamp>",
  "context": {
    "fileId": "file_abc"
  },
  "senderId": "uid_alice",
  "groupId": "group_123",
  "appId": "storage"
}
```
