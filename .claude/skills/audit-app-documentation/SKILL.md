---
name: audit-app-documentation
description: Audit documentation coverage for every bluejay app package — find apps missing from the wiki registry entirely, find apps with incomplete user/developer/interfaces docs, fill the gaps by reading the actual source, and open a PR with the result. Use when the user says things like "audit our documentation", "check for missing docs", "make sure every app has docs", "run a documentation audit", or asks whether documentation coverage is complete. Complements the nightly docs pipeline (`.github/workflows/agentic-docs-on-main.yml` records changes; the `nightly-docs-batch` skill documents them in one PR per night), which only refreshes docs for apps *already* in the registry, reactively, for merged changes — this skill is the proactive, whole-repo sweep that catches apps that were never registered at all, and can be run any time on demand.
---

# Audit App Documentation

Every app package should have a registry entry in `documentation/feature_doc_mapping.json`, a `documentation/<slug>/` folder bundled in `pubspec.yaml`, and three core files (`user.md`, `developer.md`, `interfaces.md`) inside it, plus a `guest.md` for every app that admits guests. This skill finds every place that's not true, fixes it by reading real source code, and opens one PR with the result. Rediscover how the system actually works fresh each run (Step 1) rather than trusting a stale mental model — it may have evolved since this skill was written.

## Step 1 — Learn the doc system fresh (don't assume filenames)

Read these to (re)confirm how the system actually works right now, since it may have evolved:

- `documentation/feature_doc_mapping.json` — the registry. Each entry has `name`, `documentationSlug`, `documentationAudience` (`app`/`developer`/`global` — who the *docs* are for; unrelated to whether the feature has its own registered Firestore app, see below), `watch` (array of `{type: "directory"|"file", path}`), and optionally `appId`. Every entry, regardless of `documentationAudience`, should also have `description` (one or two sentences) and `keywords` (a short list) — BlueJI (`packages/blue_ji`, `functions/blue_ji.js`) uses these to route user questions to the right doc; an entry with neither has no signal beyond its bare `name`. BlueJI gates candidates by `documentationAudience` the same way `packages/wiki/lib/wiki_visibility.dart` gates Wiki visibility: `documentationAudience: "app"` requires the appId to be installed; `documentationAudience: "global"` is always offered to everyone; `documentationAudience: "developer"` is elevated-role-only unless the entry adds `"audience": "all"` (for developer-audience docs that are cross-cutting but genuinely written for any user, e.g. `payments`). When adding a new `developer`-audience entry, read its `user.md` and decide `audience` the same way — is this written for an end user, or only for someone building/administering the platform? Note `documentationAudience` and `appId` are independent fields — a `developer`-audience entry can still carry its own `appId` if the feature has a real registered Firestore app (e.g. `app_access`); don't reclassify to `app` just to give it one. `scripts/security_tier_audit/audit.js` is the canonical example of a consumer that correctly keys off "has an `appId`" rather than `documentationAudience`.
- `pubspec.yaml`'s `flutter: assets:` block — every `documentation/<slug>/` folder must be listed here or the wiki can't load it, even if it's registered.
- `packages/wiki/lib/wiki_screen.dart` — confirm how the viewer resolves docs (as of this writing: catalog is built from bundled assets matching `documentation/{slug}/{user,developer,interfaces}.md`; the registry only supplies visibility metadata). If this has changed, adjust the rest of this skill's assumptions accordingly.

## Step 2 — Check for in-flight work

`gh pr list --search "audit-app-documentation" --state open` and check for an already-open branch named `docs/audit-app-documentation-*`. If one exists and looks current, tell the user and stop rather than duplicating it.

## Step 3 — Find every gap

Enumerate `packages/*` (exclude `build/` dirs) and cross-reference against the registry's `watch` paths. For each package with zero `watch` references anywhere in the mapping, it's **unmapped** — classify it:

1. **Get its appId.** Look for `const APP_ID = '...'` in `packages/<name>/lib/constants.dart` (or equivalent).
2. **Is it independently routed?** Grep `lib/routing/app_router.dart` for a route tied to that appId or to the package's main screen. If yes → this is a standalone app.
3. **If not routed, who imports it?** `grep -rl "package:<name>/" packages/ lib/`. If exactly one other package imports it, it's almost certainly an embedded sub-feature of that parent (e.g. a chat widget embedded in a storefront app, or a tab inside an admin console) — treat it as part of the parent's product surface, not a separate one.
4. **Decide `documentationAudience` and `appId` for the new registry entry:**
   - Standalone routed app → `documentationAudience: "app"`, `appId` = its own `APP_ID`.
   - Sub-feature of exactly one parent app that already has a registry entry → `documentationAudience: "app"`, `appId` = **the parent's** `appId` (this is deliberate — it ties the sub-feature's wiki visibility to the same "is this app installed" gate as its parent). Say so explicitly in that sub-feature's `user.md` ("accessed via X, not launched on its own").
   - Cross-cutting internal library imported by many unrelated packages with no single owning parent and no independent screen a normal user launches (e.g. a shared billing/notification/auth layer) → `documentationAudience: "developer"`, no `appId`.
5. **Build the `watch` list:** always `{type: "directory", path: "packages/<name>"}`; add `{type: "file", path: "functions/<name>.js"}` (check both `functions/<name>.js` and `functions/_<name>.js`) if it exists.

Separately, for every slug **already in the registry**, check `documentation/<slug>/` on disk for `user.md`, `developer.md`, and `interfaces.md`. Note which are missing. Also flag any file in a `documentation/<slug>/` folder that isn't `user.md`, `developer.md`, `interfaces.md`, `guest.md`, `improvements-*.md`, or `timeline.md` — these are stray legacy docs to fold into the standard files and delete. (`documentation/platform_changes/` is the exception: it holds only a `developer.md`, maintained by the nightly docs batch, and is not an app.)

**Guest guides.** Run `node scripts/docs/guest_docs.js audit-prod` (it reads production `apps` with the same admin credentials as `scripts/firestore_admin`; read-only). It lists every app whose production flags admit guests (`isEmbeddable` → visitors, `clientPortal` → clients) without a matching `"guestAudience"` on its registry entry, every declared audience the app no longer has, and every guest app missing its `guest.md`. For each: set or remove `guestAudience` yourself in Step 4, and put a missing or stale `guest.md` on the writing punch list. `documentation/README.md` ("`guest.md` for apps that admit guests") defines the file.

Also check every existing registry entry (any `documentationAudience`) for a missing `description` and/or `keywords` field — add these to the punch list too (fill them in yourself in Step 4 from the app's `user.md`/source, they're short enough not to need a writing agent). For `developer`-audience entries, also decide whether `audience: "all"` belongs (see Step 1).

Build a complete punch list before writing anything: new registry entries needed, new `pubspec.yaml` asset lines needed, entries missing `description`/`keywords`, and a per-app list of exactly which of the three core files are missing or need replacing.

## Step 4 — Apply the structural fixes yourself (don't delegate these)

Edit `documentation/feature_doc_mapping.json` and `pubspec.yaml` directly for every new registry entry, asset line, and missing `description`/`keywords` pair found in Step 3. Do this centrally, not via subagents — concurrent edits to the same two files from parallel agents is how you get merge conflicts or silently-dropped entries. Validate `feature_doc_mapping.json` is still well-formed JSON immediately after editing (`python3 -c "import json; json.load(open('documentation/feature_doc_mapping.json'))"`).

## Step 5 — Delegate content writing to parallel background agents

For the apps needing new or completed doc files, group them into batches of roughly 3-4 apps each and dispatch one background `general-purpose` Agent per batch (run them in parallel, not sequentially — this is the expensive part of the audit and there's no dependency between batches). Give each agent:

- **Style calibration**, without hardcoding filenames that might go stale: tell it to find one of the largest and one of the smallest `documentation/*/developer.md` files by line count to use as heavy/light depth references, and to match depth to the target app's actual complexity rather than padding simple apps or under-documenting complex ones.
- **Its specific apps**: package path, whether it's a sub-feature (and of what parent, if so — tell it to say so plainly in `user.md`), the `appId`/`documentationAudience` already decided in Step 3 (informational only — it should not touch the registry), and exactly which of the three files are missing or need replacing.
- **A hard requirement to read the actual full source** (every `.dart` file in `lib/`, plus any relevant `functions/*.js`) before writing a single line — no invented behavior, fields, or endpoints.
- **The app-focus rule for `user.md`** from "Keep each `user.md` about its own app" in `documentation/README.md`: the guide covers this app only, uses industry-neutral examples unless the app itself is industry-specific, names no customer groups or organizations, and mentions other apps only where they integrate (saying what happens when that app isn't installed and linking to its guide).
- **For a `guest.md`**: whether the app's guests are visitors (link, no account) or clients (client portal), and an instruction to read the app's guest code paths (`GuestStatus` checks, the collection's guest/client rules in `security/collections.json`) and describe only what those guests see and can do, per "`guest.md` for apps that admit guests" in `documentation/README.md`.
- **Instructions to fold in and delete** any stray legacy doc file assigned to it, after extracting anything still-accurate into the new standard files.
- **An explicit instruction not to touch** `feature_doc_mapping.json` or `pubspec.yaml`, any `timeline.md` (the nightly docs batch appends scripted entries to it), `documentation/platform_changes/` (written only by the nightly batch's cross-cutting agents), or anything between `<!-- generated:data-permissions:start -->` and `<!-- generated:data-permissions:end -->` in a `developer.md` — that Data and permissions table is rendered from `security/collections.json`, so prose should link to it rather than restate who may read/write what.
- **A request to report back**: files written, one sentence per app on what it actually does, and — importantly — any non-documentation oddities noticed while reading the code (dead/unreachable code, naming inconsistencies, notifications with no deep-link handler, inconsistent Firestore scoping, etc.). These are findings to surface, not to fix.

## Step 6 — Verify before opening the PR

Run the same checks every time, and don't proceed to Step 7 until all pass:

- `feature_doc_mapping.json` is valid JSON.
- Every registry entry's `documentationSlug` has `user.md`, `developer.md`, and `interfaces.md` on disk.
- `node scripts/docs/guest_docs.js audit-prod` reports no findings.
- Every registry entry's slug appears in `pubspec.yaml`'s asset list.
- Every `packages/*` directory is referenced by at least one registry `watch` path.
- No stray non-standard files remain in any touched `documentation/<slug>/` folder.
- Run `node scripts/docs/nightly_docs_batch.js render-permissions` (adds the generated Data and permissions block to any new `developer.md`, and restores any block an agent edited), then `node scripts/docs/nightly_docs_batch.js render-permissions --check` passes.

If nothing was actually missing (a clean audit), tell the user documentation is fully up to date and stop — do not open an empty PR.

## Step 7 — Commit, push, open the PR

- `git fetch origin main`, then branch off `origin/main` specifically — **not** off whatever branch happens to be checked out. The working tree may have unrelated in-progress feature work on it; bundling that into a docs PR is a real risk this skill must avoid.
- Branch name: `docs/audit-app-documentation-<YYYY-MM-DD>` (append `-2`, `-3`, ... if that name is already taken from an earlier run today).
- Stage explicitly — `git add documentation/ pubspec.yaml` — never `git add -A` or `git add .`. The working tree may contain unrelated untracked build artifacts or scratch files that must not end up in this commit. Run `git status --porcelain -- documentation/ pubspec.yaml` after staging and sanity-check the file list matches what you intended before committing.
- Commit with a message summarizing the scope (apps newly registered, apps completed, stray files removed).
- Push and `gh pr create`, ready (no `--draft`): Step 6 already verified it, and the docs auto-merge and CI both skip drafts (CLAUDE.md, "Draft PRs, local checks and PR size"). PR body must include: apps newly registered in this run, apps whose doc sets were completed, stray files cleaned up, the Step 6 verification results, and any non-doc findings the writing agents surfaced (framed clearly as "flagged for follow-up, not fixed in this PR").
- **Never merge it yourself.** Leave it open for human review, same as every other PR-producing skill in this repo. If the PR also adds `- documentation/<app>/` asset lines to `pubspec.yaml` (true whenever a brand-new app's doc folder was added), `.github/workflows/auto-merge-docs-pr.yml` still auto-merges it, but only after its checks pass, since a bad asset line would break the web build. Any other `pubspec.yaml` change makes it ineligible for auto-merge.

## Step 8 — Report back

Give the user: the PR URL, a short summary of what was found and fixed (counts, not a wall of file paths), and a clearly separated callout of any non-documentation findings surfaced during the audit (bugs, dead code, inconsistencies) — phrased as suggestions for separate follow-up work, not as something already fixed.

## Constraints

- One PR per run.
- Only touch files that are missing, incomplete, or contain stray/non-standard content. Don't rewrite already-complete, healthy docs just to restyle them — that produces churn without value and makes the diff harder to review.
- Every doc claim must trace back to something actually read in source. If a subagent's report doesn't make clear it read the real code, don't trust its output at face value — spot-check before including it in the PR.
- Keep the registry and pubspec edits centralized in Step 4, never delegated.
- Match the existing docs' voice and structure (headers, tables, JSON examples, mermaid diagrams where they clarify something real) rather than introducing a new format.
