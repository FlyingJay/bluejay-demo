
# Bluejay Permission System: Developer Playbook

This system pre-calculates each user's permissions into an **Access Index** (`users/{uid}/metadata/access_index`), and enforces them with one generic set of **Firestore Security Rules** generated from a single table, `security/collections.json`, plus the per-app **App Configuration** documents. Production enforces these rules for every collection and every Storage path (the staged rollout from the permissive 2025-12-16 release finished with stage 7 on 2026-11-06; see §7).

You do not need to write custom rules when launching a new app. You declare each collection in the table (one line for most apps, see §7) and configure the data payloads correctly.

---

## 1. The Core Architecture

### The Access Index (`users/{uid}/metadata/access_index`)
A background Cloud Function manages this document. It is the user's "VIP Pass." **Never write to this from the frontend** (the rules allow no client write to `users/{uid}/metadata`).
```json
{
  "status": "ACTIVE",               // 'ACTIVE', 'INACTIVE', or 'SUSPENDED' (Global Kill Switch)
  "roles": ["admin", "developer"],  // Platform-wide roles (from Auth custom claims)
  "clearance_level": 3,             // Numeric tier (0-5), checked against a collection's requiredClearance
  "groups": ["broker-alpha"],       // List of active groups the user belongs to
  "guest_groups": [],               // The subset of `groups` where the user is only a guest
  "denied_scopes": ["frozen-corp"], // Specific groups that are frozen (e.g., unpaid bill)
  "entitlements": [
    "broker-alpha:insurance-app",        // Base tier: read, create, edit/delete own docs
    "broker-alpha:insurance-app:edit",   // Edit tier: edit/delete others' docs
    "broker-alpha:insurance-app:admin",  // App-Admin tier (adminOnlyCollection, ownerScoped)
    "app:insurance-app:steward"          // Steward of the app (see stewardGroupIds below)
  ],
  "lastUpdated": "2026-04-29T12:00:00Z"
}
```
Group and app ids are lowercase with inner hyphens (see "Index hygiene" below), so the entitlement strings above use hyphenated ids such as `broker-alpha`.

### The App Configuration (`apps/{appId}`)
This defines the "Laws" of your micro-app. It is created either in App Manager (`packages/app_creator`) or, for an app built in a pull request, from the package's `bluejay_app.json` manifest by `register-apps.yml` after the live deploy. App Manager owns it after creation; the manifest sync never writes an existing app doc.
```json
{
  "appId": "insurance-app",
  "allowedGroups": ["broker-alpha"],      // Tenants authorized to use this app
  "externalCollections": ["applications"],// Collections admitted guests may read (only guestShareable ones)
  "isEmbeddable": true,                   // Required before guests get ANY access to this app
  "clientPortal": true,                   // The app has a client view: a group's client portal may give it to clients
  "sharedEditing": true,                  // Default when unset. false = only owners/editor-tier can edit others' docs
  "stewardGroupIds": ["partner-co"],      // Groups that manage this app for every group using it
  "visibility": "public"                  // Any group may install it. Missing or "private": only groups it is made available to
}
```

> **Who writes these fields:** `allowedGroups`, `stewardGroupIds`, `isEmbeddable`,
> `embeddableAccessModes`, `externalCollections`, `sharedEditing`, `securityTier` and
> `visibility` are `serverFields` on `apps` (`security/collections.json`). `firestore.rules`
> rejects every client write to them, platform admins' and developers' included. The
> `appsUpdatePermissions` callable (`functions/app_creator.js`, used by App Manager) is
> their only writer. It validates each value, audits the change in
> `system_audit_logs`, and its write triggers `onAppConfigurationWritten`'s
> access-index rebuild. (`immutableFields` used to live here; nothing ever enforced it
> and it is retired. Field locks are the table's `immutable`, `creatorOnly`,
> `ownerOnly` and `adminOnly` keys, see §3.)

> **`stewardGroupIds` — managing an app across the groups that use it:** a group listed
> here (e.g. a partner that co-builds the app for its clients) is the app's *steward*.
> `computeEntitlements` grants each of its non-guest members `app:<appId>:steward` —
> deliberately not `groupId`-scoped, and regardless of whether the steward group has the
> app installed. The rules' EX-STEWARD-1 grant (`grantStewardRead()`) checks it against a
> doc's **`relatedAppId`** instead of its `groupId`, and only in collections the table
> declares `stewardRead` (today `bug_reports` and `feature_requests`): stewards may read
> any doc about the app in any group, and comment on it (create a `comments` subcollection
> doc whose `authorId` is the caller, and like comments through their own `comment_likes` doc). It grants nothing else — no read of the app's own
> data in client groups, no edit, no create. So stewards see every client's requests for
> the apps they manage, through `ScopedCollection.queryForRelatedApp()`, while each client
> still sees only its own group's. `onAppConfigurationWritten` rebuilds the before/after
> steward groups' members when the field changes.

> **`sharedEditing` — who can edit a document they didn't create:** `computeEntitlements`
> grants every non-guest member `groupId:appId:edit` (not just `editor`/`manager`/`owner`/
> `super_admin` roles) whenever `sharedEditing !== false` — which includes the field being
> entirely absent, so every app that predates this field keeps its original behavior with
> zero migration. The rules' entitlement check (`detail()` in `firestore.rules`) lets the
> bare `groupId:appId` tier edit or delete only the caller's own docs (`creatorId`/`ownerIds`);
> anyone else's doc needs `:edit` or `:admin`. Set `sharedEditing: false` on an app's `apps/{appId}` doc (via the
> "Shared Editing" toggle in App Manager's edit-app screen, `packages/app_creator`) to
> restrict edit/delete to genuine editor-tier roles, document owners, and real group admins
> (`groups/{groupId}.adminIds` — a group admin always gets `:edit`/`:admin`, regardless of
> `sharedEditing` or their `membership.role`, since `adminIds` and `role` are independently
> maintained and can diverge; `setGroupAdmins` and `setGroupMemberRole` in
> `functions/group_membership.js` change them separately).
> **Before turning it off, confirm the app has its own way of expressing "who else can edit this" —**
> e.g. an explicit `ownerIds`-based sharing/membership list (see `notes`' `sharedWithIds`,
> `whiteboards`' `memberIds` or `task_list`'s `members`, all synced into `ownerIds` for
> exactly this reason) — or legitimate collaborative features silently break for plain
> members. Apps with no such narrower concept (e.g. `calendar_labels` and Gifts'
> `gift_categories`, whole-group shared resources by design) should keep
> `sharedEditing: true`. In an `ownerScoped` collection `sharedEditing` reaches only the
> docs a member owns, since `:edit` there applies to owned docs alone.
>
> **Apps confirmed by direct code reading (not just inference) to need `sharedEditing: true`,
> with no narrower ownership model to fall back on** — do not disable without giving each
> a real fix first (see the per-package `developer.md` cited for the specific reasoning):
> - `whiteboard` (`apps/whiteboard`) — real-time collaborative canvas; any member of a
>   board (its `ownerIds`, kept equal to `memberIds`) erases/edits any other member's stroke,
>   shape, or text on it. See `documentation/whiteboard/developer.md`'s
>   "Security / Authorization" section.
> - `app_maker` (`apps/app-maker`) — any group member can add context/edit a request they
>   didn't submit; documented directly in `AppMakerDetailScreen`'s doc comment
>   (`packages/app_maker/lib/app_maker_detail_screen.dart`).
> - `gallery_app` (`apps/art-gallery` — note the appId mismatch, see below) — `_canDeletePhoto`
>   is already correctly `ownerIds`/entitlement-gated (unaffected either way by this flag),
>   but `_handleVote` writes the vote arrays on the photo doc itself, which takes edit access
>   to someone else's photo. Moving its votes to the shared `VoteToggle` helper
>   (`shared_services/vote_toggle.dart`: a self-keyed `votes/{uid}` subcollection with a
>   server-recounted tally, as Improve Apps uses) removes that dependency.
>   See `documentation/gallery_app/developer.md`.
>
> **Apps that looked like candidates but turned out to be false positives on closer
> reading** — don't trust a `sharedEditing`-relevance claim (including the list above)
> without re-verifying the actual reachable UI:
> - `cookbook` (`apps/cookbook`) — has a `canEditNotes`-gated non-creator save path that
>   *looks* like shared editing, but the edit-mode toggle that would expose it to a
>   non-creator only renders for the creator, and the read/edit mode switch independently
>   forces read-only for non-creators regardless. Confirmed unreachable; `sharedEditing`
>   is `false` here. See `documentation/cookbook/developer.md`'s "Update path" section.
> - `ai_pipelines` (`apps/ai-pipelines`) — pipelines/agent profiles looked like they might
>   be a shared team library (no per-item visibility filtering, `watchPipelines()`/
>   `watchProfiles()` show the whole group's set to everyone), but `ownerIds` was already
>   correctly `[creatorId]` from creation onward (`updatePipeline`/`updateProfile` never
>   touch it) and no sharing feature exists anywhere in the package — the "any member can
>   edit" behavior was a UI gap (Edit/Delete shown unconditionally), not a designed
>   feature. Fixed the UI to hide Edit/Delete from non-creators; `sharedEditing` is `false`.
> - `calendar_labels` (part of `apps/calendar`, which also covers `calendar_events`) — same
>   shape as `ai_pipelines`: `ownerIds` already correctly `[creatorId]` from creation
>   (`CalendarLabel.toMap()` never includes `ownerIds`, so updates can't drift it), UI gap
>   was showing Edit/Delete to every member regardless of `creatorId`. Fixed; `sharedEditing`
>   is `false`. `calendar_events` used to enforce creator-only edit/delete via its own
>   bespoke `firestore.rules` block regardless of this flag; that block was later removed in
>   favor of the generic tenant rule plus the table's `adminOnly` field lock on
>   `calendar_events` (`ownerIds`, `materializedThrough`, `createdAt`), so
>   `calendar_events` now also depends on this flag staying `false` — flipping it back to
>   `true` would let any group member edit/delete other members' events, not just labels.
>
> **Code fixed but deliberately NOT yet enabled — needs a product decision first:**
> - `data_modeler` (`apps/data-modeler`) — was project-membership-gated (any project member
>   could edit any model); rebuilt to a `notes`-style per-model `sharedWithIds` sharing
>   model (see `DataModel.canEdit`/`_shareModel` in `packages/data_modeler`). While
>   backfilling `data_modeler_fields`' `ownerIds` to match their parent model, found that
>   **17 of 19 existing `data_modeler_models` documents (all in the `northwind` group)
>   have no `creatorId`/`ownerIds`/`appId` at all** — pre-`ScopedCollection` legacy or
>   seeded data. Nobody but their group's `:edit` holders can edit them, so enabling
>   `sharedEditing: false` wouldn't make anything
>   *worse*, but it also wouldn't fix these records — they'd need a real owner assigned
>   first (whose call that is depends on who `northwind` actually wants to own them;
>   not a call to make unilaterally). `sharedEditing` is still unset (default `true`) for
>   `data-modeler` pending that decision.
>
> Toggling this field rebuilds every affected user's access index via
> `onAppConfigurationWritten` in `functions/access_control.js`
> (`entitlementRelevantAppConfigChanges` tracks it), same as `allowedGroups`/
> `isEmbeddable`/`externalCollections`.
>
> **Before touching `sharedEditing` for any app not listed above, first check its `APP_ID`
> constant actually matches its registered `apps/{docId}`.** This turned out to be a
> widespread, separate bug — 21 packages so far had a Dart `APP_ID` that never matched
> their real registered app id (usually underscore-vs-hyphen), meaning the rules'
> entitlement scope match could never succeed and the app was silently running on ownership alone the whole
> time. `scripts/firestore_admin/lib/legacy_app_id_fixes.json` is the authoritative,
> current record of every instance found and fixed so far (the rules plan's M3 migration,
> `scripts/firestore_admin/migrations/2026-11-05_canonicalize_app_ids.js`, applies it; it
> replaced the in-app `BackfillMismatchedAppIdsScript`, retired with T14) — it grows every
> time a new one turns up. A full sweep of all 76 packages with an `APP_ID`
> constant (cross-checked against every registered `apps/{docId}`) turned up no further
> instances as of this pass. A handful of apps also have **no registered `apps/{docId}` at
> all** (`insurance_admin`, `shop_chat`, `payments` confirmed so far) — for those,
> `sharedEditing` can't be set because there's no doc to set it on, and no member holds
> an entitlement for them: their tenant data is reachable only through callables, platform
> roles, or another app's entitlement.
>
> **Two of the fixed packages had existing documents with no `appId` field at all** (not
> just the wrong value) — `merchant_portal`/`poker_preflop`/`snake_blitz`'s legacy docs and
> all of `gifts`' (registered as `people`). These predate `ScopedCollection` entirely, so
> a rename-only fix can't reach them (it filters on the *old* `appId` value, which these
> documents never had). The one-off `BackfillLegacyUserScopedDocsScript` (run 2026-09-03,
> since retired with T14) backfilled `appId`/`creatorId`/`ownerIds` from
> each document's existing `userId` field (or, for `snake_blitz_stats`, the document ID
> itself — its write path has always been `.doc(uid).set(...)`), and the rules plan's
> M1/M2 migrations backfilled `groupId`/`appId` on the rest. One collection,
> `gift_categories` (48 documents, part of the `gifts`/`people` app), has **no
> owner-identifying field of any kind** and is deliberately left alone — the same
> orphaned-data situation as `data_modeler`'s 17 `northwind` models above, needing a
> product decision rather than a silent backfill.
>
> **CI blocks this bug class from recurring**, via `scripts/check_app_ids.js`, the
> blocking **Check every app id is registered** step in the `build_and_preview` job of
> `.github/workflows/deploy.yml`. Every package's `APP_ID` constant and every route key
> in `lib/routing/app_router.dart` must be registered: in the committed snapshot of the
> `apps` collection (`scripts/registered_app_ids.json`, refreshed by
> `scripts/firestore_admin/refresh_registered_app_ids.js`), declared by a valid
> `packages/<package>/bluejay_app.json` manifest, or listed with a reason in the
> script's `KNOWN_UNREGISTERED` table. A manifest ties the two ids together at the
> point of entry: its `appId` must equal the package's `APP_ID`, and
> `.github/workflows/register-apps.yml` creates `apps/{appId}` from it once the code is
> live, so a new app's registered id is the id its code uses. Apps created by hand in
> App Manager still need the snapshot refreshed in the PR that uses the id.

> **Guest access, concretely:** a membership with `role: "guest"`
> (`functions/guest_users.js`) never receives the blanket `groupId:appId`
> entitlement, and never `:edit`/`:admin`. For each embeddable app
> (`isEmbeddable === true`) that admits the guest (`embeddableAccessModes`; corporate
> mode also needs an attested domain, `functions/_guest_admission.js`),
> `computeEntitlements` (`functions/_shared.js`) grants `groupId:appId:guest` and one
> read-only, collection-scoped entitlement per name in `externalCollections` —
> `groupId:appId:collection:<name>`. The rules honor a guest's collection scope only in
> collections the table declares `guestShareable` (D1), so app config can never open
> other people's records to every guest. With `:guest`, a guest creates, reads, edits and
> deletes their **own** documents (`creatorId`/`ownerIds`) only in collections the table
> declares `guestWritable`, and their subcollections through the parent (unless the
> collection sets `writeTier: "edit"`). Every other collection of the app stays
> staff-only, so a guest's reach is exactly its app's `guestWritable` collections plus
> `guestShareable` reads. Ownership narrows the `:guest` entitlement, it never grants on
> its own. The group's `memberRead` collections (the
> member directory, memberships, invitations) exclude guests (`guest_groups`).
>
> **Portal clients** are guests too: a guest membership with `guestType: "client"`
> and `clientStatus: "active" | "pending"` (`functions/_client_portal.js`). They sign in
> with their own verified email, take no seat, and fall under the same guest
> confinement. An active client gets only `groupId:appId:guest`, for each app the
> group's `portal_configs/{groupId}` lists that is installed and has
> `apps/{appId}.clientPortal: true` (`computeClientAdmissions`); no `:collection:`
> scope, and nothing while pending. `onPortalConfigWritten` rebuilds a group's clients
> when the portal is switched on or off or its app list changes. A guest membership
> without `guestType` is a visitor (an anonymous embeddable-app session) and keeps the
> `isEmbeddable` path above.
>
> A client reads a record of another collection two ways. Where the collection declares
> `clientReaderListField` (`clientUids`, kept by `functions/client_links.js`), the uids in
> that list read the doc while they hold `groupId:appId:guest` in its group
> (`isClientReader()`); `files` lists the clients a file is shared with and the client who
> uploaded it. Where a collection is `guestWritable` and `ownerScoped`, a client the server
> put in `ownerIds` reads and writes that doc like any owner: `conversations`, where the
> chat callables add a client (`clientUid`) to a conversation a member starts with them,
> or to the one the client starts with the people the portal config's
> `messageRecipientIds` names (else the group's admins).

> **Index hygiene:** besides the per-source triggers in
> `functions/access_control.js` (`onGroupWritten` also rebuilds anyone added
> to or removed from a group's `memberIds`), `accessIndexNightlyRebuild`
> rebuilds every user's index nightly from source
> (`functions/_access_index_rebuild.js`), writes only the ones that changed,
> checks each against `functions/_access_index_invariants.js`, and records a
> summary in `access_index_rebuilds/latest`. Group and app ids must match
> `functions/_tenant_ids.js` (1–63 lowercase letters, digits and inner
> hyphens; no `:` or `_`, so the joined entitlement strings stay
> unambiguous); `computeEntitlements` skips and logs any id that doesn't.

> **Membership inputs are server-owned (rules plan T7):** `memberships`,
> `invitations` and `groups` are `serverWritten` (security/collections.json), so a
> group's `memberIds`, `adminIds`, `installedApps` and `isFrozen` — and its
> descriptive fields too — have no client writer.
> Non-guest members of the group read them (`memberRead`; a member also reads their own
> membership through its `readerField`, `userId`), but every change goes through a
> callable that checks the caller's standing in the group:
> `functions/group_membership.js` (`createGroup`, `addGroupMember`,
> `removeGroupMember`, `setGroupAdmins`, `setGroupFrozen`, `setGroupMemberRole`,
> `updateGroupDetails` and `setGroupDefaultHomeScreenApps` (a group's name, logo,
> domain, organization details, minimum security tier and home-screen defaults:
> platform admins, developers, or a member holding `<groupId>:groups:edit`),
> `inviteMember`, `checkInviteUsernames`, `setInvitationRole`, `revokeInvitation`,
> `resendInvitation`, `acceptInvitation`, and the pre-sign-in, rate-limited
> `getInvitationClaim`, `claimInvitation` and `lookupInvitation`),
> `setGroupInstalledApps` (`functions/access_control.js`) and `adminDeleteGroup`
> (`functions/groups.js`). The guest flow (`functions/guest_users.js`) writes its
> own guest memberships.

> **Invitation claim links:** an invitee never reads their invitation. They join
> through a single-use, 7-day link (`https://bluejay.gg/claim?token=...`) that
> `onInvitationCreated` (`functions/users.js`) and `resendInvitation` send to the
> contact the inviter entered (`functions/_invitation_links.js`). Only the token's
> sha256 is stored, as the doc id in `invitation_claim_tokens` (kind `server`, with
> `invitationId`, `groupId`, expiry, use and revocation fields). `claimInvitation`
> redeems the link in a transaction, creates the account with the Admin SDK, and
> writes `users/{uid}.contactVerification` (a `users` `serverField`, so no client can
> forge it) as proof the invitee controls that contact. `acceptInvitation` only
> finishes joining for invitations whose `claimedBy` is the caller; no callable
> accepts an invitation by email address alone. Rate-limit counters for these
> callables live in `invitation_lookup_rate_limits` (kind `server`).

> **Other members' profiles (rules plan T9):** `users/{uid}` is kind `personal`: only its
> owner (and platform admins and developers) reads it. What one member may see about
> another lives in the group member directory, `group_members/{groupId}__{uid}`, written
> only by the `groupMembersOnMembershipWritten`/`groupMembersOnUserWritten` triggers
> (`functions/group_members.js`) and read through `GroupMemberDirectory`
> (`shared_services/group_member_directory.dart`). The `users-collection` gateway rule in
> `scripts/check_gateways.js` fails CI on a new client read of another user's doc.

> **Cross-app read fan-out (Bordereau Report):** the `groupId:appId:collection:<name>`
> scope isn't exclusive to guests — `computeEntitlements` also grants it to
> **non-guest** members of a group with the `bordereau-report` app installed,
> fanning their blanket `groupId:bordereau-report` entitlement out into
> `groupId:commercial-property:collection:insurance_applications`,
> `groupId:rented-dwelling:collection:insurance_applications`, and
> `groupId:course-of-construction:collection:insurance_applications`. This
> exists because Bordereau Report (`packages/bordereau_report`) reports on
> `insurance_applications` docs *written by* those three other apps, and the
> rules scope access to `{groupId}:{writingAppId}` (the collection is multi-app, so
> the doc's `appId` picks the scope) — a bare
> `bordereau-report` entitlement alone grants nothing on data written by a
> different app. The fan-out is read-only by construction (same mechanism as
> guest collection-scoping) and never implies `:edit`/`:admin` on the source
> apps. Reads of the `transactions` subcollection under each policy follow the
> parent doc through the generic subcollection rule. The ledger itself is
> server-written (`subcollections.transactions.serverWritten`): clients record
> rows only through the `insuranceRecordTransaction` callable.

> **App Access user segments:** a group admin can define named "segments" of
> users (`app_access_segments/{id}`, managed via the `appAccess*Segment*`
> callables in `functions/app_access_segments.js`, never written directly by
> clients) and, for any subset of that group's installed apps, gate them to
> only members of a granting segment. An app that no segment mentions stays
> open to every non-guest member, exactly as before this mechanism existed —
> segments are opt-in per app, not a default-deny system. This is enforced
> entirely inside `computeEntitlements` (`functions/_shared.js`): if an app is
> "governed" (named in at least one segment's `includedAppIds` for that
> group), a member only receives the base/`:edit`/`:admin` entitlements for it
> if they're a real group admin (`groups/{groupId}.adminIds` — **not**
> `membership.role`, which is a separately-maintained field that can diverge;
> see `groups_service.dart`'s `addAdmin`/`removeAdmin`) or belong to a segment
> whose `includedAppIds` contains that app. Guests are unaffected — segment
> governance only applies to the non-guest entitlement branch. App Access
> itself (`app-access`/`app_access`) can never be added to a segment's
> `includedAppIds`, closing off a narrow self-lockout path for an App Access
> admin who only holds the `:admin` entitlement rather than real `adminIds`.

> **Apps withheld by group settings:** `functions/_app_withholds.js` lists
> apps a group's own settings take away from some members even when the app
> is installed and ungoverned. Each rule names the app, the per-group
> settings doc that decides it (`{settingsCollection}/{groupDocId}`) and a
> pure predicate. `buildUserAccessIndex` reads those docs for the user's
> groups that install the app and passes the withheld `(group, app)` pairs to
> `computeEntitlements`, which grants that member no tier of the app. A
> trigger per settings collection (`onWarehouseSettingsWritten`) rebuilds the
> group's non-guest members when the decision can change; the nightly
> invariants flag an index that still holds a withheld app. Guests are not
> affected. The one rule today: a member scoped to their organization in
> Data Warehouse (`warehouse_settings.scopedMemberRoles`/`scopedMemberIds`,
> `functions/_warehouse_reader_scope.js`) gets no `warehouse-imports`, whose
> collections hold every organization's uploads, scorecards and coverage.

### The Standard Document Payload
Every tenant document **must** carry these fields to be authorized (`ScopedCollection` stamps them on create, §5):
```json
{
  "appId": "insurance-app",
  "groupId": "broker-alpha",
  "creatorId": "user_123",
  "ownerIds": ["user_123", "user_456"] // Individuals who may edit at the base tier
}
```
`groupId`, `appId` and `creatorId` never change after create. A doc without a `groupId`
is denied. There is no `visibility` field (D2: cross-group content is published, §2 Case 3)
and no per-doc `__admin_only` / `__required_clearance` flag (the table's
`adminOnlyCollection` / `requiredClearance` replace them).

---

## 2. Realistic Use Cases & Implementation

### Case 1: The Standard Employee
Needs to create and edit their own files within their group.
* **Payload:** `groupId: "my-corp"`, `creatorId` = the caller (stamped by `ScopedCollection`).
* **Requirement:** Index must contain `"my-corp:app-id"`.

### Case 2: The Guest
A guest (anonymous-auth `role: "guest"` membership) browses a shop's product
catalog and adds items to their own cart. They have no blanket app entitlement.
* **Read access:** The `apps/shop-app` config must have `isEmbeddable: true`, admit the
  guest, and list `"products"` in `externalCollections`, and the table must declare
  `products` `guestShareable`. The guest's access index then contains
  `broker-alpha:shop-app:collection:products`, which grants read-only
  access to that one collection — not the rest of the app's data.
* **Write access:** The guest can create/edit their own `cart_items` doc
  (`groupId: "broker-alpha"`, `creatorId: "guest_uid"`) when the table declares
  `cart_items` `guestWritable`; it doesn't need to appear in `externalCollections`. The
  `broker-alpha:shop-app:guest` entitlement plus ownership (`creatorId` == caller)
  covers the app's `guestWritable` collections, for docs they created themselves, as
  long as `groupId` is one of their own groups. Everything else in the app stays
  staff-only for the guest.

### Case 3: Cross-Group Content (The Public Catalog)
Group A needs every other group to **view** some of its docs (a marketplace listing), but not edit them.
* **Action:** Declare `publishTo: "public_<collection>"` on the source collection and a
  `public_<collection>` entry (`kind: "public"`, with its `projection`) in the table. The
  doc's owners call `PublicCollection.publish()` (the `publicPublish` callable,
  `functions/public_namespace.js`), which writes a projection of the allowed fields.
* **Requirement:** Any signed-in user reads `public_<collection>`; nobody writes it from the
  client. Edits to the source re-sync the projection, and `publicUnpublish` (or the source
  no longer matching `publishWhen`) removes it. Tenant docs themselves stay readable only
  inside their group (D2).

### Case 4: The Group Manager (Editor)
Needs to edit documents created by their team.
* **Requirement:** Index must contain `"group-id:app-id:edit"`. This allows updating any document where the `groupId` matches, even if they aren't the creator.

### Case 5: The "App Admin"
Needs to edit sensitive app settings documents that standard employees shouldn't touch.
* **Action:** Keep the settings in their own collection and declare it `adminOnlyCollection: true` in `security/collections.json`.
* **Requirement:** Index must contain `"group-id:app-id:admin"`. Only the `:admin` tier reads or writes the collection.

### Case 6: Soft Delete (Moderator vs Owner)
A user wants to delete their document.
* **Action:** Send an update setting `{"isDeleted": true, "updatedAt": "timestamp"}`.
* **Requirement:** A soft delete is an ordinary update. The doc's owner (`creatorId`/`ownerIds`) may make it with the base entitlement; a moderator needs `"group-id:app-id:edit"`. A collection with `writeTier: "edit"` requires `:edit` even for the owner.

### Case 7: App Access User Segments (Department-Gated Apps)
A group admin wants only their "Claims" team to see the `claims_intake` app,
while every other installed app stays open to the whole group.
* **Action:** Create a segment named "Claims" via `appAccessCreateSegment`
  with `memberUserIds` set to the Claims team and `includedAppIds: ["claims_intake"]`.
* **Effect:** The next access-index rebuild for every member of the group
  (triggered by `onAppAccessSegmentWritten`) withholds `group_id:claims_intake`
  from anyone not on the Claims team and not a group admin. Every other
  installed app is unaffected — it's still named in zero segments, so it
  stays open. See the "App Access user segments" note in §1 above for the
  full mechanism.

---

## 3. Data Integrity & Field-Level Security

We use a "Trust but Verify" model for data fields. Every field lock is a key on the
collection's entry in `security/collections.json`; the generated rules enforce it.

### Server Fields
Fields no client may set, on create or update (platform admins included), are the entry's
`serverFields` (e.g. `apps`' permission fields, `users.roles`). Only the
Admin SDK writes them, through a validating callable.
* **The `__` prefix is not special to the rules.** The `updateInternalStatus` callable
  (`functions/access_control.js`, platform admin or clearance 5) still writes `__`-prefixed
  fields and audits them in `system_audit_logs`, but nothing stops a client from writing a
  `__` field. Declare a field in `serverFields` when it must be server-only.

### Immutable and Locked Fields
* **`immutable`:** set on create, never changed by an update (`usage_daily`'s `uid`, `date`).
* **`creatorOnly` / `ownerOnly` / `adminOnly`:** only the creator, an owner, or a platform
  admin may change the field (`trivia_games`' lifecycle fields, `calendar_events`' watermark).
* **`staffOnly`** (with `staffApps`), **`protectedRoleField`**, **`immutableDoc`**,
  **`singleOwner`**, **`restrictEditToCreator`** and **`blockCreate`/`blockUpdate`/`blockDelete`**
  cover the rest. `security/collections.schema.json` documents every key.

### Server-Written Collections

> **Per-group app settings written only by a validating callable** —
> `commercial_property_config`, `rented_dwelling_config`, `insurance_coc_config` (doc id =
> groupId) — are `serverWritten` (no client create, update or delete) but still kind
> `tenant`: their callables check the caller is a group admin and validate every field,
> and group members read them through the tenant rule (they drive the application forms). Without
> the block, `:edit` (granted to every member while `sharedEditing` is on) or the owner branch
> would let a client rewrite rating variables or geography rules directly, skipping validation.

> **`app_group_settings`** (`{groupId}__{appId}`) holds per-group app settings declared in
> `functions/app_group_settings.json` (see `CHANGE_REQUEST_SCOPE.md`). It's
> `serverWritten`: only `appGroupSettingsUpdate` writes it (after checking the caller's
> `groupId:appId:admin` tier and validating each value), and members read it through the
> tenant rule like any `groupId`/`appId` doc. Apps
> with their own per-group config collection keep their settings in that doc's `settings` map
> instead, under that collection's own policy.

For multi-party records that every party must be able to trust (conversation messages,
quotes both sides confirmed), declare the collection `serverWritten: true`. The generic rule
then grants no client write at all, so only Cloud Functions (Admin SDK) write it, while reads
keep the tenant rule's semantics (the app's entitlement in the doc's group), plus any reader
the doc names in the entry's `readerField` (one uid) or `readerListField` (a list of uids)
from any group.
* **Differs from `kind: "server"`:** a `server` collection has no tenant read at all: only
  the `readerField`/`readerListField` users and platform admins read it.
* **Subcollections** use the parent's policy; declare
  `subcollections.<name>.serverWritten: true` for a server-only subcollection.
* **Example:** `vendor_market_threads`/`vendor_market_messages`/`vendor_market_quotes`
  (`serverWritten`, `readerListField: "ownerIds"`, so the organizer and the vendor read them
  from their own groups through `ScopedCollection.queryAsReader()`), written only by
  `functions/vendor_market.js`.

---

### Audit Trail

A collection whose table entry sets `auditTrail: true` has every create, update and delete
recorded in `audit_events` by a server trigger (`functions/audit_trail.js`, one per audited
collection, listed in the generated `functions/_audit_collections.json`). Each event holds
the actor, the time, the doc, and the before and after values of each changed field.
`audit_events` is server-written and `adminOnlyCollection`: the audited app's `:admin` tier in
the event's group (group admins included) and platform admins read it, and nobody edits or
deletes it.

The actor comes from the write. Every client write to an audited collection must stamp
`lastModifiedAt` with the request time and leave `lastModifiedBy` naming the caller; the rules
(`auditStampOk`) refuse any other client write. `ScopedCollection` adds both on every write
(`add`, `create`, `set`, `update`, `batchSet`, `batchUpdate`, `transactionSet`,
`updateForKey`), so write through it; a raw `DocumentReference` write needs
`...collection.auditStamp()` in its data. Admin SDK writes don't stamp and are recorded as
unattributed server changes.

Fields listed in an entry's `auditRedact` are recorded as changed, with `{redacted: true}` in
place of their values; a dotted path (`details.secureUrl`) hides one key inside a map field.
Use it for any secret an audited doc holds (link tokens, token hashes), because everyone who
reads the trail would otherwise see it.

People see a record's history through the `recordHistory` callable
(`functions/record_history.js`), never a client read of `audit_events`. It checks each event
with `canReviewRecord` (`functions/_record_review.js`), the same check `commentsModerate`
uses: platform admins, the event's `{group}:{app}:admin` holders, and for `stewardRead`
collections the steward groups' admins. The History item (`recordHistoryActions` in
`shared_ui/lib/record_history.dart`) shows on a detail screen's overflow menu for those
people, and Security Audit's Records tab looks up any document path for platform admins.

## 4. Hierarchy of Permissions

1.  **Platform Admin:** Reads every collection in every group (EX-ADMIN-1, while their
    account is `ACTIVE`). Writes from the client only collections declared `adminWritable`
    (and comments where `adminComments`); every other admin write goes through a callable.
    (`roles: ["admin"]`)
2.  **Platform Developer:** Reads the collections declared `developerRead` (`users`,
    `groups`, `collection_catalog`, `collection_policies`, `domain_verifications`) and
    writes those declared `developerWritable` (`apps` and `app_categories` outside their
    `serverFields`, `platform_config`, `domain_verifications`). Like admins, they read any
    group's doc in collections declared `adminComments` (`bug_reports`, `feature_requests`,
    `app_requests`) and comment on it, to work tickets from Dev Pipeline.
    (`roles: ["developer"]`)
    **Platform Support:** Answers the Bluejay desk in Help Desk (staff groups' tickets and
    every escalation to Bluejay). It grants nothing in the rules: Help Desk's collections
    are kind `server`, and its callables (`functions/_help_desk.js`) check the role. A
    person may hold it together with `developer`. (`roles: ["support"]`)
    *(Removed: the read-everything `auditor` role was never held by anyone
    and was deleted in plans/firestore-rules D4a. A stale `auditor` claim
    grants nothing and is dropped from the access index on rebuild.)*
3.  **App Admin:** Everything the editor can do, plus collections declared
    `adminOnlyCollection`, and other members' docs in `ownerScoped` collections. (`:admin` entitlement)
4.  **App Editor:** Can edit and delete others' docs in their group. (`:edit` entitlement)
5.  **App User:** Can read and create in their group, and edit/delete their own docs.
    (Base entitlement.) Ownership (`creatorId` or `ownerIds`) only narrows an entitlement
    the caller already holds (D1): it never grants access by itself, and a removed member
    loses access to the docs they created.
6.  **Guest:** Reads the app's `externalCollections` that are `guestShareable`, and
    writes their own docs in its `guestWritable` collections, for embeddable apps that
    admit them only.
    (`groupId:appId:guest` and `groupId:appId:collection:<name>` entitlements — see §1 above)

---

## 5. Writing Firestore Queries in Micro-App Packages

### Use `ScopedCollection` — never call `FirebaseFirestore.instance.collection()` directly

All reads and writes of tenant data in a micro-app package **must** go through a `ScopedCollection` instance (`scripts/check_gateways.js`' `raw-collection` and `firestore-instance` rules fail CI otherwise; only the pass-through kinds `server`, `personal`, `platform`, `platform_admin` and `public` may use a raw `.collection()`). This wrapper automatically:

- Filters every read query with `.where('groupId', isEqualTo: activeGroupId)` (and, for a collection several apps own, `appId`) so the rules can prove it.
- Returns a no-match sentinel query when no group is active, preventing accidental cross-group data leakage.
- Injects the required permission fields (`groupId`, `appId`, `creatorId`, `ownerIds`) on every `.add()` and `.set()` that creates a document, and never rewrites them on update.

### Setup (once per package)

**1. Add `shared_services` to `pubspec.yaml`:**
```yaml
dependencies:
  shared_services:
    path: ../shared_services
```

**2. Create `lib/constants.dart` with the package's registered `appId`:**
```dart
// ignore: constant_identifier_names
const APP_ID = 'my-app';   // must match the document ID in apps/{appId}
```

**3. Declare the collection in `security/collections.json`** (`"my_collection": { "apps": ["my-app"] }`, then `node security/generate.js`; see §7).

**4. Declare a `ScopedCollection` at file or class level:**
```dart
import 'package:shared_services/scoped_collection.dart';
import 'constants.dart';

final _myCollection = ScopedCollection(
  collection: 'my_collection',
  appId: APP_ID,
);
```

### Reading data

Always read through `.query` — the `groupId` filter is already applied:

```dart
// Stream of all non-deleted documents in the active group:
_myCollection.query
    .where('isDeleted', isEqualTo: false)
    .orderBy('createdAt', descending: true)
    .snapshots();

// Single document fetch with a known ID — use .doc():
final snap = await _myCollection.doc(docId).get();
```

> **Do not** use `_myCollection.doc().get()` for list queries. Use `.query` so the `groupId`
> filter is applied; the rules reject a list query they can't prove is inside one of your groups.

For a collection declared `ownerScoped` (private to its owners: `notes`, `people`,
`gift_ideas`, `polls`, `whiteboards`, the Workout Tracker, Flashcards, Habit Tracker,
AI Chat, Language Learner and Chat collections), a member may read only docs whose
`creatorId` is them or whose `ownerIds` contains them, so every list must say so. Use
`queryOwned()`, which is `.query` plus `ownerIds array-contains <signed-in uid>`, or chain
`.where('creatorId', isEqualTo: uid)`. A filter on any other field (`userId`, `ownerId`,
`sharedWithIds`, `memberIds`) can't be proven and fails the whole query. Sharing such a doc
means adding the sharee to `ownerIds`:

```dart
// Own notes and notes shared with the caller (sharing adds them to ownerIds):
_notes.queryOwned().snapshots();
```

### Reading another group's documents

Tenant docs are readable only inside their own group. There is no "query another group"
helper any more (`queryForGroup` was removed with D2). The cross-group reads that exist:

```dart
// Docs that name the caller in the table's readerField/readerListField
// (a notification's recipient, a marketplace thread's participants), from any group:
_threads.queryAsReader(uid);

// Change requests about an app the caller's group stewards (EX-STEWARD-1):
_bugs.queryForRelatedApp(relatedAppId);

// Content another group published (D2), any signed-in user:
final _catalog = PublicCollection(source: 'vendor_market_listings', appId: APP_ID);
_catalog.whereSourceGroup(operatorGroupId).snapshots();
```

Writes still always target the active group through `.add()`/`.set()`; cross-group writes go
through a Cloud Function.

### Creating documents

Use `.add()` — the permission fields are injected automatically:

```dart
await _myCollection.add({
  'title': 'Hello',
  'content': 'World',
  // groupId, appId, creatorId, ownerIds → injected by ScopedCollection
});
```

To specify additional owners, include `ownerIds` in the data map (it will not be overridden):

```dart
await _myCollection.add({
  'title': 'Shared doc',
  'ownerIds': [currentUser.uid, collaboratorUid],
});
```

A natural-key id (a uid, a slug) goes through `docForKey(key)` and the `*ForKey` helpers,
which store it as `{groupId}__{key}` so two groups never share a doc; a subcollection goes
through `.sub(parentId, name)`.

### Updating and deleting documents

Update through the collection: `update(docRef, data)`, or `batchUpdate(batch, docRef, data)`
inside a batch. The security rules evaluate the *existing* document's `groupId`/`appId`, so
no identity fields are sent; on an audited collection the shim adds the audit stamp (see
[Audit Trail](#audit-trail)):

```dart
// Soft delete (an ordinary update: the owner, or the :edit tier):
await _myCollection.update(_myCollection.doc(docId), {
  'isDeleted': true,
  'updatedAt': FieldValue.serverTimestamp(),
});

// Field update (your own doc, or the :edit entitlement for anyone's):
await _myCollection.update(_myCollection.doc(docId), {'title': 'Updated title'});
```

### Full example

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_services/scoped_collection.dart';

import 'constants.dart';

final _notes = ScopedCollection(collection: 'notes', appId: APP_ID);

// Reads
Stream<QuerySnapshot> activeNotes() =>
    _notes.query.where('isDeleted', isEqualTo: false).snapshots();

// Creates
Future<void> createNote(String title, String content) =>
    _notes.add({'title': title, 'content': content});

// Updates
Future<void> updateTitle(String id, String title) =>
    _notes.doc(id).update({'title': title, 'updatedAt': FieldValue.serverTimestamp()});
```

---

## 6. Admin-Tier Apps: Cross-Group Firestore Access

Some platform-admin views intentionally query documents across **all groups** in a
collection. This is an approved exception to the active-group scoping and applies only
to code that:

1. Enforces the `admin` role (`UserAppEntitlements.isActivePlatformAdmin`) before rendering any data.
2. Reads through `ScopedCollection.queryAcrossAllGroups()`.
3. Writes through callables, or through each document's own reference for collections
   declared `adminWritable`/`adminComments`; documents created for a specific group still
   carry the full permission payload (`groupId`, `appId`, `creatorId`, `ownerIds`).

### Approved exceptions

The former entry, `improve_bluejay_admin`, was retired: its cross-group ticket moderation
moved to Dev Pipeline, which reads every group's tickets through the server-side
`devPipelineOverview` callable and writes through callables (`improveBluejaySetItemStatus`,
`improveBluejaySetItemPoints`) instead of direct client queries. Prefer that callable pattern
for new cross-group admin views; use the client-side scope below only where an existing
user-facing list needs an admin-only cross-group mode.

| Package | Collections accessed directly | Rationale |
|---|---|---|
| `bug_reports`, `feature_voting` (Improve Apps' "All groups" list scope) | `bug_reports`, `feature_requests` (read-only, via `ScopedCollection.queryAcrossAllGroups()`) | Lets a platform admin triage every group's bugs and ideas from inside Improve Apps. The scope is offered only when `UserAppEntitlements.isActivePlatformAdmin` holds (see `shared_services/change_request_list_scope.dart`); admins comment on any group's ticket (`adminComments`), status changes go through `improveBluejaySetItemStatus`, and new tickets still file to the active group via `ScopedCollection.add`. Not an `-admin` app, but the same three conditions hold for the scope itself. |

Only the rules' EX-ADMIN-1 read grant (an `ACTIVE` platform `admin`) can prove a
`queryAcrossAllGroups()` read — a `developer` cannot, and anyone else's query is rejected
outright.

### Implementation pattern

```dart
// admin-only cross-group read: gate on isActivePlatformAdmin first
final _bugsQuery = ScopedCollection(collection: 'bug_reports', appId: APP_ID)
    .queryAcrossAllGroups();
```

The security rules let any `ACTIVE` user with `roles: ["admin"]` read every group's
documents, so cross-group reads are safe as long as the UI performs the admin role
check first. Admin *writes* are limited to `adminWritable` collections; anything else
needs a callable.

---

## 7. The Rules: One Table, Kinds, and How Collections Get Coverage

`firestore.rules` is generated, not hand-written per collection. Every
per-collection decision comes from `security/collections.json`, through
`node security/generate.js` (which also writes the client shim's
`packages/shared_services/lib/generated/collection_policies.g.dart`, the
publish callables' config `functions/_public_collections.json`, and
`storage.rules`' generated section from `security/storage_paths.json`).
There is no rollout switch any more: the rules in the repo are the rules
production runs (plans/firestore-rules/IMPLEMENTATION_PLAN.md §8.3, stage 7).

### The model

- **Isolation on every path.** Every tenant read and write first requires
  `inTenant()`: the caller's access index lists the doc's `groupId`, the
  account is `ACTIVE`, and the group isn't in `denied_scopes`. A doc without
  a `groupId` is denied.
- **Detail only narrows.** After `inTenant()`, the entitlement for
  `<groupId>:<app>` (the collection's `apps`, or the doc's `appId`) and its
  tier (`:edit`, `:admin`, `:guest`, `:collection:<name>`) decide. Ownership
  (`creatorId`, `ownerIds`) is never a grant on its own; it only lets a base
  member or guest act on their own docs (D1).
- **Identity is immutable.** `groupId`, `appId` and `creatorId` never change
  on update; new tenant docs need a random, tenant-tagged (`<groupId>__…`) or
  `idPattern` id.
- **No `visibility` exception.** Cross-group content lives in the public
  namespace (`public_<collection>`, `published/` in Storage), written only by
  the `publicPublish`/`publicUnpublish` callables (D2).
- **Nothing deeper than one subcollection** is reachable, and only the
  declared collection groups can be queried.
- **The parent a subcollection write sees** (`parentForWrite()`) is the parent
  as it was before the request. When the same batch or transaction creates the
  parent, it is the parent as the request leaves it, so a doc and its first
  subcollection docs can be created atomically (Presentations' deck and
  `versions/1`). An existing parent is never read from the request's own
  writes.
- **Self-keyed subcollections.** A tenant subcollection write normally needs
  edit access to the parent doc. A subcollection declared
  `subcollections.<name>.selfKeyed` (`{fields, selfCreate, selfDelete,
  editorsWrite?}`) is for per-member records under a shared doc: any reader of
  the parent writes the doc whose id is their own uid, limited to `fields`,
  while the parent has no `deletedAt`. Nobody else writes in it, the parent's
  creator and editors included, so a vote or ballot (Polls' `votes/{uid}`) is
  only ever its owner's. `editorsWrite: true` also gives editors of the parent
  every doc in it: Calendar's host invites and removes `attendees/{uid}`, and
  Continuing Education's managers keep that access to `registrations/{uid}`.
  Reads follow the parent unless the entry also declares `selfRead: true`
  (generated into `selfReadSubcollections()`, enforced by `selfKeyedRead()`):
  then a doc is readable only by the uid it is keyed by (as a reader of the
  parent) and platform admins; the parent app's `:admin` tier reads none of
  it, so an anonymous poll's ballots stay private within the group. A list
  query never pins the doc id, so below platform admin listing the
  subcollection is refused; clients get their own doc by id (`ScopedCollection` asserts this
  in debug builds), and whatever aggregate other readers see is written onto
  the parent by the server as `serverFields`. Polls' `votes/{uid}` ballots
  use it: `pollsOnVoteWritten` recounts `voteCounts`/`voterCount`/`voterIds`
  on the poll (`functions/_poll_tally.js`, over `_vote_tally.js`'s shared
  `recountSelfKeyedTally`), and `voterIds` stays empty on an anonymous poll,
  whose `isAnonymous` is `immutable`. The same shape without `selfRead` (any
  reader of the parent sees every doc) remains on Improve Apps' `votes/{uid}`
  (their tallies already name voters), Calendar's `attendees/{uid}` and
  Continuing Education's `registrations/{uid}`.
- **Governed subcollections.** A subcollection entry may also declare
  `auditTrail`, `blockDelete`, `authorField` + `authorMayUpdate`, and
  `softDelete` (generated into `subcollectionPolicy()`, enforced by
  `governedSubWrite()`). Then editing the parent grants nothing over a doc
  that has an owner: a `selfKeyed` doc is its uid's alone, and with
  `authorField` any reader of the parent (the tenant grant, EX-STEWARD-1,
  EX-ADMIN-1's `adminComments`) creates a doc naming themselves while only
  that author changes it, and only the `authorMayUpdate` fields. `auditTrail`
  puts the docs on the audit trail (`audit_events` records them under
  `<collection>/<subcollection>` with `parentDocId`; client writes stamp
  `lastModifiedBy`/`lastModifiedAt`, which `ScopedCollection.sub` does for an
  audited subcollection). Every new governed doc must carry its parent's
  `groupId`/`appId`, and the audit trigger takes the tenant from the parent
  in any case, so a reader can't file events into another group's trail.
  Nothing is written under a soft-deleted parent. `softDelete` means
  `deletedAt`/`deletedBy` are unset on create, set together to the request
  time and the caller (with `softDeleteClears`, that field emptied), and a
  deleted doc takes no further client write. `authorEmailField` pins a
  displayed author email to the caller's token email at create;
  `boundedList` keeps a list field a list of at most `max` items.
  `selfArrayFields` (uid lists, such as a message's `readBy`) and
  `selfMapFields` (maps keyed by uid, such as `reactionsByUser`) are the
  fields other readers mark on an author's doc: any reader of the parent may
  update a doc touching only those fields (plus the audit stamp where the
  subcollection is audited). In a list they only append their own uid to a
  list without duplicates or remove its one copy, every other item kept in
  place; in a map they only change the entry under their own uid, which must
  be removed, null or a string of at most 64 characters
  (`selfFieldsUpdateOk()`). A new doc's list holds at most its author's uid
  once, and its map at most the author's entry. At most two of each per
  subcollection, since the rules check them by position. `createdAtField`
  pins a creation-time field to `request.time` on create (the client writes
  a server timestamp) and keeps it out of every update. Chat's `messages`
  use all three.
- **Comment threads.** `commentThread: true` on a collection gives it the
  shared comment thread (`packages/shared_ui/lib/comment_thread_widget.dart`),
  defined once in `security/generate.js` (`COMMENT_THREAD`): `comments`
  (author-owned, `authorId` pinned to the caller on create and immutable, the
  author edits `text` and soft-deletes; no hard delete; audited) and
  `comment_likes/{uid}` (self-keyed, `commentIds` the reader likes; no delete;
  audited). Declared on `app_requests`, `bug_reports` and `feature_requests`.
  Moderators remove someone else's comment through the `commentsModerate`
  callable (`functions/comments_moderation.js`): the same soft delete with
  `deletedBy` the moderator, plus a `moderationReason` no client may set. It
  allows ACTIVE platform admins, the thread app's `:admin` tier in the
  ticket's group and, on `stewardRead` collections, admins of the steward
  groups of the ticket's `relatedAppId`; the thread collections come from the
  generated `functions/_audit_collections.json` (`commentThreads`).
  Any reader of the ticket likes a comment through their own likes doc, so
  likes don't depend on edit rights to the comment or the ticket, and an app
  can set `sharedEditing: false` without breaking them. Other apps' undeclared
  `comments` subcollections (Cookbook, Town Square) keep the generic rule:
  parent editors write them, and any reader creates one with `authorId` equal
  to the caller.

### Kinds

| Kind | Who reads | Who writes | Examples |
|---|---|---|---|
| `tenant` (default) | `inTenant` + entitlement detail | Same, plus the table's field locks; `serverWritten: true` = no client writes | Every app's own data |
| `server` | The doc's `readerField` user, platform admins | Admin SDK only (plus `readerMayUpdate` / `readerMayDelete`) | Payments, rate limits, ledgers, `notifications` |
| `personal` | The user whose uid is the doc id (and its subcollections, e.g. `users/{uid}/prefs`) | That user, never `serverFields` | `users`, `calendar_user_settings` |
| `platform` | Any signed-in user | `adminWritable` / `developerWritable` roles | `apps`, `app_categories`, `platform_config` |
| `platform_admin` | Platform admins (and `developerRead`) | `adminWritable` only | `script_runs`, `collection_catalog` |
| `public` | Any signed-in user | Nobody (the publish callables) | `public_vendor_market_listings` |

The few grants that skip the tenant check are reviewed exceptions in the
table's `exceptions` section (EX-ADMIN-1, EX-DEV-1, EX-STEWARD-1; Storage's
EX-PROFILE-PIC-1 is in `security/storage_paths.json`);
`security/check_rules_exceptions.js` fails CI on any other match block or
grant.

### How a new app's collections get coverage

A collection with no table entry is already kind `tenant`, scoped by its
docs' `appId`: isolated by group, readable and writable only with the app's
entitlement. Declare it anyway, with the owning app:

```jsonc
// security/collections.json
"my_app_items": { "apps": ["my-app"] }
```

The `apps` entry scopes list queries by `groupId` alone, refuses docs tagged
with another app, and gives the shim its table. CI requires it: a
`ScopedCollection(collection: 'x', …)` naming an undeclared collection fails
`scripts/check_gateways.js` (`undeclared-collection`).

### How to add or change a collection

1. Add or edit the entry in `security/collections.json` (the schema,
   `security/collections.schema.json`, documents every key: `kind`, `apps`,
   `serverWritten`, `readerField`, field locks such as `immutable`,
   `adminOnly`, `staffOnly`, `subcollections`, `idPattern`, …).
2. Run `node security/generate.js` and commit the regenerated
   `firestore.rules`, `storage.rules`, `collection_policies.g.dart` and
   `functions/_public_collections.json` (`--check` is the CI test).
3. If Cloud Functions write it and clients don't, declare it `kind: "server"`
   (or `serverWritten: true`); `security/check_server_collections.js` checks.
4. Run the emulator suite (`security/rules-tests`, `npm test`); the generated
   matrix covers the new entry automatically. `.claude/skills/change-firestore-permissions`
   is the full checklist.

Rules reach production only through `.github/workflows/deploy-rules.yml`
(emulator suite, Rules API compile, deploy, prod smoke test). Since
2026-11-06 a merge that touches the rules or `security/**` runs it
automatically (`RULES_AUTO_DEPLOY=true`, `RULES_AUTO_DEPLOY_SERVICES=both`);
it can also be run by hand (Actions -> "Deploy rules"). After a
deploy, `node security/tools/denials.js --since <deploy time>` lists the
permission-denied reports clients sent (`rulesDenialReport`).
The emergency rollback to the permissive 2025-12-16 release is documented
in `security/RULES_ROLLBACK.md` (the release is kept verbatim in
`security/rules-tests/fixtures/`).
