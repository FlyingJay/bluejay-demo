---
name: create-bluejay-app
description: Scaffold a brand-new Bluejay launcher app package from scratch — data model, ScopedCollection-backed service layer, screens, routing, and its security/collections.json entries (never a firestore.rules match block) — following the conventions and hard-won lessons from every app already in the launcher. Use when the user says things like "add a new app called X to the launcher", "create a new bluejay app for Y", or "scaffold a new package for Z". For net-new apps only, not incremental features on an existing one (see implement-feature-improvement for that). Registration is declarative: the package's bluejay_app.json manifest makes the deploy create the apps/{appId} doc and install the app into the groups it lists, so nobody registers it by hand.
---

# Create a New Bluejay App

Scaffolds a net-new app package for the Bluejay launcher end to end: data model, service layer, screens, routing, tests, and its `security/collections.json` entries. The single most important habit this skill encodes: **no new app needs a `firestore.rules` change at all**; its collections get coverage from one table entry each. The platform's generic permission model already covers the overwhelming majority of access patterns for free; reaching for a bespoke rule should be the exception you can justify, not the default you reach for. This skill exists because that lesson (and several adjacent ones — a real self-triggering Cloud Function loop, a `copyWith` bug that silently dropped a field, a form-level date constraint that blocked a whole category of events) came from actually shipping a full five-phase app (`packages/calendar/`) and having to work each of them out the hard way. Read `packages/calendar/` alongside this skill as the single richest reference implementation in the codebase — it deliberately exercises almost every pattern below.

## Inputs

Gather from the user, asking if not given rather than guessing:
- **App name and purpose** — what it does, roughly what data it stores.
- **appId slug** — kebab-case, e.g. `unit-converter`, `daily-cost`. Derive one from the name if not given, but confirm it before scaffolding — this string is load-bearing (Firestore `appId` field, `ScopedCollection`'s `appId`, the Dart `APP_ID` constant, and the `app_router.dart` route key must all match it exactly).
- **Data-access shape** — is this fully shared within a group (everyone with the app installed can read/write everything — the default and by far the most common), owner-restricted (anyone can read, only the creator/owners can edit), or something narrower? This decision drives step 3 below and is worth nailing down explicitly before writing any code.
- **Does it need file storage, a Cloud Function, or external/guest submissions** (non-members dropping data in, like an insurance quote form)? Each has an established pattern below; don't improvise a new one.

## Steps

### 1. Check for collisions

Before scaffolding anything:
```bash
grep -n "'<appId>'" lib/routing/app_router.dart
grep -n '"appId": "<appId>"' documentation/feature_doc_mapping.json
ls packages/ | grep <package-name>
```
If any of these already exist, stop and confirm with the user rather than silently overwriting or picking a different slug for them.

### 2. Decide the data-access shape — before writing a single file

This is the step most likely to go wrong, and getting it wrong either creates unreviewable rules complexity or a real access-control bug. Work through it in this order:

Every collection's rules come from one table, `security/collections.json`, through `node security/generate.js`; **no app ever adds a `match` block** (`security/check_rules_exceptions.js` fails CI on one). Production enforces these rules for every collection (rules plan stage 7, 2026-11-06). Pick the shape, then express it as a table entry:

1. **Fully group-shared (default).** Every member of a group with the app installed can read; members create and edit their own docs, and `:edit`/`:admin` holders edit any. Kind `tenant`, the default. The table entry is just the owning app: `"my_app_items": { "apps": ["my-app"] }`. Add it for **every** collection the app creates (CI's `undeclared-collection` gateway rule fails on a `ScopedCollection(collection: 'x')` the table doesn't declare). An undeclared collection would still be tenant-isolated (scoped by the doc's `appId`), but the `apps` entry is what lets a `groupId ==` query prove itself and refuses docs tagged with another app.
2. **Owner-restricted edits.** Ownership only narrows: `ownerScoped: true` (members below `:admin` see only docs they own; every list must be `queryOwned()` or filter `creatorId == uid`), `restrictEditToCreator: true`, `singleOwner: true`, `writeTier: "edit"` (only `:edit`/`:admin` may write). Populate `ownerIds` through `ScopedCollection.add()`, which injects it.
3. **Per-field locks.** `immutable`, `creatorOnly`, `ownerOnly`, `adminOnly`, `staffOnly` (+ `staffApps`), `protectedRoleField`, `immutableDoc`, `blockCreate`/`blockUpdate`/`blockDelete`. See `security/collections.schema.json` for every key and `calendar_events` / `trivia_games` for worked examples; subcollections go under `subcollections` (`serverWritten`, `selfKeyed`, `collectionGroup`).
4. **Personal, non-group-scoped data** (per-user settings). `"my_app_user_settings": { "kind": "personal" }`: the doc id is the user's uid; only that user reads and writes it (and its subcollections). Access it with a raw `.collection()` (pass-through kinds are allowed by `raw-collection`), not `ScopedCollection`.
5. **Server-only data** written by a Cloud Function: `"kind": "server"` (plus `readerField` if the user it names may read it), or `"serverWritten": true` for a tenant collection clients read but never write. `security/check_server_collections.js` checks every collection functions use is declared one way or the other.
6. **A public endpoint is needed** ("share this externally"). Cross-group content goes through the public namespace (a `public_<collection>` entry with a `projection`, published by the `publicPublish` callable), never a `visibility` field. For people with no bluejay account, gate the read in a Cloud Function `onRequest` handler that reads via the admin SDK and checks an explicit opt-in flag. Flag this new exposure to the user and confirm the sharing model before building it.

7. **Guests submit records** (an insurance quote form, an upload link). Mark the app `isEmbeddable` and give its guests exactly the collections they need: `guestWritable: true` on the collection a guest creates and keeps (their application), `guestShareable: true` on config a guest's form reads (listed in the app's `externalCollections`), and the Storage folders a guest uploads to in `guestWritableFolders` (`security/storage_paths.json`). Every other collection of the app stays staff-only for guests, and fields staff set on a guest's record need `staffOnly`/`serverFields`.
8. **Regulated or audited records** (anything a client's compliance review will ask about). Set `auditTrail: true` on every collection the app owns, so every change is recorded in `audit_events` with its author, and `blockDelete: true` on the client-writable ones (or a soft-delete flow if users genuinely delete). Records with money or staff-entered figures in them (a ledger) are `serverWritten`, recorded through a validating callable that takes the tenant and author from the server, as `insuranceRecordTransaction` does. This is what Tier 4 (`regulated`) checks; see `SECURITY_TIERS.md`.

After editing the table, run `node security/generate.js` (regenerates `firestore.rules`, the shim's `collection_policies.g.dart` and, for a publishing entry, `functions/_public_collections.json`; commit them) and the emulator suite in `security/rules-tests` (`npm test`), whose generated matrix covers the new entries automatically. Rules reach production only through `.github/workflows/deploy-rules.yml`, which the deploy train (`.github/workflows/deploy-production.yml`) runs within about 15 minutes of the merge (`RULES_AUTO_DEPLOY=true`, Firestore and Storage, since 2026-11-06). So the table change must be verified (emulator suite) before merge; say in the PR that the table changed, and watch the next "Deploy Production" run after merge.

### 3. Scaffold the package

Mirror `packages/calendar/`'s layout:

```
packages/<app>/
  pubspec.yaml
  bluejay_app.json           # app manifest: registers the app on deploy (step 9)
  lib/
    constants.dart          # APP_ID only
    <app>_models.dart        # data classes: toMap()/fromDoc(), no Firestore calls
    <app>_service.dart       # all Firestore/Storage I/O, static methods
    <app>_screen.dart        # top-level screen, registered in app_router.dart
    <app>_..._screen.dart    # detail/form/settings screens as needed
    <app>_widgets.dart       # presentational widgets: data and callbacks in, no Firestore
  test/
    <app>_service_test.dart  # pure-logic tests (see step 11)
    <app>_widgets_test.dart  # widget tests with fake data
    screenshots_test.dart    # opt-in PNG renders at 390 and 1280 px (step 11)
```

`lib/constants.dart`:
```dart
// ignore: constant_identifier_names
const APP_ID = '<appId>';   // must match the app_router.dart key, bluejay_app.json's appId and the apps/{appId} doc ID
```

`pubspec.yaml` — minimal real-world example (from `packages/calendar/pubspec.yaml`, CI-verified):
```yaml
name: <app>
description: <one line>
version: 0.0.1
publish_to: 'none'

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

  cloud_firestore: ^6.0.3
  firebase_auth: ^6.1.1
  intl: ^0.20.2

  shared_services:
    path: ../shared_services
  shared_ui:
    path: ../shared_ui
  bluejay_design:
    path: ../bluejay_design

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```
Add any third-party package (e.g. a calendar/chart/rich-text widget library) only after confirming it's free/actively maintained and — critically — after actually checking its real public API via WebFetch against its pub.dev docs rather than assuming it matches a similar-sounding package you've seen before. `calendar_view`'s builder API (`MonthViewBuilders`, not flat `onCellTap`/`onEventTap` params) and its `MonthViewState.animateToMonth` navigation method were both discovered this way, not assumed — assuming would have shipped broken code both times.

### 4. Data model (`lib/<app>_models.dart`)

- Plain Dart classes, no Firestore imports beyond `Timestamp`/`DocumentSnapshot` types.
- `toMap()` returns only user-editable fields — never include `groupId`/`appId`/`creatorId`/`ownerIds`; `ScopedCollection.add()` injects those and would only be overridden by a caller trying to spoof them (which the wrapper explicitly prevents).
- `fromDoc(DocumentSnapshot<Map<String, dynamic>> doc)` — always default-safe (`data[...] as String? ?? ''`, `Timestamp?` checks before `.toDate()`), since Firestore data can be malformed by future schema changes or partial writes.
- If a field needs "explicitly cleared" to mean something different from "not touched" in a `copyWith`, use a dedicated boolean flag param (`clearRecurrence`, `useDefaultReminders` in `calendar_models.dart`) rather than relying on `null` for both meanings — Dart's `param ?? this.param` convention can't tell them apart otherwise.
- **Double-check every field actually survives `copyWith`.** A field with no `copyWith` param that also isn't explicitly carried forward inside the method body (`fieldName: fieldName` — bare reference resolves to `this.fieldName`) silently resets to the constructor's default on every edit. This exact bug shipped once in this codebase (`CalendarEvent.isShareable`) and would have silently disabled an opt-in security-relevant flag on every ordinary edit if it hadn't been caught by re-reading the constructor call site.

### 5. Service layer (`lib/<app>_service.dart`)

- **Always** go through `ScopedCollection` (`packages/shared_services/lib/scoped_collection.dart`) for group-scoped data — never call `FirebaseFirestore.instance.collection()` directly for it. `.query` for list reads (groupId filter pre-applied), `.doc(id)` for a reference (get, delete), and the collection's own write methods for every write: `.add()`, `.create()`, `.set()`, `.update(_coll.doc(id), data)`, `.batchUpdate()`, `.transactionUpdate()`. They inject and protect the permission fields and stamp the audit fields an `auditTrail` collection requires; a raw `_coll.doc(id).update(...)` skips both and fails the `raw-doc-write` gateway check. See `FIRESTORE_PERMISSIONS.md` §5 for the full walkthrough.
- Personal/non-group data (step 2.4 above) and server-only reads: `FirebaseFirestore.instance.collection(...)` directly is correct and expected there — `ScopedCollection` would incorrectly inject a `groupId` filter these documents don't have.
- File uploads: `ScopedStorage` (`packages/shared_services/lib/scoped_storage.dart`) is the Storage-rules equivalent of `ScopedCollection` — see `STORAGE_PERMISSIONS.md`.
- Static methods on a `class <App>Service`, one `final _collection = ScopedCollection(...)` per Firestore collection at file scope.
- Multi-collection writes that must be atomic (e.g. keeping a denormalized array in sync with a subcollection) use `FirebaseFirestore.instance.batch()`, not sequential awaited writes — see `CalendarService.inviteAttendees`.
- Firestore only allows one field with a range/inequality filter per query. If you need both a range filter (e.g. a date range) and an equality-style distinction (e.g. "is this a recurring series or not"), add a derived boolean field kept in sync in `toMap()` rather than trying to filter on the richer field directly — this is why `calendar_events` has `isRecurring` as well as `recurrence`.

### 6. Screens

- `StatefulWidget` + `StreamBuilder`/manual `StreamSubscription` for anything backed by a live Firestore query; `StatelessWidget` only for genuinely static display.
- Build every screen on `bluejay_design` (`packages/bluejay_design/README.md`); new apps get no `*_theme.dart`. Use `BjPage` for each screen, `BjSnapshotView` for every stream (skeleton, error with retry, then data), `BjStateView.empty` for empty lists, `BjListRow` + `BjOverflowMenu` for rows, `showBjConfirm(destructive: true, consequences: [...])` for deletes and `BjSnack` for messages. Spacing, radii and colours come from `BjSpace`, `BjRadius`, `BjNeutral` and `context.bj`; text from `Theme.of(context).textTheme`; status colours from one map onto `BjTone`. `scripts/check_design_tokens.js` fails CI on raw `Colors.*`, `Color(0x...)` literals, `TextStyle(fontSize: ...)` and `*_theme.dart` in a new file (the baseline only covers code that predates the design system); a stored user colour or fixed brand colour takes `// design-ok: <reason>`. The `polish-app-ui` skill's design checklist applies to new screens too, and screen text (buttons, empty states, errors, confirms) follows the brand guide's product-writing rules (CLAUDE.md, "Brand and design").
- Keep the widgets that draw data in `<app>_widgets.dart`, taking models and callbacks, so tests can render them without Firebase.
- Open drill-downs (an item's detail, a folder's contents) with `Navigator.push`, so the browser's back button closes them. A sub-view held in widget state (a selected item swapped in with `setState`, a wizard step, a game's leaderboard) goes inside `BjBackStep(active: <it's open>, onBack: <close it>)`; without it, browser back leaves the app. `scripts/check_back_steps.js` fails CI on a back arrow that only changes state in a file with no `BjBackStep`.
- Check `packages/shared_ui/` before building a common widget from scratch: `UserSearchScreen(multiSelect: true)` for a member/invite picker, `IconColorPicker` for a swatch color picker (a label/category color UI is a very common need — use this rather than reinventing it), `buildClickableText`/`clickable_url.dart` for auto-linkified text, `ActiveGroupService` (from `shared_services`) for the current group context. An app always opens with an active group (the launcher opens nothing without one), so don't add a "pick a group" or "no group selected" state. Where a screen still needs a branch for a null group (the instant sign-out clears it), build `ActiveGroupPending` from `shared_services`. The group can change while the app is open, so a screen holding a group-scoped query listens to `ActiveGroupService` and rebuilds it.
- If a picker screen returns a result via `Navigator.pop`, check what type it actually pops (e.g. `UserSearchScreen` pops `List<QueryDocumentSnapshot>` for multi-select) — read the widget's source rather than assuming a convenient shape.
- Google Maps directions and "Add to Google Calendar"-style links need no API key or OAuth — both are plain URL templates resolved client-side by the target service (see `calendar_maps_link.dart`, `calendar_share_links.dart`).

### 7. Notifications

Reuse the existing pipeline — never build a parallel one:
```dart
final _notifications = NotificationService(appId: APP_ID);
await _notifications.add({
  'recipientId': uid,
  'title': '...',
  'body': '...',
  'appName': '<Human-Readable App Name>',
  'isRead': false,
  'createdAt': Timestamp.now(),
  'context': {'yourEntityId': id},
});
```
`groupId`/`appId` are injected automatically by `NotificationService`. `functions/notifications.js`'s `onNotificationCreated` trigger handles push/email/SMS fan-out per the recipient's own account-wide channel preferences — it does **not** read a per-notification "which channel" field, so don't design a feature that assumes one exists (a reminder feature in this codebase originally planned per-reminder-rule channel selection and had to be redesigned around this once the actual trigger code was checked). If you do set `actionUrl`, it must be `https://*.bluejay.gg` or a `bluejay://` deep link — anything else is silently stripped by `sanitizeActionUrl`.

### 8. Cloud Functions — only if you actually need server-side/scheduled/public work

Not every app needs one. Reach for `functions/<app>.js` only for: scheduled jobs, materializing data no client should compute, or a public unauthenticated endpoint (step 2.6).

- New file, auto-discovered by `functions/index.js` — no manual registration needed, just export the functions.
- Get every builder from the metered gateway, never from `firebase-functions` directly (CI fails on that): `const { onCall, HttpsError, onSchedule, onDocumentWritten } = require('./_metered_functions')(module);`. These are the 2nd-gen builders, the only kind there is. It attributes any billable work your functions do (emails, AI, external calls, ...) to the app derived from your filename and to the caller's verified user and group. If the filename (snake_case → kebab-case) isn't the app's id, add it to `MODULE_APP_IDS` in `functions/_metered_functions.js` (`_metered_functions.test.js` names any module that needs it). External HTTP calls go through `require('./_external_http')` (axios-compatible, plus `fetch`), not `axios`; Stripe clients come from `require('./_stripe').createStripeClient(key)`.
- `const db = admin.firestore();` at module scope; `onDocumentWritten('path/{id}', async (event) => {...})` for triggers, with the Change in `event.data` and the path params in `event.params` (works for arbitrarily nested subcollection paths too, e.g. `calendar_events/{eventId}/attendees/{uid}`); `onSchedule('every N minutes', ...)` for cron-style work.
- Never name a region. `_metered_functions` gives every function its region from `functions/_function_regions.js` (`northamerica-northeast2`, beside Firestore and Storage), and `check_gateways` fails CI on a region id anywhere else. Clients call through `BluejayFunctions` (`shared_services/cloud_functions.dart`). After adding functions, run `node scripts/function_generations.js --write` in `functions/` and commit `function_generations.json`.
- A trigger that sends or enqueues something (email, SMS, push, a task) must run once per write: Eventarc delivers at least once. Start it with `if (!await claimEvent('<functionName>', event.data)) return;` (`functions/_trigger_once.js`).
- **If a trigger writes back to the same document it's triggered by, it will re-trigger itself.** Guard with a check that the specific fields your logic cares about actually changed before doing real work again (see `reminderRelevantFieldsChanged` in `functions/calendar.js`) — this is an easy, real infinite-loop/cost bug, not a theoretical one.
- Scheduled dispatch that must not double-send: use the transactional claim pattern from `functions/announcements.js` — flip `status: 'pending' → 'dispatching'` inside `db.runTransaction`, do the work, then mark `'sent'` (or reset back to `'pending'` on failure so it retries).
- Batch writes: chunk at 400–500 per `db.batch()` (Firestore's hard limit is 500) — see the chunking helpers in `functions/calendar.js` or the precedent in `functions/groups.js`.
- **Node is available in this dev environment (unlike Flutter/Dart).** Write `functions/<app>.test.js` using the built-in `node:test`/`node:assert/strict` (no Jest/Mocha dependency), export pure/testable helpers via `exports._internal = {...}` (see `functions/calendar.js`'s bottom), then actually run:
  ```bash
  cd functions && npm install && node --test <app>.test.js
  ```
  This is real, load-bearing verification — treat a passing `node --test` run as meaningfully more trustworthy than "I read the code carefully," which is all that's possible on the Dart side in this environment.

### 9. Register the app

- **Root `pubspec.yaml`**: add the path dependency under the `# Internal` section.
- **`lib/routing/app_router.dart`**: add an import and a `'<appId>': (user) => YourScreen(currentUser: user!),` entry to the `_routes` map. The key must exactly match the `appId` slug used everywhere else.
- **`documentation/feature_doc_mapping.json`**: add one entry —
  ```json
  {
    "name": "<app>",
    "documentationSlug": "<app>",
    "documentationAudience": "app",
    "description": "One or two sentences on what the app does.",
    "keywords": ["short", "list", "of", "terms"],
    "watch": [
      { "type": "directory", "path": "packages/<app>" }
    ],
    "appId": "<appId>"
  }
  ```
  Add a `{ "type": "file", "path": "functions/<app>.js" }` entry too if you created one. If the app admits guests, add `"guestAudience": "visitors"` (an `isEmbeddable` app opened from a shared link) or `"clients"` (a client-portal app) so the nightly docs batch also writes its `guest.md`, the guide guests see from the help tab. Always include `description`/`keywords` — BlueJI (`packages/blue_ji`, `functions/blue_ji.js`) uses them to route user questions to the right app's documentation, and an app with no signal beyond its bare `name` can't be matched. **The registry entry is the only documentation-related file to hand-write** — the actual `documentation/<app>/*.md` content is generated automatically after merge (the deploy train records the change through `agentic-docs-on-main.yml`, and the nightly docs batch writes the docs); don't write those files yourself.
- **`firestore.indexes.json`**: add a composite index for any query with more than one filter, or an equality filter plus a range/`orderBy` field (list every equality field first, then the range/order field last — Firestore requires this exact shape). Collection-group queries (`FirebaseFirestore.instance.collectionGroup(...)`) need `"queryScope": "COLLECTION_GROUP"` explicitly — the default `"COLLECTION"` scope silently won't serve them. The deploy train deploys index changes after merge, the same as rules (step 2).
- **`packages/<app>/bluejay_app.json`**: the app manifest. After the PR merges and the deploy train puts the web app live, it runs `.github/workflows/register-apps.yml`, which creates `apps/{appId}` from it and installs the app into `installInGroups`; there is no manual registration step. Shape (`packages/queue_management/bluejay_app.json` is a real one):
  ```json
  {
    "appId": "<appId>",
    "name": "<Display Name>",
    "description": "<one line>",
    "icon": "<a key of packages/shared_ui/lib/icons.dart>",
    "iconBgColor": "#00695C",
    "iconColor": "#FFFFFF",
    "categories": ["<Category>"],
    "creatorEmail": "<the requesting owner's bluejay login>",
    "sharedEditing": false,
    "installInGroups": ["<groupId>"]
  }
  ```
  `appId` must equal `APP_ID`. Set `sharedEditing: false` when the app's documents are personal rather than shared (it decides whether every member gets `:edit`), and `securityTier` when the app needs more than `casual` (`SECURITY_TIERS.md`): an install into a group whose `minimumAppSecurityTier` is higher is refused. The gate checks the app's effective tier, the lower of the declared one and the one `scripts/security_tier_audit` computes from the table, so declare only what the app's table entries actually meet (run `node scripts/security_tier_audit/audit.js --app <appId>`). `installInGroups` is the groups the owner asked for; ask if they didn't say. For an App Maker request it is the request's own `groupId`, so the group that asked gets the app when it deploys. The manifest only seeds the app: once `apps/{appId}` exists, App Manager owns it and the sync never overwrites it or uninstalls anything. `node scripts/check_app_ids.js` validates the manifest; see `scripts/firestore_admin/README.md` for the full rules.

### 10. Store listing: seed and scenes (required)

A new app ships with an Add Apps listing. In the same PR, follow the `publish-app-listing` skill (`.claude/skills/publish-app-listing/SKILL.md`) to add `demo/seed/<appId>.js` and `demo/scenes/<appId>.json` with at least three scenes, and add the app to `demo/group.json` `installedApps` (format in `demo/README.md`). `node scripts/check_demo_seed.js` must pass. The seed and scenes can't be captured until the app is live, so the screenshots, tagline and categories follow once it deploys: the App Screenshots workflow's next scheduled run (the 1st or 15th of the month) captures new scenes once the app is live, or run it by hand for the app, and the rest of the skill (status, review, store copy) runs then. Say in the PR which of those steps remain.

### 11. Testing

- Dart: `packages/<app>/test/<app>_service_test.dart` using `flutter_test`, covering pure model/logic functions — `toMap()`/`fromDoc()` round trips, derived getters, URL/text builders, `copyWith` field-preservation (see step 4's warning). Check `which flutter`/`which dart` first; if unavailable in this environment (the common case), say explicitly in the PR that these were verified by careful reading only, not by running them — never imply a test suite ran when it didn't.
- Widgets: `test/<app>_widgets_test.dart` pumps the presentational widgets in `MaterialApp(theme: BluejayTheme.build())` with fake data, covering the empty, error and loaded states.
- Screenshots: copy `packages/projects/test/screenshots_test.dart` to `test/screenshots_test.dart` (opt-in with `BJ_DESIGN_SCREENSHOTS=1`, output git-ignored in `test/screenshots/out/`), render at 390 and 1280 px, and look at the PNGs before opening the PR.
- Functions: as in step 8 — actually run `node --test`, and say so, since it's genuinely possible here.

### 12. Open the PR

- Branch: `claude/<app-name>-<short-desc>` off latest `origin/main`.
- Open it as a draft (`gh pr create --draft`), run `scripts/ci/local_check.sh` (it analyzes and tests the new package and runs the Node checks on its `security/collections.json` entries and manifest), fix what it reports, then `gh pr ready <n>` (CLAUDE.md, "Draft PRs, local checks and PR size").
- PR description must cover: what was built; the `security/collections.json` entries added (one per collection) and why each has the kind and keys it has; the manifest's `installInGroups` (where the app appears once deployed); an honest test-plan section stating what was actually run vs. only read carefully; and the release note line (see "And a release note" in `CHANGE_REQUEST_SCOPE.md`): `**Release note:** none — internal app` when `installInGroups` holds only internal groups, otherwise a sentence naming the new app for the groups that get it.
- Leave it open for review — don't merge your own scaffolding PR without being asked.

## Constraints

- Never add a `match` block to `firestore.rules` or `storage.rules`: express every access pattern as a `security/collections.json` (or `security/storage_paths.json`) entry. If no existing key fits, stop and ask; a new generic key is a `change-firestore-permissions` change, not part of scaffolding an app.
- Never write the `apps/{appId}` document or a group's `installedApps` directly: declare them in `bluejay_app.json` and let the deploy register the app.
- Never build a second notification delivery path — always `NotificationService`.
- Never hand-write `documentation/<app>/*.md` — only the `feature_doc_mapping.json` entry that points the doc-generation automation at the new code.
- Never assume a third-party package's API from memory or a similar-sounding package — verify the real, current API (WebFetch against its actual docs) before writing code against it.
- If genuinely unsure whether a data-access pattern needs a new rule, re-derive the answer from the live `firestore.rules` file itself, not from this skill's summary or `FIRESTORE_PERMISSIONS.md` alone — both can drift from what's actually deployed.
