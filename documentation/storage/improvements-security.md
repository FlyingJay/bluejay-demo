# Storage — Security Improvements

## 1. Add security-event audit logs for sensitive operations

**Risk:** There is no dedicated audit trail for who shared or deleted which file and when.

**Impact:** Incident response is slower; admins cannot quickly investigate misuse or over-sharing.

**Proposal:** Write immutable audit records (actor, target file, recipients, timestamp, groupId) to a security/audit collection for share + delete actions.

## 2. Add controls for bearer-style public download URLs

**Risk:** The app copies a Firebase download URL for the published Storage object. Although the published namespace requires sign-in when read through the normal Storage API, a token-bearing download URL may be usable outside the app's group and membership checks.

**Impact:** Forwarded or exposed links can outlive a user's group membership and are difficult to revoke from the Storage UI.

**Proposal:** Add owner-controlled link revocation or rotation, and explain the difference between signed-in access to a published copy and access through its download URL before users copy or share it.
