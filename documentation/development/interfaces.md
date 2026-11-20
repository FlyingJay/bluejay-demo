# Development — Interfaces

## Overview

```text
Request a change / App Maker / Projects
      -> dev_queue_items/{key}            (owner's queue item)
      -> claude_jobs/{jobId}              (agent build)
      -> dev_changes/{changeId}           (PR lifecycle, including .preview)
      -> Hosting preview channel pr-<n>   (bluejay-preview-sandbox)
      -> devQueueApprovePreview / devQueueRequestTweak
      -> deploy train -> live
```

## Persisted Firestore interfaces

### `dev_queue_items/{key}` (production)

Fields this entry relies on:

| Field | Meaning |
| --- | --- |
| `state` | `queued`, `building`, `checking`, `in_review`, `merged`, `awaiting_user`, `failed`, `live`, `declined`, `closed` |
| `ownerId` | The requester, or `platform` for platform-owned work |
| `managed` | True for a managed group's item (no preview approval, plain status words) |
| `waiting` | While `awaiting_user`: `{ reason: 'clarification' \| 'preview_approval', askedBy: 'agent' \| 'staff', question, since, deadline, slotReleasedAt, remindAt, remindedAt }`. A preview approval adds `sha` and `previewUrl`; for an artifact result `sha` is the artifact's `versionId`, `previewUrl` its `link`, and `artifact` is set (below) |
| `waiting.artifact` | `{ kind, id, versionId, appId, appName, context, link }`: the published result waiting to be tried (`functions/_artifact_kinds.js`), for example a dashboard version |
| `approval` | `{ sha, by, at }` once the requester approves a preview or an artifact |
| `preview` | The PR's current preview, mirrored from `dev_changes` |

### `dev_changes/{changeId}.preview` (production)

Written by `functions/scripts/sync_dev_change.js` via `functions/_dev_change_preview.js`. Always the same keys: `url`, `channelId` (`pr-<number>`), `expireTime`, `sha`, `current`, `reason`.

### `groups/{groupId}.devQueue.mode`

`pool`, `managed` or `platform`. `managed` turns off the personal queue for the group's members. Read by `shouldShowDevQueueChip` (`packages/dev_queue`), the Wiki's `devQueueAvailable` condition and BlueJI's copy of it.

## Callables used by the Ready to try panel

| Callable | Request | Effect |
| --- | --- | --- |
| `devQueueApprovePreview` | `{ itemKey, sha }` | `awaiting_user` → `in_review`, records `approval`. For an item with `waiting.artifact`, the artifact kind's `approve()` makes the draft current, the item goes to `live`, and its ticket is resolved |
| `devQueueRequestTweak` | `{ itemKey, sha, text, idempotencyKey }` | Starts a follow-up build of kind `tweak` |

`sha` must equal `waiting.sha`; a mismatch is refused (`preview-changed`), and the client asks the requester to open the newer version. An artifact of a kind that is not registered is refused with `failed-precondition`.

## Reducer event: `artifact_ready`

`{ type: 'artifact_ready', jobId?, artifact: { kind, id, versionId, appId, appName, context, link }, afterPr? }`, applied from `building` (the job must match, emitted by `jobEventFor` for a `done` job with `artifact.versionId` and no `prUrl`) or, with `afterPr: true`, from `checking`, `in_review`, `merged`, `awaiting_user` or `live` (sent by `publishPendingArtifact` once the PR is live). A version already waited on or approved changes nothing.

## Preview build and deploy

| Interface | Value |
| --- | --- |
| Build define | `BLUEJAY_ENVIRONMENT=preview` (`kIsPreviewBuild` in `packages/shared_services/lib/app_environment.dart`) |
| Firebase project | `bluejay-preview-sandbox` (`kPreviewSandboxProjectId`), region `northamerica-northeast2` |
| Client config | `config/preview_sandbox/` (sandbox `firebase_options.dart`) |
| Hosting channel | `pr-<number>`, 7-day expiry, deployed by `.github/workflows/deploy.yml` |
| Sandbox backend | Functions, rules and indexes from `main`, deployed by `.github/workflows/deploy-preview-sandbox.yml` |
| Seeding | `functions/_preview_sandbox.js`, `functions/preview_sandbox.js`; collections chosen from `security/collections.json` |
| Seed targets | `previewSeedTargets` returns `[{ groupId, requesterUids, appIds }]`: each ticket group with its requesters and its App Maker requests' `builtAppId`s, plus the reviewer group with every built app |
| Preview app install | `installPreviewApps({ source, target, groupId, appIds })` → `{ installed, missing }` |

## Wiki registry field: `visibleWhen`

`documentation/feature_doc_mapping.json` entries may set `"visibleWhen": "<condition>"`. Known conditions:

| Name | True when |
| --- | --- |
| `devQueueAvailable` | There is an active group whose `devQueue.mode` is not `managed` |

Resolved by `wikiGroupConditions` (`packages/wiki/lib/wiki_group_conditions.dart`) and `WIKI_GROUP_CONDITIONS` (`functions/blue_ji.js`). Unknown names hide the entry.
