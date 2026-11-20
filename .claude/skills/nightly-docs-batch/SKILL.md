---
name: nightly-docs-batch
description: Produce the nightly documentation update — read the docs pending-change log, triage each touched feature (trivial / incremental / full), document cross-cutting merges once on a shared platform page, dispatch one isolated subagent per feature that needs one, script the timeline and the generated permissions tables, verify everything, and open ONE docs PR for the whole night that the docs auto-merge workflow then merges. Use when a scheduled session or the user says things like "run the nightly docs batch", "do tonight's docs", "update docs for everything merged today", or "process the pending doc changes".
---

# Nightly Docs Batch

`.github/actions/record-pending-docs`, run by each deploy train as its `docs_pending` target (and by hand through `agentic-docs-on-main.yml`), records which documentation features the commits merged since the `deployed/docs_pending` tag touched, one entry per commit and feature, in a single commit per train (`documentation/.pending_doc_changes.json`, matched against `documentation/feature_doc_mapping.json` watch rules by `scripts/docs/record_pending_entries.js`). This skill turns that log into **one docs PR per night**, spending agent time only where the docs actually need it:

| Mode | When (decided by the builder, deterministically) | Work |
|---|---|---|
| `trivial` | Every merge within the feature's watch paths is test-only, generated/lockfiles, or comment/whitespace-only — or its only real changes come from cross-cutting merges and total < 40 lines | **No agent.** Scripted timeline line(s) + state update |
| `incremental` | Default for real changes | One agent with the diffs (inline up to ~1500 lines), updating only the affected sections; improvements-* only lose implemented items |
| `full` | Docs folder new/incomplete, last full audit > 30 days old, diff > 6000 lines, or a **rotation** pick (up to 3 features/night with no pending changes, oldest full audit first) | One agent with the original full-audit prompt (same quality bar as ever, incl. the forward-looking improvements-* refresh) |
| cross-cutting task | A merge touching ≥ 8 outstanding features | One agent writes ONE section on `documentation/platform_changes/developer.md`; the per-feature agents link to it instead of re-describing the change |

Apps that admit guests (`"guestAudience": "visitors"` or `"clients"` on their `feature_doc_mapping.json` entry) also have a `guest.md`, the guide guests read from the app's help tab. The builder adds it to those features' required files and prompts, and `verify` fails when it's missing; nothing extra to do by hand.

Agents never edit `timeline.md` (the `timeline` step appends one line per merge: date, PR, author, commit subject, in the file's own format) or the generated **Data and permissions** block in each `developer.md` (`render-permissions`, from `security/collections.json` + `security/storage_paths.json`, re-rendered for every slug every night).

All grouping, triage, prompt text, state bookkeeping and verification live in `scripts/docs/nightly_docs_batch.js` (with `docs_triage.js`, `docs_timeline.js`, `permissions_doc.js`, all unit-tested). Don't re-implement any of it by hand — run its subcommands.

**Shell is zsh.** Unquoted `$VAR` does **not** word-split: `for s in $SLUGS` loops once with the whole string. Use arrays (`slugs=(a b c); for s in "${slugs[@]}"`) or `${=VAR}`, and always brace variables (`${WT}/documentation`, never `$WT/...` next to a `:` — `$R:f` is a zsh modifier). Never build a delete/revert list from an unquoted variable: on 2026-11-06 a bad keep-list deleted every worktree.

## Step 0 — Preconditions

- Don't run twice in parallel or on top of an unmerged night: `gh pr list --state open --search "docs: nightly batch in:title" --json number,title,headRefName,mergeStateStatus`. If a previous nightly PR is still open, do **not** start a new batch (it would redo the same entries and conflict on `documentation/.docs_batch_processed.json`). Instead check why it's stuck: failing check → report it; conflicting → follow `cleanup-documentation-prs`; green but unmerged → `gh workflow run auto-merge-docs-pr.yml` to sweep. Then stop and report.
- Never use `git stash`. Never touch other worktrees or the main checkout's working tree — other sessions use them.

## Step 1 — Worktree

```zsh
DATE=$(date -u +%Y-%m-%d)
REPO=$(git rev-parse --show-toplevel)          # the bluejay checkout
WT="${REPO}/.claude/worktrees/docs-nightly-${DATE}"
BATCH="/tmp/docs-nightly-${DATE}.json"         # outside the repo, never committed
git -C "${REPO}" fetch origin main
git -C "${REPO}" worktree add "${WT}" -b "claude/docs-nightly-${DATE}" origin/main
```

If the branch already exists from an earlier aborted run today and has no open PR, delete that worktree/branch first (`git worktree remove --force "${WT}"; git branch -D "claude/docs-nightly-${DATE}"`) — only that exact path and branch.

## Step 2 — Build the batch, re-render the permissions tables

```zsh
node "${WT}/scripts/docs/nightly_docs_batch.js" build --date "${DATE}" --out "${BATCH}"
node "${WT}/scripts/docs/nightly_docs_batch.js" render-permissions --root "${WT}"
```

`build` reads pending − processed (`documentation/.docs_batch_processed.json`), groups per `documentationSlug`, triages every (feature, merge) pair from `git show` of the feature's watch paths, detects cross-cutting merges, picks modes, adds rotation features, and caps the night's **agent** features at `--limit` (default **60**; trivial features are free and never deferred). Output: `{ date, worktree, baseSha, features: [{ slug, mode, modeReason, rotation, dependsOn, newFolder, keys, merges, prompt, … }], crossCutting: [{ shortSha, pr, subject, slugs, heading, documented, prompt }], processedKeys, droppedKeys, deferred, stateBootstrap, summary }`. stderr prints the per-mode counts. `prompt` is `null` for trivial features (and for cross-cutting merges already documented on an earlier night); every prompt already contains the absolute worktree path.

`render-permissions` rewrites the generated block in every mapped app slug's `developer.md` (no agent; it's a no-op when the tables haven't changed). Running it **before** the agents means they read the current table.

- `features` empty and `droppedKeys` empty → nothing to do: if `render-permissions` changed nothing either, remove the worktree and branch, report "no pending doc changes", stop. If it did change blocks, continue to Step 6 with just those.
- `features` empty but `droppedKeys` non-empty → skip to Step 5 (record them so on-main prunes them).
- `deferred` non-empty → those agent features stay pending for tomorrow; mention them in the PR body. A huge night is still ONE PR. `--limit 0` = no cap; `--rotation 0` disables rotation; `--all-full` restores the old every-feature-full-audit behaviour (use only if triage itself is suspected broken).

## Step 3 — Cross-cutting tasks first, then one subagent per feature

Keep a `failed` zsh array. It holds failed feature slugs **and** failed cross-cutting short shas.

**3a. Cross-cutting tasks** — for each entry in `crossCutting` with a non-null `prompt`, **one at a time** (they all edit the same page, so never in parallel), launch an `Agent` (subagent_type `general-purpose`) with exactly that `prompt`. After each, verify it:

```zsh
node "${WT}/scripts/docs/nightly_docs_batch.js" verify --batch "${BATCH}" --stage agents --only "<shortSha>"
```

It must report `missingCrossCutting: []` and no `outOfScope`. On failure (agent failed, section heading missing, stray edits), revert `documentation/platform_changes/` to HEAD, retry once if transient, else add the short sha to `failed`. A failed cross-cutting task automatically excludes every feature that depends on it (`dependsOn`) in all later steps — their entries stay pending and retry tomorrow, when the task is re-emitted.

**3b. Per-feature agents** — for each feature with a non-null `prompt` that doesn't depend on a failed cross-cutting sha, launch an `Agent` whose prompt is **exactly** the feature's `prompt` string (read it with `node -e` / `jq`; don't paraphrase, shorten, or merge prompts). One feature per agent, never two. Trivial features get no agent.

- Run in **waves of ~6** agents in parallel (one message with ~6 Agent calls, run in foreground so the wave completes before you continue). Then the next wave.
- After **each wave**, verify that wave immediately (Step 4) — this keeps any stray edit attributable to at most ~6 agents.

## Step 4 — Verify each wave

```zsh
node "${WT}/scripts/docs/nightly_docs_batch.js" verify --batch "${BATCH}" --stage agents --only "<this wave's slugs, comma-separated>" --exclude "<failed, comma-separated>"
```

It prints `{ ok, outOfScope, missing, unchanged, changedSlugs, timelineEdits, stalePermissions, missingCrossCutting }` from `git status` against the batch.

- `timelineEdits` — an agent edited a `timeline.md` despite the rule. Restore just that file (`git -C "${WT}" restore --source=HEAD --staged --worktree -- "<path>"`); the feature itself is fine.
- `stalePermissions` — an agent edited inside the generated block. Re-run `render-permissions --root "${WT}"`; the feature itself is fine.
- `developer.md` changes of slugs **outside** the batch are accepted only when they are confined to the generated block (that's the Step 2 re-render).

A feature fails when:

- its agent reported `STATUS: failed`, errored, or timed out;
- any of its non-timeline required files is in `missing` (the timeline step creates `timeline.md` for new folders);
- `outOfScope` lists paths it touched (anything outside `documentation/<its slug>/`, e.g. another feature's docs, the platform page, source code, `feature_doc_mapping.json`, `.pending_doc_changes.json`, a non-asset `pubspec.yaml` change). Attribute stray paths via the agents' `FILES:` reports; if a stray path can't be attributed, treat **every** feature in that wave as failed.

`unchanged` (agent changed nothing) is acceptable for **incremental** features whose SUMMARY says "no doc change needed" with a plausible reason; for **full** features only if the report says the docs were already accurate. Otherwise mark it failed.

For each failed slug, revert just its folder, and revert every out-of-scope path:

```zsh
git -C "${WT}" restore --source=HEAD --staged --worktree -- "documentation/${slug}/" 2>/dev/null
git -C "${WT}" clean -fdq -- "documentation/${slug}/"
# each stray path p (quoted, one at a time):
git -C "${WT}" restore --source=HEAD --staged --worktree -- "${p}" 2>/dev/null || git -C "${WT}" clean -fq -- "${p}"
```

Then re-run `render-permissions` (a reverted `developer.md` keeps HEAD's block, which may predate tonight's re-render). Failed features are excluded from the timeline, state and processed steps below, so their entries stay pending and retry next night. Don't re-dispatch a failed feature in the same run unless the failure was clearly transient (one retry max).

## Step 5 — Scripted steps, final verify

```zsh
EXCLUDE="${(j:,:)failed}"   # zsh join of the failed array (slugs and cross-cutting shas)
node "${WT}/scripts/docs/nightly_docs_batch.js" render-permissions --root "${WT}"
node "${WT}/scripts/docs/nightly_docs_batch.js" timeline        --batch "${BATCH}" --exclude "${EXCLUDE}"
node "${WT}/scripts/docs/nightly_docs_batch.js" state           --batch "${BATCH}" --exclude "${EXCLUDE}"
node "${WT}/scripts/docs/nightly_docs_batch.js" register-assets --batch "${BATCH}" --exclude "${EXCLUDE}"
node "${WT}/scripts/docs/nightly_docs_batch.js" record          --batch "${BATCH}" --exclude "${EXCLUDE}"
node "${WT}/scripts/docs/nightly_docs_batch.js" verify          --batch "${BATCH}" --exclude "${EXCLUDE}"
```

- `render-permissions` (again): new folders created by full-mode agents get their block, and any block an agent touched is restored.
- `timeline` appends one line per merge for every successful feature (trivial ones included), in the style each file already uses (table / bullets / headings, oldest-first or newest-first); cross-cutting merges link the platform-page section. Idempotent: merges already mentioned (by short sha or PR number) are skipped. Creates `timeline.md` for new folders.
- `state` writes `documentation/.docs_state.json`: `lastDocumentedSha` (newest merge, or the batch base for full audits), `lastFullAuditAt` / `lastImprovementsRefreshAt` (tonight, for full-mode features). The first run also persists the bootstrapped values for every mapped slug (see the header of `nightly_docs_batch.js`).
- `register-assets` adds a `- documentation/<slug>/` line to `pubspec.yaml` for each successful new folder, including `platform_changes/` the first time a cross-cutting section is written (Flutter assets aren't recursive; the auto-merge accepts asset-only pubspec changes once checks pass).
- `record` adds the successful features' keys (plus dropped keys) to `documentation/.docs_batch_processed.json`. **Never edit `documentation/.pending_doc_changes.json`** — `agentic-docs-on-main.yml` rewrites it on almost every deploy train, so the PR would conflict. When this PR merges, the next train's on-main run prunes the recorded keys from pending and then trims the processed file back down.
- The final `verify` must print `"ok": true` (all required files incl. timeline, current permission blocks, every successful cross-cutting section present). Also `git -C "${WT}" diff --name-only HEAD` and `git -C "${WT}" status --porcelain` must show only `documentation/**` and (asset-only) `pubspec.yaml`. If not, fix (revert) before continuing. Don't edit any feature's docs yourself beyond fixing a clear contradiction between agent reports.

If nothing succeeded, there are no dropped keys and the permissions re-render changed nothing, don't open a PR: remove the worktree, report the failures, stop.

## Step 6 — Commit, push, PR

```zsh
N=<number of successful features>
git -C "${WT}" add -- documentation pubspec.yaml
git -C "${WT}" status --porcelain     # sanity-check the staged list
git -C "${WT}" commit -F - <<EOF
docs: nightly batch ${DATE} (${N} features)

<one line per agent feature: slug (mode) — its agent's SUMMARY first line>
<one line per cross-cutting section: PR #N — its agent's SUMMARY first line>
<"N trivial features: timeline only" and "permissions blocks re-rendered: N">

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git -C "${WT}" push -u origin "claude/docs-nightly-${DATE}"
```

`gh pr create --repo bluejayorg/bluejay --base main --head "claude/docs-nightly-${DATE}" --title "docs: nightly batch ${DATE} (${N} features)" --body-file <file>` with a body containing:

- `## Summary` — the builder's per-mode counts (trivial / cross-cutting downgrades / incremental / full / rotation / cross-cutting tasks / agents).
- `## Platform changes` — per cross-cutting task: PR, subject, affected-feature count, the agent's SUMMARY.
- `## Features` — per agent feature: `slug` (mode, reason), its merges (`shortSha` + subject), and the agent's SUMMARY. Then one compact line listing the trivial features (timeline/state only).
- `## Generated permissions` — the slugs whose Data and permissions block changed tonight (from `git diff --stat`), if any.
- `## Not documented tonight` — failed slugs with reason (entries left pending, retry tomorrow), deferred slugs past the cap, dropped unmapped slugs.
- `## Findings (flagged, not fixed)` — the agents' non-`none` FINDINGS, one line each.
- `**Release note:** none`
- final line: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

Do **not** title it `[WIP]` (the auto-merge skips those) and open it ready, without `--draft`: the batch is finished when it's opened, and the auto-merge and CI both skip drafts (CLAUDE.md, "Draft PRs, local checks and PR size"). `.github/workflows/auto-merge-docs-pr.yml` classifies it as documentation-only (all files under `documentation/`, plus asset-only `pubspec.yaml`) and merges it — immediately, or after checks when `pubspec.yaml` is touched. You don't merge it yourself.

## Step 7 — Clean up and report

`git -C "${REPO}" worktree remove "${WT}"` (the branch lives on in the PR), `rm -f "${BATCH}"`. Report: PR URL, per-mode counts, agents run, features failed / deferred / dropped, and any findings.

## Constraints

- One PR per night; at most one agent per feature (none for trivial ones); cross-cutting agents run first and one at a time; agents edit only their own `documentation/<slug>/` (cross-cutting agents only `documentation/platform_changes/developer.md`), never `timeline.md` or a generated block.
- Never edit `documentation/.pending_doc_changes.json` or `documentation/feature_doc_mapping.json` in this PR.
- Don't edit agent prompts; to change the instructions, thresholds or quality bar, change `scripts/docs/` in a normal code PR.
- Never merge, force-push, `git stash`, or touch other worktrees.
