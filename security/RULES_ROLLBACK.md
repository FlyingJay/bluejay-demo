# Rules deploy and rollback

How Firestore and Storage rules reach production, and how to undo it
(plans/firestore-rules/IMPLEMENTATION_PLAN.md §8.2, task T4).

## Ultimate fallback: the pre-pipeline permissive rulesets

These were live in production when the pipeline was built (read through the
Rules API on 2026-11-05; released 2025-12-16). They allow any signed-in user
to read and write everything (plus unauthenticated reads of `invitations`).
Rolling back to them restores the exact pre-T4 behaviour: tenant isolation
is gone everywhere, so it is the emergency fallback only, for an outage the
previous generated ruleset doesn't fix. Since stage 7 (2026-11-06) the repo
has no open mode to flip back to; the sources are kept verbatim in
`security/rules-tests/fixtures/live-{firestore,storage}-2025-12-16.rules`.

| Service | Release | Ruleset |
|---|---|---|
| Firestore | `cloud.firestore` | `projects/bluejay-d926f/rulesets/6db881a9-a4ce-4f16-918f-ee895275047b` |
| Storage | `firebase.storage/bluejay-d926f.firebasestorage.app` | `projects/bluejay-d926f/rulesets/d3d5c742-3341-4a30-9450-8e01ded97eba` |

```bash
# From GitHub: Actions -> "Roll back rules" -> Run workflow
#   service: firestore, to: 6db881a9-a4ce-4f16-918f-ee895275047b
#   service: storage,   to: d3d5c742-3341-4a30-9450-8e01ded97eba

# Or locally (GOOGLE_APPLICATION_CREDENTIALS = the admin key, see scripts/firestore_admin/README.md;
# needs `npm ci` in functions/):
node security/tools/rollback_rules.js --service firestore --to 6db881a9-a4ce-4f16-918f-ee895275047b
node security/tools/rollback_rules.js --service storage   --to d3d5c742-3341-4a30-9450-8e01ded97eba
```

Rulesets are kept after a deploy replaces them, so a rollback only re-points
the release: nothing is rebuilt, and it takes effect within about a minute.
Firebase caps a project's stored rulesets, and firebase-tools may delete old
unreleased ones near the cap. If these two are ever gone, their full source
is in the Rules API record above, or re-create it: Firestore is
`match /{document=**} { allow read, write: if request.auth != null; }` plus
`match /invitations/{invitationId} { allow read: if true; }`; Storage is
`match /{allPaths=**} { allow read, write: if request.auth != null; }`.

## Rolling back one deploy

Every deploy records what it replaced:

- the job summary and the `rules-deploy-<sha>-<attempt>` artifact
  (`releases-before.json`) of the "Deploy rules" run;
- Firestore `rules_deployments/{sha}`: `before` (the rollback target; the
  first record for the SHA, never overwritten by re-runs), `after`,
  `status` (`deploying`, `deployed`, `deploy_failed`, `smoke_failed`),
  `smoke` and every run in `runs`.

A failed deploy or smoke test prints the exact rollback commands in the job
summary. To find a target by hand:

```bash
node security/tools/rollback_rules.js --list                      # Firestore, newest first, [LIVE] marked
node security/tools/rollback_rules.js --list --service storage
node security/tools/rollback_rules.js --service firestore --to <rulesetId> --dry-run
node security/tools/rollback_rules.js --service firestore --to <rulesetId>
```

`--to` refuses a ruleset of the other service. After rolling back, run the
core smoke probes: `node security/tools/prod_smoke.js --core-only` (the
"Roll back rules" workflow does this). The per-collection probes are skipped
because the table in the checkout is newer than the released rules.

The other rollback is a revert PR of the change that broke something, then
a deploy (about 5 minutes). Since stage 7 there is no per-collection `open`
switch to flip.

When to roll back (plan §6.4.4): denied outcomes over 0.5% of recorded
ops, any denial in a core flow (login, launcher, access index,
notifications), a spike of denied requests in Cloud Logging, or any
"maximum of 1000 expressions" error from the smoke test.

## Deploying

`.github/workflows/deploy-rules.yml`: the emulator suite (rules-tests.yml)
on the same SHA, a Rules API compile, the IAM preflight, the release record,
`firebase deploy --only firestore:rules[,storage]`, the prod smoke suite and
the outcome record. Its deploy job runs in the `deploy-rules` concurrency
group, one rules deploy at a time; a running deploy is never cancelled.

- **Manual:** Actions -> "Deploy rules" -> Run workflow on `main`.
  `services`: firestore (default), storage or both. `dry_run`: run the tests
  and compile only; nothing is recorded or released.
- **Automatic from the deploy train:** on when the repository variable
  `RULES_AUTO_DEPLOY` is `true` (it is, since 2026-11-06). When main has
  changes to `firestore.rules`, `storage.rules` or `security/**` since the
  `deployed/rules` tag, the train (`deploy-production.yml`, within about 15
  minutes of the merge) calls this workflow, which deploys the services in
  `RULES_AUTO_DEPLOY_SERVICES` (currently `both`; default `firestore` if
  unset). Set `RULES_AUTO_DEPLOY` to anything else to turn it off; Deploy
  Production with `force: rules` still deploys them.

### Storage

`storage.rules` calls `firestore.get()`, which needs the Firebase Storage
service agent to hold `roles/firebaserules.firestoreServiceAgent`. It was
granted before the first enforced Storage deploy (stage 6, 2026-11-06), and
the preflight step fails any Storage deploy if it is ever missing. The
one-time grant (needs project IAM admin), in case it has to be redone:

```bash
gcloud projects add-iam-policy-binding bluejay-d926f \
  --member=serviceAccount:service-691184172506@gcp-sa-firebasestorage.iam.gserviceaccount.com \
  --role=roles/firebaserules.firestoreServiceAgent
```

`storage.rules` is generated from `security/storage_paths.json`; every
family is enforced (stage 6), and the tenant and block families call
`firestore.get()`. `node security/tools/storage_rules_api_smoke.js` confirms
its decisions on the production rules engine (read-only), as
`node security/tools/rules_api_smoke.js` does for `firestore.rules`.

## Prod smoke accounts

`security/tools/prod_smoke_accounts.json` names the two accounts the smoke
suite signs in as (custom tokens minted with the deploy key): a member of
`developer` and a member of `games`, both ACTIVE, neither holding a platform
role, neither in the other's group. The tool checks this before every run
and refuses unsuitable accounts.
