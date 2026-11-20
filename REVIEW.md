# Pull request review guidelines

What to check when reviewing a pull request in this repository, whether the
reviewer is a person or Claude (`/code-review`).

---

## Scope

Blocking CI enforces the mechanical Firestore checks
(`scripts/check_gateways.js`, `node security/generate.js --check`,
`security/check_rules_exceptions.js`, `security/check_server_collections.js`
and the rules emulator suite, `rules-tests.yml`). Review covers the judgment
calls below.

When any of the paths below change, review them intentionally and leave a review
comment when the PR misses one of these requirements.

---

## 1. Firestore access in `packages/` must use `ScopedCollection`

All Dart code in `packages/` that accesses Firestore must use
`ScopedCollection` from `shared_services`.

Flag a review issue when a package file uses
`FirebaseFirestore.instance` or a raw `.collection(...)` on a tenant
collection, because that bypasses required group scoping, the rules reject
the unscoped query, and the read isn't metered.

### Do not flag these exceptions

- A raw `.collection(...)` (through `BluejayFirestore.forApp(APP_ID)`) on a
  pass-through kind in `security/collections.json`: `server`, `personal`,
  `platform`, `platform_admin` or `public` (e.g. `notifications`, the
  caller's own `users/{uid}`, `apps`)
- Lines marked `// gateway-exempt: <rule> <reason>`
- Test files
- `scoped_collection.dart` and the other gateway files themselves

A new `ScopedCollection(collection: 'x')` also needs `x` declared in
`security/collections.json` (CI's `undeclared-collection` rule).
Another user's profile comes from `GroupMemberDirectory`, never their
`users/{uid}` doc.

If you flag this issue, tell the author to switch to `ScopedCollection`, keep
`APP_ID` in `constants.dart`, and rely on the injected `groupId`, `appId`,
`creatorId`, and `ownerIds` fields.

Reference: `FIRESTORE_PERMISSIONS.md` §5.

---

## 2. Firestore composite-index coverage must be reviewed in PRs

When changed Dart files under `packages/` use `ScopedCollection.query`, inspect
new or modified query chains.

Flag a review issue when a query appears to require a composite index that is
missing from `firestore.indexes.json`.

Treat these patterns as index-sensitive:

- any `.orderBy(...)` on a `ScopedCollection.query`
- `arrayContains` or `arrayContainsAny` combined with another `.where(...)`

When evaluating the required index, remember that `ScopedCollection` injects a
`groupId` equality filter automatically. The expected index coverage therefore
includes:

- `groupId`
- every explicit `.where(...)` field
- every `.orderBy(...)` field, with the detected direction

If coverage appears missing, say so in the review and suggest updating
`firestore.indexes.json`. Use the project convention of `groupId ASC` first,
then equality fields, then ordered fields.

Reference: `FIRESTORE_INDEXES.md`.

---

## 3. `firestore.rules` changes should be treated as high risk

`firestore.rules` is a platform-level authorization layer and should almost
never change for individual micro-app features.

`firestore.rules` and `storage.rules` are generated from
`security/collections.json` and `security/storage_paths.json`
(`node security/generate.js`). Flag a high-severity review issue when a PR:

- edits a generated section by hand, or adds a new `match /...` block or
  `grant*` function to the hand-written half of either file
- adds an entry to the table's `exceptions`, or a reviewed grant key
  (`adminWritable`, `developerRead`/`developerWritable`, `stewardRead`,
  `memberWrite`, `guestShareable`) to a collection
- adds a single-app-named branch such as `collection == '...'`

Prefer the existing data-shape and entitlement model instead:
`groupId`, `appId`, `creatorId`, `ownerIds`, `ScopedCollection`, and a plain
table entry (`"my_items": { "apps": ["my-app"] }`). A table change also needs a
rules deploy after merge (Actions -> "Deploy rules"); remind the author.

If a feature appears blocked by rules, treat it as a data-shape or query-scoping
issue first and verify against `FIRESTORE_PERMISSIONS.md` before suggesting a
rules change.

---

## 4. Cloud Functions changes need deploy/reset reminders

When production Cloud Functions source changes under `functions/`, remind the
reviewer and author that the runtime will not update until the affected
functions are redeployed or otherwise reset.

Focus on changed `.js` files under `functions/`, excluding:

- `functions/_*.js`
- `functions/index.js`
- `functions/package.json`
- `functions/package-lock.json`

If possible, mention the top-level exported function names affected by the PR.
Your review should explicitly call out that changed functions may need a
Firebase deploy/reset before the behavior change is visible.

---

## 5. New micro-app packages must follow the Firestore setup contract

When a PR adds a new package under `packages/`, verify all of the following:

1. `lib/constants.dart` defines a unique lowercase `APP_ID`
2. the package `pubspec.yaml` depends on `shared_services`
3. each Firestore collection is represented by a file-level `ScopedCollection`
4. reads, writes, updates, deletes, and subcollections use the
   `ScopedCollection` API instead of raw `FirebaseFirestore.instance.collection`

---

## 6. Release notes must match what end users will notice

PR bodies carry a `Release note:` line (see "And a release note" in
`CHANGE_REQUEST_SCOPE.md`); live changes with a note become entries in the
What's New app. The release note step of PR Checks only checks the line exists,
so review the judgment:

- Flag a note on a change users can't notice (refactor, tooling, logging,
  invisible plumbing) — it should be `Release note: none`.
- Flag `Release note: none` on a change that visibly alters a screen, flow,
  result or error message an end user sees.
- Flag notes that describe implementation ("migrated to server-side
  thumbnails") instead of the user-visible effect ("album photos load
  faster"), and `Release apps` that don't match the apps the change touches.

---

## 7. UI and user-facing text follow the design system and brand voice

- Screens in `packages/` and `lib/` are built from `packages/bluejay_design` (see its README). Flag new raw `Colors.*`, `Color(0x...)` literals, `TextStyle(fontSize: ...)` or a new `*_theme.dart` that `scripts/check_design_tokens.js` would miss (for example one marked `// design-ok` without a real reason).
- A change to `packages/bluejay_design/lib/src/tokens.dart`, `accent.dart`, `color.dart` or the theme's text styles must also update `packages/bluejay_design/design_tokens.json`, and its PR body should say the brand guide needs the same change.
- UI text is sentence case, plain and specific: buttons are verbs that say what happens, errors say what to do next, destructive confirms name what will be lost. The product is spelled "Bluejay".

## 8. Review-comment expectations

When one of the checks above fails, leave a concise review comment that:

- names the risky file or query
- states the missing requirement
- gives the next action (`ScopedCollection`, index entry, rules rollback, or
  function deploy/reset reminder)

Prefer actionable comments over style feedback.
