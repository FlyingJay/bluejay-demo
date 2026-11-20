---
name: run-improvement-sprint
description: Stand up a temporary "dev team" of parallel agents, each assigned a distinct bluejay app/feature, that independently run implement-feature-improvement and each open their own PR — producing a batch of N ready-for-review PRs in one dispatch. Optionally scope the candidate pool to one bluejay group's installed apps (via Firestore) instead of the whole catalog, for improvements targeted at a specific customer/org. Use when the user says things like "put together a dev team and knock out improvements", "spin up agents to improve 10 features", "run an improvement sprint across N apps", "fan out the improvement backlog", "pick some features and open a PR for each of their top improvements", or "improve the apps installed in <group>". Fans out implement-feature-improvement across many features at once rather than one at a time; each spawned agent is otherwise an ordinary run of that skill and inherits all of its rules (one improvement per PR, never auto-merge, stay in scope).
---

# Run Improvement Sprint

Orchestrates a batch of `implement-feature-improvement` runs, one per selected app/feature, each in its own isolated agent so they can work concurrently without stepping on each other's git state. End state: N open PRs, each independently reviewable, each following the same PR-body contract as a solo `implement-feature-improvement` run.

This skill only *selects features and dispatches agents*. It never edits code, reads improvement docs, or touches git itself — that's entirely the spawned agents' job via the sub-skill.

## Inputs

Parse from the user's request:

- **count** (default 10): how many features to assign. Cap at 15 without explicit confirmation — a bigger fan-out means more concurrent PRs, more review burden, and more compute; if the user asks for more than 15, confirm they actually want that many before proceeding.
- **selection mode** (default `random`):
  - `random` — sample `count` features at random from the candidate pool.
  - `first` — take the first `count` features from `documentation/feature_doc_mapping.json`'s list order.
  - **explicit list** — the user names specific apps/features; use exactly those (skip the candidate-pool filtering below except the in-flight check).
- **group** (optional): a bluejay `groups/{groupId}` name or ID (e.g. "Initech", "Games", "Northwind"). When given, narrows the candidate pool to only the apps actually installed in that group *before* applying `random`/`first`/explicit selection — see step 1a. Use this when the user wants improvements targeted at a specific customer/org rather than the whole catalog.
- **priority** (optional, default `impactful`): passed straight through to each sub-agent's `implement-feature-improvement` call — `impactful` or `easy`. Same meaning as in that skill.

## Steps

1. **Build the candidate pool.** Load `documentation/feature_doc_mapping.json`. Filter to entries with `"documentationAudience": "app"` — this excludes the handful of `developer`/`global` meta-docs entries, which aren't standalone features suited to this flow. If the user gave an explicit list instead, resolve each named feature against this file the same way `implement-feature-improvement` does (fuzzy match, confirm if ambiguous).

   **1a. If a `group` was given, narrow the pool to that group's installed apps.** Look the group up in production Firestore with the read-only admin CLI (see `scripts/firestore_admin/README.md`, credentials are a one-time local setup already documented there): `node scripts/firestore_admin/cli.js query groups --where groupId=<id>` (or `--limit 25` and match by `name` client-side if the user gave a display name rather than an ID — group IDs are lowercase slugs like `initech`, `northwind`). Take that doc's `installedApps` array and intersect it (by `appId`) with the `documentationAudience: "app"` pool from step 1. If the group can't be found, or its `installedApps` doesn't intersect with any known feature (stale/legacy app IDs happen — the array has been observed to contain mixed-case or renamed entries alongside current ones), tell the user and ask them to confirm the group or fall back to the full catalog rather than silently returning zero candidates.

2. **Exclude in-flight work.** Run `gh pr list --state open --search "feature-improvement"` (and eyeball branch names for `claude/feature-improvement/*`) to find features that already have an open improvement PR. Drop those from the candidate pool for `random`/`first` selection so the sprint doesn't duplicate work. If the user explicitly named a feature that's already in flight, tell them instead of silently swapping it out.

3. **Select the features** per the chosen mode, deduplicated — never assign the same feature to two agents in one sprint.

4. **Show the selected list to the user before dispatching.** This kicks off N concurrent agents that will each write code and open a PR — real, visible, moderately hard-to-reverse actions (closing an unwanted PR is cheap, but the compute and review burden aren't). List the chosen features and the priority mode, and get a go-ahead before spawning. Skip this only if the user's original request already pinned down the exact list and count explicitly (e.g. they named all 10 apps themselves).

5. **Dispatch one agent per selected feature, in parallel, in a single message** (all `Agent` tool calls batched together, `run_in_background: true`). For each agent:
   - `subagent_type: "claude"`.
   - **`isolation: "worktree"` is mandatory, not optional.** All agents share this same repo checkout; without a dedicated worktree per agent, concurrent `git checkout -b` / commits from parallel runs will race and corrupt each other's branches. Each agent needs its own isolated copy.
   - The prompt must be self-contained (the agent has no memory of this conversation): tell it plainly to invoke the `implement-feature-improvement` skill via the Skill tool with that specific feature's `documentationSlug`/`name` and the chosen priority mode, then report back the resulting PR URL and a one-line summary of what it implemented. Tell it the run is unattended and must end with the PR marked ready, and to run `scripts/ci/local_check.sh --jobs 2` so N agents' Flutter checks don't swamp the machine (CLAUDE.md, "Draft PRs, local checks and PR size"). Don't re-explain the sub-skill's internal steps — it already knows them; just hand it the feature and priority.

6. **Do not poll or wait.** Once all agents are dispatched, tell the user how many agents are running and on which features, and that each will report a PR URL when it finishes. Task-completion notifications arrive automatically as each agent finishes — do not sleep, poll `gh pr list`, or fabricate results in the meantime.

7. **As agents report back**, track which features succeeded, which failed, and their PR URLs. Once all have reported (across however many turns that takes), give the user one consolidated summary: a table or list of feature → PR URL, plus any features that failed (e.g. sub-skill found in-flight work mid-run, missing docs, no viable improvement found) so the user can decide whether to retry those separately.

## Constraints

- Never spawn agents without `isolation: "worktree"` — this is the one detail that makes parallel dispatch safe instead of racy.
- Never assign the same feature to more than one agent in a single sprint.
- Inherit every constraint from `implement-feature-improvement` (one improvement per PR, never auto-merge, stay within the feature's `watch` scope, flag Firestore/Storage/billing-sensitive changes) — the dispatch prompt should point the agent at that skill rather than restate its rules, but you're still responsible for not undermining them (e.g. don't tell an agent to batch multiple improvements to save time).
- If a spawned agent reports back that it found in-flight work or couldn't find a viable improvement, don't automatically dispatch a replacement feature without checking with the user first — silently growing the sprint defeats the point of showing the selected list up front.
- When summarizing results back to the user, call out any PR that touches `firestore.rules`, Storage rules, or per-document ownership/membership logic as needing closer review than the rest of the batch — `implement-feature-improvement` inherits `change-firestore-permissions`'s guardrail against bespoke per-app rules carve-outs, but a fan-out of N concurrent agents is exactly the situation where a human is least likely to catch a subtle one-off before several PRs have already landed.
