---
name: implement-improve-apps-ticket
description: Look up a bug, feature, or new-app ticket submitted through Improve Apps or App Maker (bug_reports/feature_requests/app_requests, by ID or keyword) and implement it directly, opening a PR for human review, in one pass. Use when the user says things like "implement improve apps ticket <id>", "implement app maker request <id>", "find and fix the improve apps bug about <keyword>", "work through this improve apps ticket", or pastes a ticket title/description from Improve Apps, App Maker, or Dev Pipeline. Writes the resulting PR link straight back onto the ticket doc in Firestore.
---

# Implement Improve Apps Ticket

> **Working the dispatch queue?** Use `implement-claude-job` instead. Every
> producer (including Improve Apps and App Maker) now queues work onto
> `claude_jobs`, and the dispatch workers hand that queue to that skill.
> This skill stays the path for a human who wants a specific ticket
> implemented by ID or keyword, without going through the queue.

Claude implements the ticket in-session and writes the PR link back onto the ticket itself. See `documentation/improve_apps/interfaces.md` for the full ticket schema and the `improveBluejayTriggerTicketJob`/`appMakerTriggerTicketJob` callables (`functions/improve_bluejay.js`, `functions/app_maker.js`) that normally produce it — both build their payload via the shared `functions/_agentic_ticket_dispatch.js`. `implement-feature-improvement` does the same for the improvements backlog; here the source is a live user ticket instead of a forward-looking improvements doc.

Ticket lookups use `scripts/firestore_admin/cli.js` (see [[firebase-admin-access-policy]]: broad reads against production Firestore are fine here, since this runs on the user's own platform-admin credentials — no need to ask before reading). If `GOOGLE_APPLICATION_CREDENTIALS` isn't set or the CLI errors out, fall back to asking the user to paste the ticket's title/description directly rather than blocking.

## Inputs

Parse from the user's request:

- **itemType** (required, or inferable): `bug`, `feature`, or `app` (App Maker new-app request). If not given and you have an itemId, try `bug_reports`, `feature_requests`, and `app_requests` when looking it up.
- **itemId** (if given): the Firestore doc ID — look it up directly.
- **keyword(s) / title fragment** (if no itemId): use to search for the ticket.
- If the user pastes the ticket content directly (no ID needed), skip lookup and go straight to Steps.
- **source** (optional, default `claude`): who's invoking this. A human typing "implement
  improve apps ticket X" in an interactive session is the default `claude`. Automated
  callers state their own identifier explicitly in their task prompt (the dispatch
  workers use `claude-local`; see `manage-ticket-dispatch-worker`), so the write-back
  (step 10) records who did the work and `manage-ticket-dispatch-worker`'s diagnostics
  can attribute it. If you're extending this skill or its callers, keep new automated
  invocations tagged the same way rather than defaulting silently to `claude`. (The
  dispatch workers go through `implement-claude-job`, which shares these source tags and
  the same write-back fields.)

## Unattended invocation

Any `source` other than the default `claude` means nobody is watching this run live —
there's no one to answer a question or read a "stop and tell the user" message. Every
instruction below phrased as "ask/tell the user" means, for an unattended run: **abort
this run cleanly instead of guessing or blocking.** Concretely:
- Release the claim: `cli.js update <collection> <itemId> --data '{"agentClaimedAt":"$DELETE_FIELD"}' --confirm`.
- If the abort is because something's actually wrong (not just "this ticket's already
  handled" or "already in flight" — see step 3, which isn't an error, just a legitimate
  skip), also record why: `cli.js update <collection> <itemId> --data '{"agentDispatchError":"<concise reason, truncate to ~500 chars>"}' --confirm`.
  This is the same `agentDispatchError` field the queueing code writes on failure
  (`functions/_agentic_ticket_dispatch.js`'s `recordQueueFailure`) — the admin UIs
  already render it ("Auto-dispatch failed: ...") with no changes needed on their side.
- Then stop. Do not implement anything or open a PR off an unresolved ambiguity just
  because no one's there to ask — an automated run guessing wrong and shipping it
  unreviewed is worse than an automated run doing nothing and leaving a clear error for
  a human to look at later.
This applies to any failure encountered anywhere in the steps below, not just the two
explicitly called out (scope resolution in step 2, in-flight work in step 3) — a failed
`flutter analyze`/test run you can't fix, a `gh pr create` failure, or anything else that
stops you from reaching step 8 with a real PR open should abort the same way.

## Steps

1. **Look up the ticket.**
   - By ID: `node scripts/firestore_admin/cli.js get bug_reports <itemId>`, and if not found, try `feature_requests`, then `app_requests` (or whichever order the user implied).
   - By keyword: `node scripts/firestore_admin/cli.js search bug_reports --fields description --contains "<keyword>" --where appId=improve-apps --where isClosed=false`, the same against `feature_requests --fields title,description`, and `app_requests --fields title,summary,problem --where appId=app-maker` for App Maker ideas. Run all that plausibly apply unless the user specified a type. If multiple plausible matches come back, show them briefly and ask which one before proceeding — don't guess among several open tickets.
   - Note the collection it came from (`bug_reports` → bug; `feature_requests` → feature; `app_requests` → app) and pull the relevant fields:
     - bug/feature: `title` (bug reports may only have `description`), `description`, for bugs `stepsToReproduce`/`expectedBehavior`/`actualBehavior` (structured reproduction details; absent on older tickets), `relatedAppId`/`relatedAppName`, `appId`, `groupId`, `requesterEmail`/`reporterEmail`.
     - app: `title`, plus App Maker's several small answer fields in place of one `description` — `summary`, `problem` (what it solves), `audience`/`audienceNotes` (who'd use it), `dataToTrack`, `inspiration`, `importance`, `additionalNotes` — and `submitterEmail`/`submitterName`. There is no `relatedAppId`: an `app_requests` ticket is always a brand-new app idea, never a feature on an existing one (see `create-bluejay-app`'s scope note).
   - **Claim it before doing real work**: if `agentDispatchedAt` is already set on the doc, another run already handled (or is handling) this ticket — stop and tell the user rather than duplicating work. Otherwise, write `agentClaimedAt: "$SERVER_TIMESTAMP"` via `cli.js update <collection> <itemId> --data '{"agentClaimedAt":"$SERVER_TIMESTAMP"}' --confirm` as a lightweight best-effort claim (not a real transaction — fine for this volume) before proceeding past step 3.

2. **Resolve scope.**
   - For `bug`/`feature`: look up `appId` (prefer `relatedAppId` if set — that's the app the ticket is actually about, vs. `appId: improve-apps` which is just the submission surface) in `documentation/feature_doc_mapping.json`. Note its `documentationSlug`, `class`, and `watch` rules — these bound the legitimate scope of code you may touch. If it can't be resolved, ask the user rather than guessing scope.
   - For `app`: there's no existing feature to resolve — this is net-new. Read the `create-bluejay-app` skill and follow its scaffolding conventions in step 5 below instead of a `watch`-scoped fix. Per that skill, the package gets a `bluejay_app.json` manifest; step 9 says which group it lists and registers it.

3. **Check for existing in-flight work.** Run `gh pr list --search "<itemId or a few title keywords>" --state open` and check open branches for anything already addressing this ticket, so you don't duplicate work a prior run or a human already started. If something's clearly in flight, stop and tell the user (and don't leave a dangling `agentClaimedAt` — clear it: `cli.js update <collection> <itemId> --data '{"agentClaimedAt":"$DELETE_FIELD"}' --confirm`).

4. **Read context.** For `bug`/`feature`, under `documentation/<slug>/`: `developer.md` and `interfaces.md` for current behavior, plus `improvements-*.md` if the ticket overlaps a known improvement (mention the overlap in the PR body if so). For `app`, read `packages/calendar/` as the reference implementation `create-bluejay-app` points at.

5. **Implement it.**
   - `bug`/`feature`: scoped to the ticket's description and the feature's `watch` paths. Use the ticket description as the source of truth for scope and expected behavior. Don't scope-creep beyond the ticket unless a fix is tightly coupled.
   - `app`: follow `create-bluejay-app`'s steps end to end (data model, `ScopedCollection`-backed service layer, screens, routing, tests, and — only if truly unavoidable — `firestore.rules`), using the ticket's `summary`/`problem`/`dataToTrack`/etc. as the app's spec in place of the interactive Q&A that skill normally starts with. Derive the `appId` slug from `title`; if it's ambiguous, state your chosen slug explicitly in the PR description rather than asking (nobody's there to answer).
   - UI changes use bluejay_design (`packages/bluejay_design/README.md`); in an app already on it, don't add raw colours, `TextStyle(fontSize: ...)` literals or a `*_theme.dart` (`scripts/check_design_tokens.js` fails CI on them). A request to restyle or redesign an app follows the `polish-app-ui` skill. UI text follows the brand guide's voice and product-writing rules (CLAUDE.md, "Brand and design").
   - Either way: if the ticket is ambiguous, state your interpretation and assumptions explicitly in the PR description rather than guessing silently.

   **Decide who the change is for first**, per `CHANGE_REQUEST_SCOPE.md`: every group that uses the app by default (always for bug fixes); behind a per-group setting in `functions/app_group_settings.json` — on for the requesting group, unchanged for everyone else — only when it's client-specific or would change behavior other groups rely on. Never branch on a literal group id.

6. **Create a feature branch** off latest `main`: `git fetch origin main && git checkout -b claude/improve-apps-ticket/<itemType>-<short-desc> origin/main`.

7. **Run `scripts/ci/local_check.sh`** (add `--rules` if it prints the rules notice) and fix everything it reports before pushing, so CI passes on the first run (CLAUDE.md, "Draft PRs, local checks and PR size"). If a step can't run because a tool is missing (it says so), note that in the PR body rather than failing the task.

8. **Commit, push, and open a PR** via `gh pr create`. When this runs unattended (the ticket-dispatch worker), open it ready (no `--draft`) so CI runs and people see the result; in an interactive session, open a draft and `gh pr ready` once step 7 passes. PR body must start with the scope line and then the release-note line from `CHANGE_REQUEST_SCOPE.md` ("And a release note" — `none` if users won't notice the change, as for a purely internal fix) (e.g. **Scope: Globex only, behind setting `garagePricingBySize`** — reason), and must include:
   - Ticket type, itemId, collection, and a summary of what was implemented and why it addresses the ticket.
   - Submitter name/email and any deep link, if available — for traceability back to the ticket.
   - Any assumptions made due to ticket ambiguity.
   - A note if local validation or the Firestore lookup was skipped due to missing tooling/credentials.
   - The ticket marker `<!-- bluejay-ticket:<itemType>:<itemId> -->` (e.g. `<!-- bluejay-ticket:bug:abc123 -->`), so `.github/workflows/dev-change-lifecycle.yml` links the PR to the ticket: reviewers are pinged when it's ready, and once it's merged and deployed the ticket is marked fixed/completed/shipped and the submitter is notified.
   - Leave the PR open for human review — **never merge it yourself**.

9. **For `app` tickets only: create the app's launcher entry now.** The scaffold's
   `packages/<slug>/bluejay_app.json` (see `create-bluejay-app`) must have
   `"installInGroups": ["<groupId>"]`, where `<groupId>` is the app request's own
   `groupId`: the group that asked for the app is the group that gets it. Never add
   `developer` (or any other group) to it. Create the entry without installing it
   anywhere:
   ```
   node scripts/firestore_admin/sync_app_manifests.js --app <slug> --create-only            # dry run
   node scripts/firestore_admin/sync_app_manifests.js --app <slug> --create-only --confirm
   ```
   `--create-only` creates `apps/<slug>` and defers the install into the requester's
   group to the deploy, so nobody gets a launcher tile for code that isn't live yet. It
   still checks the install against the group's security tier and reports a refusal.
   Pick a reasonable icon/colors (check existing `apps` docs or `packages/*/lib/` for
   conventions if unsure): cosmetic, easily fixed later in App Manager, don't block on
   perfecting it. If the sync refuses (an invalid manifest, or the group's security-tier
   requirements), or the dry run shows anything but creating `apps/<slug>` with one
   deferred install into the requester's group, note that plainly in the PR description
   and move on: don't force it or work around the refusal.

   Once it succeeds, record the appId on the request:
   `node scripts/firestore_admin/cli.js update app_requests <itemId> --data '{"builtAppId":"<slug>"}' --confirm`.
   With `builtAppId` set, the PR preview installs the app into the sandbox copies of the
   requester's group and the `developer` group (`installPreviewApps` in
   `functions/_preview_sandbox.js`), so the requester and reviewers can try it before
   merge. After the PR is merged and deployed, the deploy's app registration installs it
   into the requester's group (subject to that group's security-tier minimum), and the
   dev change lifecycle (`functions/_dev_changes.js`) marks the request shipped and
   notifies the submitter so they can try it. If `builtAppId` is missing, the reviewers
   are asked to finish it by hand.

10. **Write the result back onto the ticket doc**:
    ```
    node scripts/firestore_admin/cli.js update <collection> <itemId> --data \
      '{"agentDispatchedAt":"$SERVER_TIMESTAMP","agentDispatchSource":"<source>","agentClaimedAt":"$DELETE_FIELD","agentDispatchError":"$DELETE_FIELD","prUrl":"<pr url>","prState":"open","prNumber":<pr number>,"prSyncedAt":"$SERVER_TIMESTAMP"}' \
      --confirm
    ```
    `<source>` is whatever this run's `source` input resolved to (`claude` or
    `claude-local` — see Inputs). Clearing `agentDispatchError` here too, in case a prior
    failed attempt on this same ticket left one behind. Do this only after the PR is
    actually open — `agentDispatchedAt` being set is read by the admin UIs (and this
    skill's own claim check) as "this ticket is fully handled," matching the
    invariant documented in `functions/_agentic_ticket_dispatch.js` above
    `recordQueueFailure`. If the PR fails to open, this is a failure — follow
    "Unattended invocation" above (or, if a human's present, tell them) rather than
    silently leaving no trace.

11. **Report back** to the user: PR URL, one-line summary of what was implemented, and which ticket it addresses. For `app` tickets, also note whether the registration (step 9) succeeded.

## Constraints

- One ticket per run.
- Never auto-merge.
- Stay inside the target feature's `watch` scope from the mapping file unless a fix is tightly coupled (bug/feature), or `create-bluejay-app`'s scope boundaries (app).
- If Firestore rules, Storage rules, or billing-sensitive code are touched, flag that explicitly in the PR description for extra reviewer attention.
- Ticket writes are limited to the dispatch/claim/error/PR-link bookkeeping fields (`agentClaimedAt`, `agentDispatchedAt`, `agentDispatchSource`, `agentDispatchError`, `prUrl`/`prState`/`prNumber`/`prSyncedAt`) in step 1, "Unattended invocation", and step 10 — never close a ticket, change its status, or edit its title/description/content. Leave that to the human reviewing the PR.
- The registration in step 9 (`app` tickets only) is limited to `sync_app_manifests.js --app <slug> --create-only` for the app you built, with `installInGroups` exactly `["<the request's groupId>"]`: a new `apps/{appId}` doc, installed nowhere until the deploy. Never list another group, never run it without `--create-only`, and never write an existing app's `apps` doc.
