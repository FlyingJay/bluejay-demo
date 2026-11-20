---
name: change-firestore-permissions
description: Make a change to bluejay's Firestore or Storage authorization model — the policy table security/collections.json (and security/storage_paths.json) that generates firestore.rules and storage.rules, the access_index entitlement pipeline (rebuildUserAccessIndex/computeEntitlements in functions/_shared.js), the apps/{appId} permission config fields, or the Cloud Function triggers that keep access indices in sync — and open a PR for it. Use when the user says things like "change what guests/members/editors can access", "add a new permission scope", "fix a Firestore rules bug", "add a role", "restrict access to X collection", or asks to modify how firestore.rules, the access index, or entitlements work. This is a specialized, higher-care variant of a normal code change: the access-control model is security-critical, has a documented history of drifting from what's actually deployed, and has caused real bugs (a restriction silently lost on rebuild, a create-time ownership bypass) from changes that only handled one code path instead of all of them.
---

# Change Firestore Permissions

Bluejay's authorization model: one generic rule in `firestore.rules` (generated from
`security/collections.json`; `inTenant()` then entitlement detail, routed by the
collection's kind) makes the actual read/write decision, but it decides almost entirely
by reading one precomputed document (`users/{uid}/metadata/access_index`) rather than
looking up live group/membership state — that precomputation is a Cloud Function
pipeline (`rebuildUserAccessIndex` / `computeEntitlements` in `functions/_shared.js`),
triggered from several different Firestore write events in `functions/access_control.js`.
**A permission change that only edits the table, or only edits one of the
several `rebuildUserAccessIndex` trigger sites, is very likely incomplete.** This skill
exists because that exact failure mode has happened here before.

## The model since stage 7 (2026-11-06)

Production enforces the repo's rules for every collection and every Storage path family.
The staged `open`/`enforced` rollout is over and its switch is gone: there is no
`enforce` or `stage` key in `security/collections.json` or `security/storage_paths.json`,
no open-mode block in either rules file, and no "all-enforced" variant: the tests, the
Rules API smoke tools and production all run the committed files.

- **One table, kinds.** Each entry has a `kind` (`tenant` default, `server`, `personal`,
  `platform`, `platform_admin`, `public`) plus keys that only narrow (`apps`,
  `serverWritten`, `readerField`, field locks, `subcollections`, …) and the few reviewed
  grants (`adminWritable`, `developerRead`, `stewardRead`, `memberRead`, …). The schema
  documents every key.
- **Undeclared = tenant.** A collection with no entry is kind tenant, scoped by its
  docs' `appId` (`collectionPolicy()` falls back to `{}`); nothing is ever open. A
  `ScopedCollection(collection: 'x')` naming an undeclared collection still fails CI
  (`scripts/check_gateways.js`, `undeclared-collection`): declare it with
  `"x": { "apps": ["<appId>"] }`, or exempt the line with a reason.
- **Subcollections** follow the parent's kind and policy (a `personal` parent: only the
  uid in the path, e.g. `users/{uid}/prefs`; a tenant parent: the parent doc decides);
  nothing below one subcollection level is reachable.
- **Verify** with `node security/generate.js --check`,
  `node security/check_rules_exceptions.js`, `node security/check_server_collections.js`,
  `node scripts/check_gateways.js`, the emulator suite (`security/rules-tests`,
  `npm test`; the generated matrix and `every_collection.test.js` cover a new entry
  automatically, `cost.test.js` guards the 1000-expression headroom), and the
  read-only production rules engine (`node security/tools/rules_api_smoke.js`,
  `node security/tools/storage_rules_api_smoke.js`).
- **Deploy** only through `.github/workflows/deploy-rules.yml` (Actions -> "Deploy
  rules", `services: firestore | storage | both`). Since 2026-11-06 the repository
  variables are `RULES_AUTO_DEPLOY=true` and `RULES_AUTO_DEPLOY_SERVICES=both`, so
  after a merge that touches `firestore.rules`, `storage.rules` or `security/**` the
  deploy train (`.github/workflows/deploy-production.yml`, about hourly) calls
  `deploy-rules.yml` and deploys both rulesets: verify everything above before merge,
  and watch the next "Deploy Production" run after it. Afterwards,
  `node security/tools/denials.js --since <deploy time>` shows the permission-denied
  reports clients sent through `rulesDenialReport` (`RulesDenialReporter` in
  `shared_services`).
- **Rollback** is a revert PR plus deploy, a re-point of the release to the previous
  ruleset (`rollback-rules.yml` / `security/tools/rollback_rules.js`), or, in an
  emergency, the 2025-12-16 permissive rulesets (`security/RULES_ROLLBACK.md`).

## Step 1 — Re-read the real, deployed state first (don't trust this doc's memory of it)

This file describes the architecture as of stage 7. Re-verify against the actual files
before relying on any of it — they may have changed since:

- `security/collections.json` — the per-collection policy table (with
  `security/collections.schema.json`). Every generated section of `firestore.rules`
  (`collectionPolicy()`, `serverFields()`, `readerWrites()`, `selfKeyedSubcollections()`,
  `serverWrittenSubcollections()`, `collectionGroupRead()`) is written from it by
  `node security/generate.js`, which also writes the shim's
  `packages/shared_services/lib/generated/collection_policies.g.dart` and
  `functions/_public_collections.json`; edit the table, never the generated sections.
  Every collection Cloud Functions use must be declared server-owned there
  (`kind: "server"`, `serverWritten`, or `subcollections.<name>.serverWritten`) or listed
  with its client writers in `security/client_written_collections.json` —
  `security/check_server_collections.js` (run by its test in CI) fails otherwise.
  A `kind: "server"` collection whose reader must still change their own read state
  (e.g. `notifications`' `isRead`) declares `readerMayUpdate: [fields]` /
  `readerMayDelete: true` (generated into `readerWrites()`); the docs themselves are
  created by a callable (`notificationsSend`).
  Its `exceptions` section is the reviewed-exception list (EX-ADMIN-1, EX-DEV-1,
  EX-STEWARD-1; Storage's EX-PROFILE-PIC-1 lives in `security/storage_paths.json`):
  every match block and `grant*` function other than the generic tenant rule must be
  listed there with `what`, `why` and a `reviewed` date.
  `security/check_rules_exceptions.js` enforces that in CI (via its test), and
  `.github/CODEOWNERS` makes the rules, `security/**` and the index builder need the
  code owner's review.
  After any change to the rules or the table, run
  `node security/tools/rules_api_smoke.js` (needs the admin credentials; it calls the
  Rules API's read-only `test` method). It compiles the rules and runs representative
  requests, which catches Firestore's 1000-expression-per-request limit: a big map
  literal evaluated several times per request once made every ordinary write fail.
  Keep per-call lookup tables small (the generator buckets `collectionPolicy()` for
  this reason).
- `firestore.rules` (about 1450 lines, mostly generated tables) — the rules
  production runs. **This is ground truth**, not `FIRESTORE_PERMISSIONS.md`. Read its
  hand-written half (`inTenant`, `detail`, `readByIndex`, `docCreate`/`docUpdate`/
  `docDelete`, `subRead`/`subWrite` and the generic `match` blocks) before changing
  anything. Confirm what is actually released with
  `node security/tools/rollback_rules.js --list` (read-only).
- `storage.rules` and `security/storage_paths.json` — the same for Storage: one path
  family per prefix, the tenant rule for `groups/{g}/apps/{a}/**`.
- `functions/_shared.js` — `computeEntitlements` (pure, unit-tested) and
  `rebuildUserAccessIndex` (the Firestore I/O wrapper around it).
- `functions/access_control.js` — every trigger that calls `rebuildUserAccessIndex`.
  Grep `rebuildUserAccessIndex` in this file and enumerate every call site; there is no
  single "the trigger", there are several, and a change to entitlement logic must be
  correct from all of them, not just the one you happened to test.
- `packages/shared_services/lib/scoped_collection.dart` (and `scoped_storage.dart`,
  `public_collection.dart`) — the client-side convenience wrappers. **They are not an
  enforcement point.** They scope queries so the rules can prove them and inject
  `groupId`/`appId`/`creatorId`/`ownerIds` on create, but a malicious or buggy client
  could bypass them entirely — the rules are the only real enforcement boundary. Never
  "fix" a permission problem by changing the shim alone.
- `functions/guest_users.js` and `functions/_guest_admission.js` — if the change touches
  guest behavior specifically.
- `FIRESTORE_PERMISSIONS.md` and `STORAGE_PERMISSIONS.md` — read them, but verify every
  claim against the files above before trusting it.

## The architecture, structurally

- **`access_index` shape**: `status` ('ACTIVE'/'INACTIVE'/'SUSPENDED', a global kill
  switch), `roles` (platform-wide: `admin`, `developer` — not group-scoped; the `auditor`
  role was removed, D4a), `clearance_level` (numeric, checked against a collection's
  `requiredClearance`), `groups` (the user's active group IDs), `guest_groups` (the
  subset where they're only a guest; `memberRead` excludes them), `entitlements` (array
  of scope strings, see below), `denied_scopes` (frozen/suspended group IDs).
- **Where `roles`/`status`/`clearance_level` come from**: Firebase Auth custom claims
  (`platformRoles`/`platformStatus`/`clearanceLevel`), set only by
  `functions/_platform_access.js` `setPlatformAccess()` via role_manager.js's admin
  callables (`adminSetUserRole`, `adminSetUserStatus`). Never from `users/{uid}`: those
  fields are a display mirror (and `serverFields` there, so no client writes them).
  Server code reads the index only through
  `getAccessIndex()` (`_shared.js`), which overlays the claims;
  `scripts/check_gateways.js` rule `access-index-read` enforces that. Server endpoints
  that act on a request-named group use `functions/_tenant_access.js`
  (`requireGroupEntitlement`, `trustedGroupId`), and Storage paths from client data go
  through `functions/_storage_paths.js` (`tenantStorageFile`) — rules
  `callable-tenant-check` (ratchet) and `storage-object-path`.
- **Deactivated accounts** (`status` not ACTIVE, set only by `adminSetUserStatus`, the
  one switch behind the Users app chip and the Groups user dialog): `readPlatformAccess`
  returns them with no roles and clearance 0 (`effectivePlatformAccess`; `{raw: true}`
  only for role_manager.js, which edits the stored roles), so the rebuilt index and
  every platform-admin grant deny them (the rules' `hasRole()` and `inTenant()` also
  require `ACTIVE`); `getAccessIndex()` also empties their
  `groups`/`entitlements`; `setPlatformAccess` disables the Auth account and revokes
  refresh tokens on a status change; the app shell's `InactiveAccountGate` shows "Your
  account is inactive". A new server check that trusts `groups.adminIds` (not the index)
  must check `isAccountActive(index)` itself — see app_icons.js / app_group_settings.js /
  email_sender.js. The old `users/{uid}.isBanned` flag is retired.
- **Entitlement scope strings**, all keyed by `groupId:appId` (the collection's single
  `apps` entry, or the doc's `appId` for a multi-app collection):
  - `groupId:appId` — base tier: read every doc in scope, create, and edit/delete the
    caller's own docs (`creatorId`/`ownerIds`; `writeTier: "edit"` withholds the own-doc
    writes).
  - `groupId:appId:edit` — editor-tier: can edit/delete *other* users' docs in scope.
  - `groupId:appId:admin` — the only tier that reads or writes an
    `adminOnlyCollection`, or other members' docs in an `ownerScoped` collection.
  - `groupId:appId:collection:<name>` — **read-only**, scoped to exactly one
    collection. Granted to admitted guests from that app's `externalCollections` (and
    honored for guests only where the table says `guestShareable`), and to Bordereau
    Report's members for the three insurance apps' `insurance_applications`. This is
    the mechanism to reach for if you need finer-than-whole-app granularity for any
    role, not just guests.
  - `groupId:appId:guest` — an admitted guest of an embeddable app (plan D1): with
    ownership, the guest reads and writes their own docs, only in the app's
    `guestWritable` collections (and Storage `guestWritableFolders`). Mark only the
    record a guest submits; staff-side collections stay closed to guests.
  - `app:appId:steward` — members of the app's `stewardGroupIds`; EX-STEWARD-1 reads
    (and comments on) `stewardRead` docs whose `relatedAppId` is the app, from any group.
  - Group and app ids must match `functions/_tenant_ids.js` (Dart mirror
    `shared_services/tenant_ids.dart`); `computeEntitlements` skips any that don't.
    Never introduce a suffix that collides with an existing tier (`edit`, `admin`,
    `guest`, `collection:<name>`): `detail()` matches the joined strings literally.
- **Index hygiene**: `accessIndexNightlyRebuild` re-derives every index nightly and
  writes only drifted ones; `functions/_access_index_invariants.js` holds the
  properties every index must have (checked in tests and by the nightly run). A new
  entitlement shape must be taught to `parseEntitlement` there, or the nightly run
  alerts on every index carrying it.
- **The generic rule** (`match /{collection}/{id}`, its one subcollection level, and the
  collection-group block) routes on the collection's `kind`. For a tenant doc:
  `inTenant(ix, groupId)` (ACTIVE, a member, group not in `denied_scopes`) AND
  `detail()` (clearance, then the entitlement tier, with ownership only narrowing: D1).
  Creates also need `creatorId == uid`, an accepted id (`tenantIdOk`), the doc's `appId`
  in `apps`, and the field locks; updates never change `groupId`/`appId`/`creatorId`.
  The rules read the caller's access index with **one** `get()` (`idx()`, memoized per
  request) and, for subcollections, the parent doc. **Do not add another `get()`**
  (e.g. to look up `apps/{appId}` live) without a very strong reason; prefer baking
  whatever data you need into the precomputed `entitlements` array at rebuild time
  instead, the same way the guest collection-scoping was done.
- **Role → entitlement mapping** happens in `computeEntitlements`
  (`functions/_shared.js`): `member` (default) → base scope; `editor`/`manager`/`owner`/
  `super_admin` → `:edit` (and every member while `sharedEditing !== false`);
  `owner`/`super_admin` and real group admins (`adminIds`) → `:admin`; `guest` → only
  `:guest` plus `:collection:<name>` entries for `externalCollections`, gated on
  `appData.isEmbeddable === true` **and** on the guest being admitted to that (group,
  app) — `computeEntitlements`' `guestAdmissions`, from `computeGuestAdmissions` /
  `functions/_guest_admission.js`: public mode admits any guest; corporate mode only a
  guest with a `guest_identities` attestation whose domain is on the
  `corporate_access_configs` allowlist (empty allowlist = nobody). Never the blanket
  scope, never `:edit`/`:admin`. `onCorporateAccessConfigWritten` rebuilds a group's
  guests when its config changes. This role string lives on the
  `memberships/{groupId}_{uid}` doc, not on the user doc.
- **`apps/{appId}` permission config fields**: `allowedGroups` (tenants authorized for
  this app — also matched against `group.installedApps`, either is sufficient),
  `externalCollections` (collections admitted guests may read), `isEmbeddable`
  (whether guests can access this app at all), `embeddableAccessModes`,
  `sharedEditing`, `stewardGroupIds`, `securityTier`. All are `serverFields` on `apps`:
  only the `appsUpdatePermissions` callable (`functions/app_creator.js`) writes them.
  (`immutableFields` used to live here too but was never enforced and is retired;
  field locks are table keys.)
- **No bespoke `match` blocks.** Every collection goes through the generic rule; the
  per-collection differences are table keys. The only constructs outside the generic
  tenant grant are the reviewed exceptions above. **Before reaching for a new
  construct, check whether an existing table key already covers it**:
  `restrictEditToCreator` for "creator-or-admin-only, no group-role exception",
  `kind: "server"` (+ `readerField`) or `serverWritten` for a collection written
  exclusively via the Admin SDK, `selfKeyed` subcollections for a subcollection doc
  keyed by the caller's own uid (calendar's `attendees/{uid}` RSVP,
  `ce_events/{id}/registrations/{uid}`, `{fields, selfCreate, selfDelete}` per entry;
  only the owner writes one unless `editorsWrite: true` lets the parent's editors in too,
  and `selfRead: true` also limits reads to that uid and the app's `:admin` tier, with
  the server writing any aggregate onto the parent, as for Polls' ballots),
  `memberWrite` for per-user records every client writes.
- **Design goal**: "no new app needs a hand-written rules change at all" — new
  collections get coverage from one table entry, as long as their docs carry
  `groupId`/`appId`/`creatorId` (which `ScopedCollection` injects automatically). If
  your change needs a new rules construct rather than a table entry, double check it's
  actually a new cross-cutting permission concept.

## Guests, the audit trail and the Regulated tier

These are table keys, so a change to them follows every rule above. `SECURITY_TIERS.md` is
what the tier audit checks them against.

- **Guest confinement.** An admitted guest's `{g}:{app}:guest` grants own-doc access only in
  collections marked `guestWritable` (subcollections follow the parent), and own-file access
  only in the app's `guestWritableFolders` (`security/storage_paths.json`, a separate guest
  block in `storage.rules`). Shared config a guest reads is `guestShareable` and listed in the
  app's `externalCollections`. Lock the fields staff set on a guest's record with
  `staffOnly`/`serverFields`.
- **Audit trail.** `auditTrail: true` makes a trigger per collection (`functions/audit_trail.js`,
  from the generated `functions/_audit_collections.json`) record every create, update and
  delete in `audit_events` (server-written, `adminOnlyCollection`). The rules
  (`auditStampOk`) refuse any client write to an audited collection that doesn't set
  `lastModifiedAt` to the request time with `lastModifiedBy` the caller. `ScopedCollection`'s
  write methods stamp both, so before marking a collection, move every raw client write to
  them (`raw-doc-write` gateway rule), register the new `auditTrail<Collection>` trigger in
  `functions/function_generations.json`, and stamp emulator tests' writes with
  `serverTimestamp()`. A Rules API smoke case can't carry a timestamp, so it can only check
  an unstamped write is refused.
  - `auditTrail` applies to kind `tenant` and kind `server` (it's a server trigger). Server
    writes made for a caller stamp the same fields with `auditStamp(uid, at)`
    (`functions/_audit_trail.js`), or the trail records them unattributed; a delete, which
    can't carry a stamp, is recorded by its caller with `recordAttributedDelete` in the
    deleting transaction.
  - Who reads a collection's entries: the `audit_events` rule admits the `:admin` tier of the
    entry's `appId` in its `groupId`. The trigger records a collection's entries under its
    `auditAppId`, else its one `apps` entry (the rules' scope), else each doc's `appId`; set
    `auditAppId` when the docs carry none or the app whose admins should read the history
    differs (`groups` → `group-admin`), and `auditGroupIdFromDocId` when the doc id is the
    group (`groups`, `group_subscriptions`). Add a Rules API smoke case and an emulator case
    proving who reads the new entries.
  - `auditExempt` (a reason) is for writes that hold no record of their own; the generator
    allows it only on `notifications`, `users/metadata` and a `ledger` subcollection under an
    audited collection, never on an app's own tenant collection. It exists so a callable's
    `auditedWrites` may name those (`scripts/security_tier_audit/audited_callables.js`).
- **No hard deletes.** `blockDelete: true`. Check what deletes the collection first; where
  users genuinely delete, build a soft delete (`deletedAt`) and filter reads. In a
  `blockDelete` collection the rules (`softDeleteOk`) refuse every client edit of a doc
  with `deletedAt` except a restore that only clears it (its field lock decides who), and
  `tenantSubWrite` refuses every client write under any soft-deleted parent.
- **Subcollections and files.** Tier 4 holds a collection's declared client-writable
  subcollections to the same bar (`subcollections.<name>.auditTrail`/`blockDelete`,
  enforced by `governedSubWrite()`); a collection showing the shared comment thread
  declares `commentThread: true` instead of spelling them out. Attachment folders in
  Storage go in `storage_paths.json`'s `retainedFolders` (no client delete, overwrite or
  metadata change).
- **Staff and financial records** (ledgers, approvals) are `serverWritten` and recorded
  through a validating callable that takes the tenant, figures and author from the server
  (`insuranceRecordTransaction`, `functions/_insurance_ledger.js`), never trusted from the
  client.
- **Tiers.** Install gates use the effective tier, the lower of declared and computed
  (`effectiveSecurityTier`, `functions/_security_tiers.js`). On a PR, the security tier step
  of PR Checks fails when a change lowers an earned `business`/`regulated` tier or drops an app
  below its declared tier, unless the PR has the `security-tier-decrease-approved` label.

## Known sharp edges (read before touching triggers or entitlement generation)

- **The docs have drifted from the rules before, silently.** `FIRESTORE_PERMISSIONS.md`
  once carried a "Universal Firestore Rules" template that described mechanisms the
  deployed rules didn't have, and for months the repo rules weren't deployed at all.
  Always diff your understanding against the generated `firestore.rules` and the
  released ruleset, and update the docs whenever you touch the mechanisms they describe.
- **Fixed:** `functions/access_control.js`'s `onAppConfigurationWritten` used to only
  rebuild affected users' indices when `allowedGroups` changed, silently leaving
  `isEmbeddable`/`externalCollections` edits on existing apps unpropagated. It now
  also detects those fields via the extracted, unit-tested
  `entitlementRelevantAppConfigChanges(beforeData, afterData)` helper (see
  `access_control.test.js`), and fans out to every group with the app in
  `installedApps` in addition to `allowedGroups` (the fan-out previously missed the
  `installedApps` path entirely, for *any* triggering field). **The general lesson
  stands even though this specific instance is fixed**: whenever you add or change an
  `apps/{appId}` field that `computeEntitlements` reads, check whether
  `entitlementRelevantAppConfigChanges` needs to grow a new flag for it.
- **Fixed:** the guest-session-creation ordering hazard (`onUserCreated` racing
  `createGuestSession`'s explicit `rebuildUserAccessIndex` call and sometimes
  clobbering real entitlements back to blank) is resolved — `onUserCreated` now writes
  the baseline index with `.create()` instead of `.set()` and treats `ALREADY_EXISTS`
  (gRPC code 6) as a no-op instead of an overwrite, so whichever write lands first wins
  and the other becomes a harmless no-op. **The general lesson**: when two different
  code paths can both plausibly be "the first write" to the same document, prefer a
  conditional write (`create()`, a transaction, or an explicit existence check) over
  `set()` if either write could be more complete than the other.
- **Closed by D1:** the old rules let a caller self-own-create a doc tagged with any
  `appId` in one of their groups, even for an app the group hadn't installed. Since
  stage 3 ownership never grants on its own: a create needs the entitlement for the
  doc's scope (or `memberWrite`), and a declared collection refuses docs tagged with an
  app outside its `apps`. Don't reintroduce an ownership-only grant.
- **Fixed, and the lesson behind `detail()`'s shape:** the old rules' scoped-entitlement
  check once granted access to `__admin_only` docs through the bare scope — a refactor
  had merged an early-returning check into the same `||` chain as the regular scoped
  check without keeping the two mutually exclusive. When refactoring a rule function
  from sequential early-returns into one boolean expression, verify each original
  short-circuit still excludes what it excluded before, not just that the cases that
  should return `true` still do. (Per-doc `__admin_only` itself is gone: it failed open
  in list queries; `adminOnlyCollection` replaces it.)
- **Fixed:** bare-scope holders used to get full edit/delete on every doc in their
  group+app. Some apps' UX (e.g. `gifts`, `calendar_labels`, `whiteboard`) genuinely
  relied on "any group member can edit any shared doc," so the fix was the opt-out
  `apps/{appId}.sharedEditing` field (default `true` when unset) that
  `computeEntitlements` reads to decide whether to grant `:edit` to *every* non-guest
  member or only genuine editor-tier roles; the rules require `:edit`/`:admin` (or
  ownership at the base tier) for edit/delete. See `FIRESTORE_PERMISSIONS.md`'s
  `sharedEditing` note. **The general lesson**: when a loose default can't be tightened
  outright because some callers genuinely depend on it, look for a per-caller
  opt-in/opt-out field before concluding the whole platform is stuck with the loose
  behavior forever.

## Step 2 — Understand the requested change, and prefer the primitives that already exist

Before writing anything, work out: which entitlement string(s), table key or rules
branch does this change add/modify? Does it need a new role, or does an existing role
(`member`/`editor`/`owner`/`guest`/platform `admin`/`developer`) already cover
it? Does it need a new `apps/{appId}` config field (follow the `externalCollections`
precedent: config lives on the app doc, gets consumed inside `computeEntitlements`, not
inside the rules directly, to keep the rules to one index `get()`)? If the user's
request is ambiguous about scope (e.g. "restrict X" — restrict for whom, relative to
what baseline role?), ask before implementing.

**Check the app's security tier before deciding how much hardening it needs** — see
`SECURITY_TIERS.md` and `scripts/security_tier_audit/`. A casual app (games, polls)
being asked for ownership lockdown it doesn't actually want is a real mistake this repo
has made before (a casual shared-expense app, since retired, got a strict ownership
lockdown in PR #1931's original version that had to be walked back); a business-critical or
regulated app should get the more conservative read even when the request doesn't spell
it out. Run `node scripts/security_tier_audit/audit.js --app <appId>` to see what the
app's rules currently support, not just what's declared.

**Exhaust the existing generic primitives before reaching for a new rules construct.**
In priority order, check whether the need is already covered by:
1. **`groupId` scope** — `inTenant()`: the doc belongs to one of the caller's active
   groups (`index.groups`).
2. **Entitlement tiers** — base scope, `:edit`, `:admin`, `:guest`, `:collection:<name>`,
   per `groupId:appId`. "Only admins of this app can do X" is an entitlement check, not a
   new rule. **Ownership** (`creatorId`/`ownerIds`) narrows a tier: it is how "only the
   person who made this can touch it" works at the base tier, and `ownerScoped` extends
   it to reads.
3. **Roles/segments** — platform roles (`admin`/`developer`), or App Access
   user segments if the need is about a subset of users within a group rather than a
   tier.
4. **Per-app config flags consumed generically by `computeEntitlements`** —
   `sharedEditing` is the template: instead of hardcoding one app's name into
   the rules, add a config field on `apps/{appId}` that any app can opt into, and
   consume it in a way that isn't keyed to a literal app ID.
5. **The collection's table entry** in `security/collections.json` — every
   per-collection policy concept in one place: `kind`, `apps`, `writeTier`,
   `ownerScoped`, `adminOnlyCollection`, `requiredClearance`, `serverWritten`,
   `readerField`/`readerListField`, `memberRead`, `memberWrite`, `guestShareable`, `guestWritable`, `auditTrail`,
   `serverFields`, the field locks (`immutable`, `creatorOnly`, `ownerOnly`, `adminOnly`,
   `staffOnly` + `staffApps`/`staffOnlyAppIds`/`staffOnlyValues`), `protectedRoleField`,
   `restrictEditToCreator`, `immutableDoc`, `singleOwner`, `blockCreate`/`blockUpdate`/
   `blockDelete`, `idPattern`, `naturalKeyIds`, `publishTo`, `commentThread`, and `subcollections`
   (`serverWritten`, `selfKeyed`, `collectionGroup`, and the governed keys `auditTrail`,
   `blockDelete`, `authorField`/`authorMayUpdate`, `softDelete`, `selfArrayFields`/`selfMapFields`
   for read receipts and reactions others mark with their own uid, and `createdAtField`). Deliberately **not** Firestore
   data: it ships in the same PR and deploy as the enforcement, costs no extra reads,
   and CI (`security/generate.test.js`, `node security/generate.js --check`) fails if
   the rules and the table disagree.

A new `collection == 'x' && appId == 'y'` branch — or any single-app-named clause in
the hand-written rules — should be the *last* resort, not the first idea. If you catch
yourself about to write a literal `appId == '<name>'` string into `firestore.rules`,
stop and ask: is this really a new cross-cutting permission concept, or is it one
app's document-level ownership/membership model that the existing table keys already
almost cover?

**Before concluding the primitives don't fit, check whether the app's data model — not
the permission concept — is the actual obstacle.** The generic ownership branch keys off
specific field shapes: `creatorId` (a single, immutable uid) and `ownerIds` (an *array* —
anyone in it gets full edit/delete). An app that models ownership differently (a singular
`ownerId` string instead of an `ownerIds` array, or that needs one document's owner to
have override authority on a *related* document but never records that relationship on
the related document itself) will look like it needs bespoke rules, when actually it just
isn't shaped like every other collection yet. Two tells this is what's happening, not a
genuinely new permission concept:
- The bespoke code you're about to write is reimplementing *ownership checking* — a new
  `isXOwner()`/`isXMember()` helper that inspects a field the generic rule doesn't already look at
  — rather than adding a genuinely new *rule* (field validation, a role, a scope).
- Renaming a field, or denormalizing one extra uid onto a related document at write time,
  would make an existing primitive apply directly with no new rule logic at all.

When that's the case, prefer reshaping the app's collections/fields to match convention —
even if it costs a one-time data migration and a service-layer change — over adding a
parallel access-control system in `firestore.rules`. Concretely: rename a singular
`ownerId` to an `ownerIds` array; when one document's owner needs override authority on a
*related* document (e.g. an event owner deleting another member's expense under that
event), denormalize that owner's uid into the related document's own `ownerIds` at
creation time instead of writing a cross-document `get()`-based bespoke check; pair with
`sharedEditing: false` on the app if the actual gap is that bare group membership was
granting blanket edit that ownership was supposed to gate instead. This costs more up
front than a bespoke rules construct, but per this repo's engineering philosophy
(`CLAUDE.md`), reshaping the data is the correct fix when the recurring shape — "this
app's ownership model doesn't use the standard field names" — is the actual bug, not a
one-off to route around. Whatever residual truly isn't an ownership question at all
(per-field create-time business validation like amount/currency format checks, or
membership in an app-defined sub-group narrower than the group itself) belongs in a
validating callable over a `serverWritten` collection, or in a new generic table key
confirmed with the user (Step 2's last paragraph) — keep that residual as small as
possible once the data model fix is in place. (Concrete instance: PR #1931, for a since-retired shared-expense
app — three bespoke `match` blocks and three hand-rolled ownership helpers, when the
actual gap was a singular `ownerId` string instead of `ownerIds`, and no denormalized
event-owner uid on child documents.)

If it's the latter, **use the collection's table entry** rather than writing a new
rules clause: add or edit the entry in `security/collections.json`, listing which fields
fall into `immutable`, `creatorOnly`, `ownerOnly` or `adminOnly`, then run
`node security/generate.js`. It ships in the same PR/deploy as whatever change needed
it — no separate seed step, no runtime lookup, no window where the rule and its config
could be out of sync.

**Why `creatorOnly` isn't vacuous even for a collection with no other special-casing:**
ownership already lets *anyone* in a doc's `ownerIds` edit it at the base tier — not just
the creator. `creatorOnly` narrows that back down to creator-only for a specific subset
of fields, for collections that deliberately give non-creator participants edit access
for *some* purpose (submitting trivia answers, filling in an assigned form, editing
shared list items) but want a narrower set of governance fields — who's allowed in, what
state the whole thing is in — reserved for the creator alone. A collection whose
`ownerIds` only ever contains the creator (e.g. `photo_albums`) doesn't need an entry
at all — there's no other participant to wall off from anything.

`adminOnly` is the "even the creator can't touch this directly" category (only a
platform admin may change the field from the client) — it forces every mutation of a
listed field through a server-validated Cloud Function/callable instead, for a case
where a raw write from the creator's own account could violate an invariant a bare
field-diff check can't express. `calendar_events`' `ownerIds`, `materializedThrough` and
`createdAt` use this, since `CalendarService` owns those exclusively (`groupId`, `appId`
and `creatorId` are immutable on every tenant doc anyway). Whether a governance field
needs `creatorOnly` or `adminOnly` is a judgment call worth revisiting once client
behavior is confirmed — Lists' membership fields were originally the "even the creator
can't bypass the callable" shape, then relaxed once the client was confirmed to already
route every add/remove through the callables exclusively. This table-driven approach
still requires naming the collection and field explicitly — it isn't a blanket,
zero-config rule for every collection, because some apps (`notes`, whose sharing model
has any current owner update `ownerIds` when `sharedWithIds` changes; also `sell`,
`data_modeler`) mutate governance-shaped fields via direct client writes rather than a
callable (`groups`' membership fields are already `serverFields`, written only by the
T7 callables). **This is a gap to close, not a permanent ceiling** — per this repo's
engineering philosophy (`CLAUDE.md`), the fact that the same field names
(`ownerIds`/`memberIds`/`adminIds`/`members`) and the same shape of risk recur across
many apps is itself the signal that the durable fix is a single generic
membership-mutation callable plus a universal table entry on those field names — not N
per-app entries maintained by hand forever.

**`restrictEditToCreator: true` is a different axis from the field categories above —
it gates the *whole document's* `update`/`delete`, not specific fields.** Reach for this
when a collection needs "only the creator (or platform admin) may ever touch this
document, full stop, no group-role exception" — something the tiers can't express even
with `sharedEditing: false`, since `computeEntitlements` still hands `:edit` to genuine
`editor`/`manager`/`owner`/`super_admin` role holders regardless of that flag (that's
deliberate for most apps — an app's own group manager *should* usually be able to fix
another member's document — but wrong for a collection where that's never legitimate).
Today only `usage_daily` sets it. `calendar_events` was the motivating case when this was
built, but a separate decision (confirmed with the user) deliberately widened
`calendar_events` instead, so editor-tier group roles keep edit/delete access to other
members' events; see FIRESTORE_PERMISSIONS.md's "sharedEditing" section.
`documentation/polls/improvements-security.md` independently flags the identical
"creator-only, no role exception" gap on `polls.closedAt` as an open item. When set, a
collection's field-level categories still apply on top — `restrictEditToCreator` only
changes who gets past the door at all, not what they can touch once inside.

**`memberWrite: true` is the one write grant that skips the app entitlement**
(`memberWriteOk()` in `firestore.rules`). Use it only for per-user records every
client writes whatever app is open (today: `usage_daily`, the Usage Meter counters). Any
non-guest active member of the doc's group may create and update, never delete, a doc whose
`creatorId` (and `readerField`, if declared) is the caller. The field locks still apply, and
reads stay entitlement-scoped. The validator requires `singleOwner` and rejects
`writeTier`/`requiredClearance`/`adminOnlyCollection`/`serverWritten` alongside it. For a
natural key, `idPattern` may hold `<groupId>` (the doc's groupId) and `<uid>` (the caller),
so the id is tied to both without a tenant-tagged rekey.

**History, briefly:** before the table, per-collection policy lived in several parallel
hand-maintained tables and literal `collection != 'x'` exclusion chains in
`firestore.rules` (`membershipLock()`, `fieldPermissions()`, `immutableCollections()`,
`singleOwnerCollections()`, `serverOnlyCollections()`), and for one day in
`field_permissions/{collection}` Firestore docs editable from App Manager. Both were
folded into `collectionPolicy()` and then into `security/collections.json`. The lesson
that survives: config that decides access ships as code, in the same PR as its
enforcement, with no runtime read. If you find a doc or test still naming one of the
old tables, that's drift to fix, not a second mechanism to preserve. Security Audit's
"Schema" tab (`packages/security_audit/lib/schema_tab.dart`) only browses
`collection_catalog`; configuring a restriction is a table PR.

`trivia_games` shows the one shape the field categories can't express: "anyone may join,
but one privileged member (the host) can never be removed or reassigned." That is
`protectedRoleField: "hostId"`, checked by the generic `fieldLocksOk()`.
Verify against apps with a similar shape — does *this* app's flow rely on a symmetric "any
owner may add/remove" model (`notes`), an asymmetric one where only the creator may
add/remove but even the creator goes through validation logic worth keeping server-side
(Lists, trivia's host identity), or a governance-fields split where participants get broad
edit but the creator alone controls state (trivia's lifecycle fields, forms' `ownerIds`)? —
before assuming a collection needs anything new, and check whether the need is "lock the
whole field" (the categories) or "protect one member's presence within an otherwise-open
field" (`protectedRoleField`).

**If, after this check, no existing primitive — or reasonable generalization of one —
can express the requirement, that's a genuine gap in the permission model, not something
to route around quietly.** Stop and confirm with the user before implementing anything.
Present:
- What you're proposing to add, concretely (the new table key/kind, rules function, or
  entitlement).
- Why none of the existing primitives (groupId scope, entitlement tiers and ownership,
  roles/segments, per-app config flags, table keys) can express it.
- What it would take to make this a supported, generic capability instead of a one-off
  (a new entitlement tier, a new generic table key, etc.), so the next app
  with a similar shape of problem doesn't need its own bespoke carve-out either.
- If the need is genuinely impossible to satisfy with any reasonable extension of the
  current model, say so plainly instead of forcing an awkward fit.

## Step 3 — Check for in-flight work

`gh pr list --search "firestore" --state open` and `gh pr list --search "access_index" --state open` (adjust terms to the specific area) to avoid duplicating or conflicting with another in-progress permission change. This area is exactly where two concurrent changes can silently interact badly — be more cautious here than the baseline "check for in-flight work" step in other skills.

## Step 4 — Implement, respecting the invariants above

- Prefer encoding new logic in `computeEntitlements` (precomputed, unit-testable) over
  adding conditions to the rules that require extra `get()` calls.
- If you touch entitlement generation, trace through **every** `rebuildUserAccessIndex`
  call site in `functions/access_control.js`, not just the one most relevant to your
  change — that's the exact bug class this skill exists to prevent.
- Express per-collection changes as table entries and regenerate
  (`node security/generate.js`); commit the table, `firestore.rules`, `storage.rules`,
  `collection_policies.g.dart` and `functions/_public_collections.json` together.
- A genuinely new rules construct (a new kind, key or `grant*` function) goes in the
  generator (`security/generate.js`, `generate_storage.js`) and the hand-written half of
  the rules, with its schema entry, and — if it grants anything without `inTenant()` —
  an entry in the table's `exceptions` (`what`, an honest `why`, `reviewed` = today,
  `firestoreMatchBlocks`/`storageMatchBlocks`/`ruleFunctions`).
  `node security/check_rules_exceptions.js` fails otherwise, and also fails on entries
  whose block is gone. Teach `security/rules-tests/lib/expected.js` (or
  `expected_storage.js`) the same decision so the matrix checks it.
- If you add a new `apps/{appId}` config field that should take effect immediately for
  existing users, check whether `onAppConfigurationWritten` needs its change-detection
  extended to cover it (see "Known sharp edges" above), and add it to `apps`'
  `serverFields` and `appsUpdatePermissions`' validation.
- Keep the change to one coherent permission concept — don't bundle unrelated rules
  cleanup into the same PR.
- **Keep rules comments and table `comment`s general, not incident-specific.** A comment
  should explain a *mechanism*, an *invariant*, or a durable *lesson* — something
  that still makes sense to a reader who has no idea which PR or ticket added it. It
  should not narrate the specific app's UI flow, list what was considered and rejected
  for this one case, or restate what the adjacent code already says. Put the ticket-
  specific narrative (why this app needed it, what UI flow depends on it, what
  alternatives were rejected and why) in the **PR description** instead. A table entry's
  `comment` is emitted into `firestore.rules`, so the same bar applies to it.

## Step 5 — Test

- `node --test security/*.test.js security/tools/*.test.js` (table/generator in sync,
  exception guard, server-collection guard, deploy/rollback tools), and
  `node scripts/check_gateways.js`.
- The emulator suite: `(cd functions && npm ci) && (cd security/rules-tests && npm ci && npm test)`
  (needs a JDK 11+; see `security/rules-tests/README.md`). The generated matrix covers
  every table entry; `RULES_MATRIX_ONLY=<regex>` narrows a run. CI runs it as
  `.github/workflows/rules-tests.yml` on every rules or `security/**` change.
- If you added or changed entitlement-generation logic, add/extend `node:test` cases in
  `functions/_shared.test.js` (they call `computeEntitlements` directly with plain
  objects, since it's a pure function): `cd functions && node --test _shared.test.js`.
- With the admin credentials, `node security/tools/rules_api_smoke.js` and
  `node security/tools/storage_rules_api_smoke.js` run representative requests
  through the production rules engine (read-only) against the files in your checkout.
- If you couldn't run something (no JDK, no credentials), say so explicitly in the PR
  body and describe what a reviewer should run.

## Step 6 — Update documentation if it would otherwise go stale

If the change affects anything `FIRESTORE_PERMISSIONS.md` currently describes (the
access index shape, the app config fields, the role hierarchy, the ownership rules),
or `STORAGE_PERMISSIONS.md` for Storage, or the affected apps' `documentation/<app>/`
developer and interfaces docs, update the relevant section — don't let it drift further. Don't do a wholesale rewrite;
touch only what your change actually affects.

## Step 7 — Commit, push, open the PR

Per this repo's standing `CLAUDE.md` instruction: branch off `origin/main`
(`git fetch origin main && git checkout -b claude/<short-desc> origin/main`), stage
explicitly (never `git add -A`), commit, push, and `gh pr create --draft`. Run
`scripts/ci/local_check.sh --rules` (a permissions change always touches the rules
suite's inputs), fix everything it reports, then `gh pr ready <n>` (CLAUDE.md, "Draft PRs, local checks and PR size"). **Explicitly call out
in the PR description that this touches the permission/authorization model** and name
the specific table keys, rules functions, entitlement strings, or trigger sites
affected — this needs closer reviewer attention than an average change. Say that the
deploy train deploys the rules within about 15 minutes of the merge. Never merge it yourself.

## Step 8 — Report back

PR URL, a plain-language summary of who gains or loses access to what as a result, and
any known sharp edges you decided *not* to fix as part of this change (name them
explicitly, don't bury them).

## Constraints

- Never add a literal `appId == '<name>'` (or otherwise single-app-named) branch to
  `firestore.rules` without first exhausting the existing generic primitives (Step 2)
  and, if genuinely none apply, confirming the approach with the user first.
- Never hand-edit a generated section of `firestore.rules` or `storage.rules`; edit the
  table and regenerate.
- Treat the generated rules (and the released ruleset) as ground truth over
  `FIRESTORE_PERMISSIONS.md` for current behavior; update the doc, don't just defer to it.
- Never reintroduce ownership as a grant on its own (D1), or a `visibility`-style
  cross-group read on tenant docs (D2: publish instead).
- Never add a second `get()` call to the hot path without strong justification; prefer
  precomputing into `entitlements` instead.
- Any change to entitlement generation must be verified against every
  `rebuildUserAccessIndex` trigger site in `functions/access_control.js`, not just one.
- One permission concept per PR.
- Never merge the PR yourself — leave it for human review, same as every other
  PR-producing skill in this repo.
- Before writing bespoke ownership-checking logic, check whether the app's data model —
  not the permission concept — is the real obstacle (mismatched field names/shapes like
  `ownerId` vs. `ownerIds`, or a missing denormalized uid); reshaping the data, even with
  a migration, beats a parallel access-control system in the rules.
- Keep rules comments to durable mechanism/invariant explanations, not
  per-PR narration — ticket-specific rationale belongs in the PR description (Step 7),
  not in the file every future change has to read past.
