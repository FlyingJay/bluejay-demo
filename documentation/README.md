# Bluejay Launcher Documentation Hub

This directory is the canonical home for launcher feature documentation.

## Where to Find Documentation

- In the repository: `documentation/<feature-or-app-name>/`
- In GitHub: browse the same path in the `main` branch

The folder name is predictable and maps to the package/feature name (for package-backed apps, this is the package slug from `packages/<slug>`).

## Required Files Per App / Feature

Each app/feature folder must contain these eight files, plus `guest.md` for apps that admit guests (see below):

1. `user.md`
   - User-facing documentation
   - What the feature does, how to use it, setup/configuration, workflows, best practices, common mistakes, and practical examples
   - Written for people using the app: the steps they take in the product's screens, with no code blocks, code syntax or programming terms

2. `developer.md`
   - Technical/developer documentation
   - Architecture, data flow, key services/classes, data structures, integration points, operational concerns, and implementation details for experienced developers

3. `interfaces.md`
   - Interface documentation for all feature data structures in and out
   - Comprehensive request/query/response/persistence/update payload structures in JSON or other precise schema form

4. `timeline.md`
   - Current-state timeline for merged changes
   - Append-only historical entries for merged PRs (no deletions)

5. `improvements-security.md`
   - Forward-looking security improvements only
   - Risks related to authorization, data access scope, security rules, and sensitive-data handling

6. `improvements-performance.md`
   - Forward-looking performance improvements only
   - Query/API efficiency, response latency, rate limits, and cost/billing optimizations

7. `improvements-ux.md`
   - Forward-looking UX improvements only
   - Simplicity, clarity, reliability, and streamlined user flows

8. `improvements-features.md`
   - Forward-looking net-new feature improvements only
   - New capability ideas that improve usefulness or profitability

### `guest.md` for apps that admit guests

Some apps let people outside the group in. They come in two kinds:

- **Visitors** open an embeddable app (`apps/{id}.isEmbeddable`) from a shared link, without a group account.
- **Clients** use an app through the group's client portal (`apps/{id}.clientPortal`).

These apps set `"guestAudience": "visitors"` or `"clients"` on their entry in `feature_doc_mapping.json`, and their folder adds `guest.md`. It is the guide those guests read from the app's help tab in place of `user.md`. It covers only what they see and can do: how they get in, what's on screen, step-by-step tasks, what they can't do (in a line each, pointing them to the group), and troubleshooting for real failure modes. It leaves out member and admin features, uses plain language, and runs shorter than `user.md`. Members can read it in Wiki under **Guest**.

Two checks keep these in step:

- `scripts/docs/guest_docs.test.js` (CI) fails when an app with a `guestAudience` has no `guest.md`, or a `guest.md` sits in a folder without one.
- `node scripts/docs/guest_docs.js audit-prod` compares `guestAudience` with the production `apps` flags and lists any app that admits guests without a declared audience, or the reverse. The `audit-app-documentation` skill runs it.

## How Documentation Is Generated and Updated

Documentation is updated once per night, in one PR covering everything merged that day:

1. Each deploy train (`.github/workflows/deploy-production.yml`) runs `.github/workflows/agentic-docs-on-main.yml` as its `docs_pending` target. It matches the files each commit merged since the `deployed/docs_pending` tag changed against the `watch` rules in `feature_doc_mapping.json` (`scripts/docs/record_pending_entries.js`) and records one entry per commit and touched feature in `documentation/.pending_doc_changes.json`, in a single commit. It starts no agent.
2. A scheduled Claude Code session runs the `nightly-docs-batch` skill (`.claude/skills/nightly-docs-batch/SKILL.md`). It triages each pending feature:
    - `trivial`: test-only, generated or comment-only changes get a scripted `timeline.md` line and no agent.
    - `incremental`: one agent updates only the affected sections from the diffs.
    - `full`: one agent audits the whole folder against the code. This mode is used for new or incomplete folders, large diffs, folders whose last full audit is over 30 days old, and a nightly rotation of up to 3 features.
    - A merge that touches 8 or more features gets one section in `platform_changes/developer.md`, and each affected feature's docs link to it.
    - For apps with a `guestAudience`, agents also keep `guest.md` current, and the batch's file check requires it.
3. `timeline.md` entries and the generated **Data and permissions** block in each `developer.md` (rendered from `security/collections.json` and `security/storage_paths.json`) are written by script. The logic lives in `scripts/docs/nightly_docs_batch.js`.
4. The batch opens one docs PR, and `.github/workflows/auto-merge-docs-pr.yml` merges it once checks pass. Merging records the processed entries in `documentation/.docs_batch_processed.json`, and the next deploy train prunes them from the pending log.

The `audit-app-documentation` skill sweeps the whole repo for apps that were never registered or have incomplete folders.

## Authoring Standard

For every app/feature, docs should be:

- accurate to current code behavior
- complete for both first-time users and experienced developers
- specific, practical, and actionable
- continuously updated after meaningful feature changes
- deliberately comprehensive and wide-ranging, favoring depth and thoroughness over minimal brevity when tradeoffs are required

### Keep each `user.md` about its own app

Groups install different sets of apps and come from different industries, so a user guide has to stand on its own:

- Describe this app's own screens, settings and behavior. When it integrates with another app, mention that briefly, say what happens if the other app isn't installed, and link to that app's guide rather than re-explaining it.
- Use industry-neutral examples unless the app itself is built for one industry (the insurance product apps, for example). Generic apps such as the Warehouse suite, Cash Register or Payments get generic examples.
- Don't name particular customer groups or organizations.
