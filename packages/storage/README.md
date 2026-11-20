# File Sharing App

A Flutter package (`storage`) for file uploading, sharing, and management, with public and private files.

## Features

- **Three-tab interface**:
  - **Public**: the active group's published files (`public_files`, read through `PublicCollection`; any signed-in user may read a published file)
  - **My Files**: every file the current user uploaded in the active group (public and private)
  - **Shared**: files shared with the current user (`sharedWithIds`)
- **Public/Private files**: a public file (`isPublic: true`) is published through the `publicPublish` callable, which copies it under `published/` and writes its projection to `public_files`; a private file stays readable only inside its group
- **Upload progress indicator**: Real-time progress tracking during file uploads (web platform)
- **Floating Action Button**: Easy access to file upload from any tab
- **Manual refresh control**: Files are queried once on load; use the refresh button to reload
- **Smart updates**: List automatically refreshes after uploads and deletions
- **File management**: Download and delete your own files with confirmation dialog

## Storage plans

Each group is on one of three plans (`functions/_storage_billing.js`):

- **Free tier** (default): the group can store up to the free tier (50 GB unless `platform_config/storage_billing.freeTierGiB` says otherwise). An upload that would take it past the tier is refused before it starts.
- **Pay as you go**: no limit. The admin who turns it on is billed monthly, through Wallet, for the group's storage above the free tier, averaged over the month (GB-months), at the price they accepted.
- **Unlimited**: granted by Bluejay (`unlimitedGroupIds`, Bluejay's own group by default) and never billed.

The price per GB-month is Google Cloud's list price for Standard storage in Toronto (US$0.023), doubled to cover uploads, downloads and bandwidth, in CAD. The Storage plan screen (the app bar's usage button, or "Storage plan" in App settings) shows the price per GB and per 100 GB, the group's usage against the free tier and, on pay as you go, who pays and this month's estimate. Group admins switch plans there; `storageBillingStatus` and `storageBillingSetPlan` serve it, and `storageBillingMonthlyOverage` bills the previous month on the 2nd. Usage is counted from the bucket by Usage Meter, never from the `files` docs' client-written `size`.

## Firestore Schema

The app uses a `files` collection (a `ScopedCollection`, so `groupId`, `appId`, `creatorId` and `ownerIds` are stamped on create) with these app fields:

```
files/
  {fileId}/
    - storagePath: string  (groups/{groupId}/apps/storage/files/...)
    - downloadUrl: string
    - fileName: string
    - userId: string
    - userEmail: string
    - size: number (bytes)
    - createdAt: timestamp
    - isPublic: boolean (default: true for backward compatibility)
    - sharedWithIds: string[]
```

Published projections live in `public_files/{groupId}__{fileId}` (kind `public` in `security/collections.json`; only the server writes them).

## Required Firestore Indexes

`firestore.indexes.json` is the source of truth. The tabs query `files` by `groupId` plus `userId` or `sharedWithIds`, ordered by `createdAt` descending.

## Usage

```dart
import 'package:storage/file_sharing_screen.dart';

// In your app
FileSharingScreen(currentUser: FirebaseAuth.instance.currentUser)
```

## Platform Support

- ✅ Web (with upload progress tracking)
- ✅ Android/iOS (progress shown as complete after upload)
