# Storage — UX Improvements

## 1. Add live updates for shared/public activity

**Risk:** The Public, My Files, and Shared file lists are backed by one-time `.get()` calls plus manual refresh. Usage summaries already stream their server-maintained rollups.

**Impact:** Users miss teammate uploads/shares unless they tap refresh, which feels unreliable for collaboration.

**Proposal:** Move all three file tabs to `StreamBuilder` snapshots so new files and shares appear automatically.

## 2. Add access-management UI (unshare/revoke)

**Risk:** Owners can add recipients but cannot remove them.

**Impact:** Mistaken shares are hard to fix without deleting and re-uploading the file.

**Proposal:** Add a Manage Access sheet that lists recipients and supports revoke actions.

## 3. Allow post-upload visibility edits

**Risk:** Visibility choice is one-time at upload.

**Impact:** Users who accidentally choose Public/Private must re-upload to correct it.

**Proposal:** Add owner-only action to toggle `isPublic` and refresh tabs.
