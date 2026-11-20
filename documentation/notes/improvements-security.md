# Notes — Security Improvements

## 1. Replace duplicated `sharedWithEmails` storage with live profile lookup

**Current risk:** Every shared note stores recipients' email addresses directly in note documents. Those copies can become stale and increase the spread of personally identifiable information across Firestore documents.

**Why it matters:** Minimizing replicated PII lowers exposure during debugging, exports, and future feature additions. It also avoids revealing outdated addresses after a user changes email.

**Proposed improvement:** Store only `sharedWithIds` on note documents and resolve display identity through the group-scoped `GroupMemberDirectory` when rendering share metadata.

## 2. Restrict and safely revoke share membership

**Current risk:** The UI only adds recipients, and share membership updates are not a dedicated authorization operation. A future removal feature could leave `sharedWithIds`, `sharedWithEmails`, and `ownerIds` inconsistent or let an unintended collaborator change who has access.

**Why it matters:** Revocation must remove all access-bearing records together and follow a clear authority model; partial updates can leave access behind or break note ownership.

**Proposed improvement:** Define who may add or remove collaborators, then enforce that policy in the write path. Apply each membership change atomically across `sharedWithIds`, `sharedWithEmails`, and `ownerIds`, and test concurrent edits and revocation in the rules emulator.
