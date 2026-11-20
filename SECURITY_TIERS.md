# Bluejay Security Tiers

Bluejay's app catalog spans casual social tools (checkers, polls) and paid
business products for real insurance brokerages (policy-editor, bordereau-report).
Those two ends of the spectrum need genuinely different defaults — a permission
model strict enough for a regulated business product is the wrong default for a
friend-group game or poll, and vice versa (PR #1931 is a concrete case where the
stricter default was applied to a casual app — a since-retired shared-expense
tracker — and had to be walked back).

Security tiers give that spectrum a name and a checklist, so tier decisions are
made deliberately once per app rather than re-litigated per PR. This doc defines
the tiers; `scripts/security_tier_audit/` is the tool that checks whether an
app's actual rules (read from `security/collections.json`, which `firestore.rules`
is generated from) and `functions/` implementation support the tier it claims.

## The core distinction: declared vs. computed

- **Declared tier** (`apps/{appId}.securityTier`) — a deliberate classification,
  set by whoever owns that app/customer relationship (e.g. "Initech is a paying
  insurance customer, their apps are `business` at minimum"). Defaults to
  `casual` when unset, the same zero-migration pattern `sharedEditing` uses.
- **Computed tier** — what `scripts/security_tier_audit/` determines the app's
  *actual* `firestore.rules`/`functions/` implementation structurally supports,
  independent of what's declared.

**Only the computed tier is trustworthy on its own.** This mirrors the lesson
`change-firestore-permissions` already documents about `FIRESTORE_PERMISSIONS.md`
drifting from deployed rules: a doc (or a declared field) can claim anything: only
the real file governs behavior. `declared > computed` is the dangerous
combination — an app claiming protection it doesn't structurally have. Run the
audit and compare; don't trust the declared field alone.

## The tiers

Each tier's checklist is split into **mechanical** checks (the audit script can
verify these directly from `security/collections.json`/`functions/`/the app's config doc)
and **judgment** flags (the script can point at something worth a human look, but
can't decide it). A tier's computed value only credits mechanical checks; judgment
flags are reported alongside but never silently downgrade or upgrade the number.

### Tier 0 — Casual

Games, polls, whiteboard, flashcards, trivia, checkers. No shared-state
stakes beyond one member being annoyed at another. This is the default for
anything unclassified.

- No requirements beyond the platform floor (the generated rules require
  `creatorId == request.auth.uid` on every tenant create, and `ScopedCollection`
  injects it).
- Open editing (`sharedEditing` unset or `true`) is expected, not a gap.

### Tier 1 — Personal

Notes, lists, calendar, habit-tracker, photo-albums, workout-tracker. Data
belongs to one person; the blast radius of a bug is that person's own data.

- **Mechanical:** ownership (`creatorId`/`ownerIds`) actually gates edit/delete
  for the app's collections. The generated tenant rule guarantees this for every
  collection (and `security/check_rules_exceptions.js` fails CI on a bespoke
  `match` block), so the audit checks only `writesResolved`: it found the
  collections the app writes (through `ScopedCollection`, or the table's `apps`),
  or the app provably writes nothing.

**Declaration-only, not a reachable computed value.** `tier_rules.js`'s
`computeAppTier` sets `tier = 1` the instant the mechanical check above passes,
then unconditionally overwrites it to `tier = 2` before returning, with a
comment admitting Tier 2 "has no mechanical-only gate beyond Tier 1's." So no
app can ever come back from the audit script with a *computed* tier of exactly
`personal` — the computed value jumps straight from `casual` to `shared` (or
higher). `personal` still does real work as a **declared** tier: an app owner
can classify an app that way, and a group's `minimumAppSecurityTier: personal`
genuinely excludes installing apps declared `casual` without requiring the
heavier Tier 2 self-attestation judgment review. Just don't expect the audit
to ever confirm an app *at* this tier — only Tier 0 and Tier 2+ are
observable outcomes.

### Tier 2 — Shared / Trusted-Group

Task_list, projects, calendar events with attendees. Multi-party shared state with real but bounded stakes among people who
already trust each other.

- **Mechanical:** every field that represents "this document attests an action
  taken by a specific person" (`from`, `hostId`, `respondedBy`, `assigneeId`, ...)
  is checked against `request.auth.uid` server-side, not just enforced by the
  client UI. This floor is *not* tier-exclusive — a Tier 0 app with a field of
  this shape should still have the check (it's as cheap as the universal
  `creatorId` check); having it doesn't by itself make an app Tier 2 or higher.
- **Judgment flag:** any collection where non-creator members get broad edit
  access (via `ownerIds`, which lets every listed owner edit at the base tier, or via
  `sharedEditing`) should have its governance fields (who's a member, what state
  the whole thing is in) reviewed against the collection's entry in
  `security/collections.json` (its `creatorOnly`/`adminOnly` field locks) — see
  `change-firestore-permissions` Step 2. The audit script flags candidates; it can't determine which fields
  are "governance" for an arbitrary app.

### Tier 3 — Business-Critical

Business tools with real contractual or financial consequences from wrong
data: `naic-sight`, `continuing-education`, `business-like-that`, `billing`.

- **Mechanical:** `apps/{appId}.sharedEditing == false` — editor-tier roles only,
  no blanket member edit.
- **Mechanical:** guests are confined (`guestsConfined`). An app that isn't
  embeddable passes. An embeddable app passes when every collection its config
  shares with guests (`apps/{appId}.externalCollections`) is one
  `security/collections.json` declares `guestShareable`. The rules do the rest:
  a guest's own-doc access applies only in the app's `guestWritable` collections,
  and its uploads only in the app's `guestWritableFolders`
  (`security/storage_paths.json`), so every other collection and folder stays
  staff-only. This is how a consumer-facing app (an insurance quote form) reaches
  Tier 3: guests submit their own records, and staff work happens where guests
  can't reach.
- **Judgment flag:** each of the app's `guestWritable` collections is listed for
  a human to confirm that the fields staff set on a guest's record are locked
  (`staffOnly`/`serverFields`), and each `guestShareable` collection for a review
  of what it exposes.

### Tier 4 — Regulated / Audited (SOC 2-track)

The insurance apps (`rented-dwelling`, `course-of-construction`,
`commercial-property`, `get-insurance`, `policy-editor`, `bordereau-report`),
`signatures`, `app-access`, `app-maker` and `merchant-portal`: every collection they own is on the audit trail
and none can be hard-deleted from a client. For Signatures this matters because an
e-signature's legal validity rests on proving who signed what and when. For
App Access it is a record of who opened which app to outsiders and who changed
which members' access.

- **Mechanical:** an immutable audit trail: every collection the app owns
  declares `auditTrail: true` in `security/collections.json`. A server trigger
  (`functions/audit_trail.js`, from the generated `_audit_collections.json`)
  then appends every create, update and delete to `audit_events`: the actor,
  the time, the doc and each changed field's before and after values. Only the
  server writes `audit_events`, and nobody edits or deletes it; the audited
  app's `:admin` tier (group admins included) and platform admins read it.
  Declared, client-writable subcollections count too: each needs its own
  `subcollections.<name>.auditTrail` (a `commentThread` collection's comments
  and likes have it). The
  actor comes from `lastModifiedBy`/`lastModifiedAt`: the rules require every
  client write to an audited collection to stamp the caller and the request
  time, and `ScopedCollection` does it on every write. Admin SDK writes are
  recorded unattributed unless they stamp the same fields, so a server write
  made for a signed-in caller stamps them with `auditStamp(uid, at)`
  (`functions/_audit_trail.js`). A delete can't carry a stamp: a callable that
  deletes an audited doc records the delete itself with
  `recordAttributedDelete` in the same transaction, under the id the trigger
  would use, so it's recorded once. Writes with no caller (scheduled jobs,
  triggers) are recorded unattributed. A collection whose docs carry no
  `appId` names the app its entries are recorded under (`auditAppId`), and a
  collection keyed by group takes the doc id as the entry's group
  (`auditGroupIdFromDocId`): `groups` and `group_subscriptions` are recorded
  under Group Admin and `memberships` under Users, so each group's admins read
  their history. A kind `server` collection can declare `apps` too (App
  Access's `app_access_segments`), so a privilege source no client touches is
  still owned and audited. `auditStamp`'s time defaults to the server
  timestamp; a builder that already takes a `now` passes it through.
- **Mechanical (zero-collection apps):** an app that owns no collections but
  writes through callables (Group Admin, Add Apps, Merchant Portal) opts in with
  `securityTierAudit.writesThroughCallables`. It and every repo package file
  it imports may import only allowlisted external packages (no Firestore,
  Storage, web or HTTP client; `EXTERNAL_IMPORTS` in the audit); it reaches
  callables only as `BluejayCallable.call('<name>', ...)` with a literal name.
  Each callable it names declares `auditedWrites` in its `onCall` options;
  every declared collection is `auditTrail` or `auditExempt` (only the
  deliveries `notifications`, `action_items`, `notification_audit_log` and
  `ops_alerts`, plus `users/metadata` and a `ledger` under an audited
  collection: the generator refuses it elsewhere); the writes its handler
  visibly makes are declared; and a functions test runs its real export
  under the guard (`exerciseAuditedWrites`). See
  `scripts/security_tier_audit/README.md`.
- **Run time (defense in depth):** `functions/_write_guard.js` holds each
  declaring callable to its declaration on every Admin SDK Firestore write and
  every Storage write (objects, copy/move destinations, ACLs) in the
  invocation. It refuses an undeclared write, and fails the invocation even
  if the handler catches the refusal, in the Node tests, the emulator and
  production: `AUDITED_WRITES_MODE=enforce` in `functions/.env.bluejay-d926f`
  (since 2026-11-17, by the owner's decision to enforce before version 1
  and fix what it refuses; it ran log-only before that).
  - **Watching it:** each refused write logs one structured error,
    `[write-guard] undeclared write refused` (fields `callable`, `attempted`,
    `path`, `declared`, `stack`), and the caller gets an `internal` error. The
    Cloud Logging query is
    `jsonPayload.message:"[write-guard] undeclared write"`; from this repo,
    `node scripts/firestore_admin/logs.js read --since 14d --contains "[write-guard] undeclared write"`.
    Any hit is a missing declaration (or a real undeclared write): add the
    collection to the callable's `auditedWrites`, with a test that runs the
    write under the guard, and deploy. Check after every functions deploy
    that adds or changes a declaring callable.
  - **Falling back:** `AUDITED_WRITES_MODE=log` lets an undeclared write
    through and logs it as a warning under the same message without
    `refused`. Use it only to unblock a callable while its declaration is
    fixed.
- **Mechanical:** no hard deletes — `blockDelete: true` on the collection's
  table entry plus a soft-delete field (`deletedAt`), so the audit trail is never
  destroyed by a delete. `ScopedCollection.softDelete`/`batchSoftDelete` set
  the field (stamped for the audit trail) and `ScopedCollection.isSoftDeleted`
  filters reads; a field lock on `deletedAt` (`creatorOnly`, say) decides who
  may delete and restore. A doc with `deletedAt` then takes no client edit
  besides that restore, and nothing is written under it. The audit's `noHardDelete` passes when no client can
  delete in any of the app's collections: the entry sets `blockDelete` (or
  `serverWritten`), or is kind `server` without `readerMayDelete`, or kind `public`.
  Each declared, client-writable subcollection must set `blockDelete` too
  (server-written subcollections have no client writes and don't count). A
  comment thread (`commentThread`) soft-deletes comments by their author.
- **Judgment flag:** attachment files. `security/storage_paths.json`'s
  `retainedFolders` lists, per app, the Storage folders whose files no client
  deletes, overwrites or changes once uploaded (App Maker's and Improve Apps'
  attachments, Signatures' documents). The audit flags every `ScopedStorage`
  folder of the app that isn't retained; it doesn't gate the tier, because
  not every folder holds records (a cache of property photos).
- **Not yet built: consent capture.** A regulated client's consumers have to
  give consent before their personal information is collected (meaningful
  consent under PIPEDA, express consent for sensitive information under
  Quebec's Law 25). No app records it yet, and the audit doesn't check for it,
  so today's Tier 4 covers the audit trail and no hard deletes only. Production
  holds test data only. Consent capture has to exist before a Tier 4 app
  collects real consumer data for a client.
- **Judgment flag:** destructive/bulk actions (mass export, bulk delete) should
  route through an admin-only or dual-control callable rather than a raw client
  write — the script can check *that* a callable exists, not that every relevant
  action actually goes through it.

## Always-on checks (not tier-gated)

One check applies to every app regardless of declared or computed tier, because
it's a correctness bug, not a hardening question: **no rules construct may grant
access outside the generic tenant rule unless it is a reviewed exception.**
`firestore.rules` and `storage.rules` are generated from `security/collections.json`
and `security/storage_paths.json`; `security/check_rules_exceptions.js` (CI) fails on
any match block or `grant*` function that is neither the generic rule nor listed in
the table's `exceptions`. This closes the bug class behind the old wildcard
exclusion lists (a bespoke block whose collection the generic wildcard also matched,
so the wildcard silently granted back what the block restricted).

## Group minimums

`groups/{groupId}.minimumAppSecurityTier` lets a group (e.g. a real brokerage)
protect itself from a lower-tier app being installed inadvertently. This **cannot
be enforced inside `firestore.rules`**: validating an arbitrary-length
`installedApps` array against each app's tier would require a `get()` per array
element, and Firestore Security Rules has no loop construct for a dynamic number
of `get()` calls (this is a hard language limitation, not a style choice —
the rules' own budget of one access-index `get()` per request is a separate,
narrower constraint, but the loop limitation applies regardless of budget). Enforcement
therefore lives in the install policy (`evaluateAppInstall` in
`functions/_app_install_policy.js`), which every writer of `installedApps` calls:
the `setGroupInstalledApps` callable (`functions/access_control.js`, used by
`packages/groups/lib/services/groups_service.dart`'s `addAppAccess`),
`createGroup`, `groupPurchasesCreate`, App Maker's `installAppsInGroup` and the app
manifest sync. The same policy decides whether the app is available to the group
at all (public, in the group's `availableApps`, stewarded by the group, or
installed by a platform role).

The gate compares each new app's **effective tier** against the minimum: the
lower of its declared and computed tiers (`effectiveSecurityTier` in
`functions/_security_tiers.js`, used by every server install path and mirrored
for display in `shared_services/security_tier.dart`). Only platform admins and
developers may install a below-tier app anyway (`overrideAppIds`); a group admin
who passes it is refused. An app that declares
`regulated` but computes `shared` installs as `shared`, so a declared tier can
never get an app past a minimum its rules don't meet. An app the audit hasn't
computed yet is held to its declared tier. The Security Audit app's group
violations report uses the same effective tier, and each app's detail shows
which mechanical checks passed (`apps/{appId}.computedSecurityChecklist`).

On a pull request, the security tier step of PR Checks (`pr-checks.yml`) fails when a change lowers
an app's computed tier from `business` or `regulated`, or drops any app below
its declared tier (`findTierRegressions` in
`scripts/security_tier_audit/tier_rules.js`). The
`security-tier-decrease-approved` label approves an intended decrease. Other
computed-tier changes are reported in a PR comment.

## What this doc does not do

- It does not populate `securityTier`/`minimumAppSecurityTier` on real
  production documents. That's a deliberate classification pass, run and
  confirmed separately (writes to production data need explicit confirmation
  regardless of how mechanical the read-side tooling is).
- `installedApps` is not client-writable: `groups` is server-written
  (security/collections.json, rules plan T7), and every server writer goes
  through the install policy above. A brand-new group is created at the
  default `casual` minimum, so the tier never refuses its starting apps
  (`initialGroupApps` in `functions/_group_docs.js`); the platform default apps
  and the apps the creating path itself adds are eligible whatever their
  visibility.
