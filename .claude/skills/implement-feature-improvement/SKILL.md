---
name: implement-feature-improvement
description: Pick the single highest-leverage improvement for a bluejay feature — from its improvements-*.md backlog, or a genuinely novel idea surfaced by reading all of its docs — and implement it directly, opening a PR that documents the choice, its unintended consequences, and how to test it. Use when the user says things like "implement the top improvement for <feature>", "do a quick win on <feature>", "work through the improvement backlog for <feature>", or "find and make the highest-value change to <feature>".
---

# Implement Feature Improvement

Claude picks one improvement for a feature and implements it in-session, ending in a PR for human review. The nightly docs batch (`nightly-docs-batch`) keeps the `improvements-*.md` backlogs current; this skill works through them.

## Inputs

Parse from the user's request:
- **feature** (required): a `documentationSlug` or `name` from `documentation/feature_doc_mapping.json`. If the user gives a fuzzy name, look it up in the mapping and confirm before proceeding if ambiguous.
- **priority** (optional, default `impactful`):
  - `impactful` — pick the single highest-leverage item, weighing risk/impact, across all improvement docs *and* any novel idea surfaced by reading the feature's full doc set (see step 4).
  - `easy` — pick the highest-impact item that is also simple and fast to verify. Prefer quick wins over complex/risky changes even if a bigger item scores higher on raw impact.

## Steps

1. **Resolve the feature.** Look it up in `documentation/feature_doc_mapping.json`. Note its `documentationAudience`, `appId`, and `watch` rules (these define the legitimate scope of code you may touch).

2. **Check for existing in-flight work.** Run `gh pr list --search "<slug>" --state open` and check open branches for anything already addressing this feature, to avoid duplicating work someone (or a prior run of this skill) already started. If something's clearly in flight, stop and tell the user instead of proceeding.

3. **Read the required docs**, all under `documentation/<slug>/`:
   - `improvements-security.md`
   - `improvements-performance.md`
   - `improvements-ux.md`
   - `improvements-features.md`
   - `developer.md`, `interfaces.md`, `user.md` (for context on current behavior)

4. **Select the single highest-leverage change** per the priority mode above. Weigh two pools together, not sequentially — don't default to the backlog just because it's easier to cite:
   - **Catalogued items** from the four `improvements-*.md` files read in step 3.
   - **A novel idea**, if reading `user.md`, `developer.md`, and `interfaces.md` surfaces a gap none of the improvements docs captured (security hole, missing capability, dead-simple high-value addition). It's fine — expected, even — for this to win over a catalogued item if it's genuinely more valuable. It's also fine for none to beat the best catalogued item; don't force novelty for its own sake.

   State your reasoning for the pick explicitly, including why it beat the next-best candidate from the other pool — this goes in the PR description.

5. **Create a feature branch** off latest `main`: `git fetch origin main && git checkout -b claude/feature-improvement/<slug>-<short-desc> origin/main`.

6. **Implement the change**, scoped to the selected improvement and the feature's `watch` paths. Don't scope-creep into unrelated fixes unless they're tightly coupled to this change.

   UI changes use bluejay_design (`packages/bluejay_design/README.md`); in an app already on it, don't add raw colours, `TextStyle(fontSize: ...)` literals or a `*_theme.dart` (`scripts/check_design_tokens.js` fails CI on them). A request to restyle or redesign an app follows the `polish-app-ui` skill. UI text follows the brand guide's voice and product-writing rules (CLAUDE.md, "Brand and design").

   **If the selected improvement touches `firestore.rules`, Storage rules, the `access_index`/entitlement pipeline, or any per-document ownership/membership model (who can read/edit/admin a doc, or add/remove members from something)** — stop before writing rules code and apply `change-firestore-permissions`'s Step 2 decision procedure: exhaust the existing generic primitives (`groupId` scope, entitlement tiers with `creatorId`/`ownerIds` ownership narrowing them, roles/segments, generic per-app config flags like `sharedEditing`, and the collection's keys in `security/collections.json`, from which `firestore.rules` is generated) before adding any new app-named or collection-named carve-out to the rules. A one-off `appId == '<name>'` branch is a smell even when it "works" and matches an existing precedent in the file — it's still one more bespoke case for the next reviewer, and the next app with the same shape of problem, to deal with. If no existing primitive (or reasonable generalization of one) covers the need, don't ship a bespoke rule quietly inside this PR — stop and confirm with the user first, same as that skill requires, even though this improvement wasn't a directly-requested permissions change.

7. **Update the improvements doc**, if applicable: if the selected item came from one of the `improvements-*.md` files, remove it — these files are forward-looking only, per the existing docs convention, and don't leave implemented items listed. If the selected item was the novel idea from step 4 (not sourced from any improvements doc), there's nothing to remove; say so in the PR instead. Either way, do not touch `user.md`, `developer.md`, `interfaces.md`, or `timeline.md` — the nightly docs batch updates them after this PR merges (`agentic-docs-on-main.yml` records the merge as a pending doc change).

8. **Run `scripts/ci/local_check.sh`** (add `--rules` if it prints the rules notice) and fix everything it reports before marking the PR ready (CLAUDE.md, "Draft PRs, local checks and PR size"). If a step can't run because a tool is missing (it says so), note that in the PR body rather than failing the task.

9. **Commit, push, and open a PR** via `gh pr create --draft`, then `gh pr ready <n>` once step 8 passes; a run that ends with the PR still in draft hasn't finished. PR body must include:
   - **Why this was chosen**: what was implemented and why it was selected as the single highest-leverage (or top quick-win) item — cite the specific improvements doc entry, or explain the gap that motivated a novel pick and why it beat the best catalogued alternative.
   - **What changed**: the change itself and why the approach is correct.
   - **Unintended consequences**: what could this break or degrade elsewhere — other callers of touched code, edge cases in scope/permissions, performance/cost implications, migration concerns for existing data. If there genuinely are none worth flagging, say so explicitly rather than omitting the section.
   - **How to test**: concrete steps a human reviewer can follow to verify the change (manual repro steps, which automated tests cover it, what to check in the running app), not just "tests pass."
   - A note if local validation was skipped due to missing tooling.
   - The `**Release note:**` / `**Release apps:**` lines from `CHANGE_REQUEST_SCOPE.md` ("And a release note") — or `**Release note:** none` if end users won't notice the change. Required by the Release Note Check workflow.
   - Leave the PR open for human review — **never merge it yourself**.

10. **Report back** to the user: PR URL, one-line summary of what was implemented, and either which improvements doc entry was removed or that it was a novel pick not previously catalogued.

## Constraints

- One improvement per run. Don't batch multiple items from the improvements docs into a single PR.
- Never auto-merge: leave the PR awaiting human approval.
- Stay inside the feature's `watch` scope from the mapping file unless a fix is tightly coupled.
- If Firestore rules, Storage rules, or billing-sensitive code are touched, flag that explicitly in the PR description for extra reviewer attention.
- Never add a bespoke, single-app-named branch to `firestore.rules` without first exhausting the existing generic primitives (ownership, groupId scope, entitlement tiers, roles/segments, per-app config flags, table keys) per `change-firestore-permissions`'s Step 2, and confirming with the user if none apply. This applies even when the permissions fix is a means to an end (e.g. the improvement itself is "harden membership mutation"), not just when the user directly asked for a permissions change.
