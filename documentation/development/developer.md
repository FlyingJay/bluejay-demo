# Development — Developer Guide

## Purpose and boundaries

This entry documents the path a change request takes from a person's development queue to production, and the preview environment requesters and reviewers use to try a change before it merges. It is a platform-wide (`documentationAudience: "global"`) entry with no owning app. Its registry entry sets `"visibleWhen": "devQueueAvailable"`, so members of managed groups (`groups/{id}.devQueue.mode == 'managed'`), who have no personal queue, don't see it in the Wiki or get it from BlueJI.

The design history lives in `plans/development-queue/` (`OVERVIEW.md` and the phase designs). The developer-facing consoles have their own entries: Dev Pipeline (`dev_pipeline`), Review Desk (`review_desk`), Queue Management (`queue_management`) and Dev Workers (`dev_workers`).

## Source map

| Area | File(s) |
| --- | --- |
| Queue chip, queue screen, Ready to try panel | `packages/dev_queue/lib/` (`dev_queue_chip.dart`, `dev_queue_screen.dart`, `dev_queue_widgets.dart`, `dev_queue_sheets.dart`) |
| Client models, status vocabulary and pure helpers | `packages/dev_queue/lib/dev_queue_models.dart`, `dev_ticket_status.dart`, `dev_queue_logic.dart` (`shouldShowDevQueueChip`) |
| Callable client | `packages/dev_queue/lib/dev_queue_service.dart` |
| Function exports | `functions/dev_queue.js` |
| Model and reducer (states, status labels, slot rules, preview approval) | `functions/_dev_queue_model.js` |
| Firestore transactions | `functions/_dev_queue.js` |
| Callable handlers | `functions/_dev_queue_callables.js` |
| Scheduler pass | `functions/_dev_queue_scheduler.js` |
| Sizing | `functions/_dev_queue_sizing.js` |
| Item notifications | `functions/_dev_queue_notify.js` |
| Artifact results (a request whose result is data, such as a dashboard, with no PR) | `functions/_artifact_kinds.js` |
| Preview capture for a PR (`dev_changes.preview`) | `functions/_dev_change_preview.js`, written by `functions/scripts/sync_dev_change.js` |
| Preview build and deploy | `.github/workflows/deploy.yml` |
| Sandbox backend deploy | `.github/workflows/deploy-preview-sandbox.yml` |
| Sandbox seeding | `functions/_preview_sandbox.js`, `functions/preview_sandbox.js` |
| Sandbox client config | `config/preview_sandbox/`, `packages/shared_services/lib/app_environment.dart` |
| Preview ribbon | `lib/ui/widgets/preview_build_ribbon.dart` |

## Lifecycle

Items live in `dev_queue_items/{key}`. The internal states are `queued`, `building`, `checking`, `in_review`, `merged`, `awaiting_user`, `failed`, `live`, `declined` and `closed`; `live`, `declined` and `closed` are terminal. `statusFor` in `_dev_queue_model.js` maps them to the user vocabulary (Up next, Waiting for your developer agent, Building, Checking, Waiting on you, Ready to try, Final review, Live, Declined, Closed). Managed groups' submitters see only `MANAGED_STATUS_CODES` (Received instead of the queue words). `CLOSED_AS_CLOSED_REASONS` lists the close reasons that read Closed rather than Declined; it includes `not_ready` (`NOT_READY_REASON` in `_dev_queue.js`, "Not ready to build yet"), which Review Desk's `reviewDeskMarkNotReady` and the staff close dialogs use for a request that is wanted later but needs more definition. Reopening its ticket queues it again. `withNote` appends a staff note to a reason's `closedReason`, and `closeTicketPatch` writes it as an app request's `declineNote`.

1. **Intake.** Improve Apps, App Maker and Projects tickets enqueue an item for their owner. Managed groups' items are held for triage until `devQueueSendToPipeline`.
2. **Scheduling.** `devQueueScheduler` (every minute) and `devQueueKick` grant slots from the owner's pool (personal, group `pool`, `managed`, `platform`, `expedite`) and dispatch a `claude_jobs` job.
3. **Build and checks.** `devQueueOnJobWritten` and `devQueueOnDevChangeWritten` follow the job and the PR (`dev_changes`) through `building` → `checking` → `in_review` → `merged`.
4. **Ready to try.** When the PR's preview is current (`preview.current` with a `sha`), `previewApprovalApplies` moves a bug or feature item owned by a person (never managed, never platform-owned) to `awaiting_user` with `waiting.reason: 'preview_approval'`. The requester calls `devQueueApprovePreview` (records `approval.sha`, back to `in_review`, shown as Final review "Approved after trying it") or `devQueueRequestTweak` (a follow-up build). A newer push changes `waiting.sha` and the client shows "There is a newer version to try".
5. **Waiting timeout.** A `waiting` deadline is `waitingTimeoutBusinessDays` (default 2) business days in the platform time zone; past it the slot is released (`waiting.slotReleasedAt`) and the item stays in `awaiting_user`.
6. **Live.** The deploy train ships the merge and the PR's `dev_changes` record reaches `live`, which closes the item as `live`.

### Artifact results

Some requests produce validated data instead of a pull request; a dashboard spec is the first such kind, registered in `functions/_artifact_kinds.js`. A job completed through `publishArtifact` carries `artifact` and no `prUrl`, so `jobEventFor` emits `artifact_ready` and the reducer moves the item from `building` to `awaiting_user` with `waiting.reason: 'preview_approval'`, `waiting.sha` set to the artifact's `versionId`, and `waiting.artifact` describing where the result lives. The item keeps its slot like any Ready to try item. A job that also needs code attaches the artifact as `artifactPending` and opens a normal PR; once that PR is live, `publishPendingArtifact` sends `artifact_ready` with `afterPr: true` and the item waits without a slot, and `pr_live` leaves an item already waiting on an artifact alone.

Approving an artifact (`devQueueApprovePreview` with the `versionId` as `sha`) runs the kind's `approve()` in the same transaction to make the draft current, moves the item straight to `live` (there is no Final review) and frees the slot. The ticket is then resolved through `resolveTicketAsSystem` ("Your <app> change is live."). The item's `previewUrl` and the Ready to try notification point at the app holding the result (for a dashboard, the Dashboards app at `?dashboard=<id>`), with the artifact's web link as the fallback. A kind may also declare a mirror record (the dashboard's own status) that the queue's commit transaction keeps in step with the item, the same way it updates the ticket's `devStatus`.

## Preview environments

### Where previews run

PR previews run against a separate Firebase project, **`bluejay-preview-sandbox`**, in `northamerica-northeast2` like production. `.github/workflows/deploy.yml` builds the web app for a PR with `BLUEJAY_ENVIRONMENT=preview`, installs the sandbox's `firebase_options.dart` from `config/preview_sandbox/`, and deploys it to a Hosting preview channel `pr-<number>` on the sandbox project (7-day expiry). `app_environment.dart` exposes `kIsPreviewBuild` and `kFirebaseProjectId`; preview builds talk only to the sandbox's Firestore, Auth, Storage and Cloud Functions. Every screen of a preview build shows the **Preview** corner ribbon.

`functions/_dev_change_preview.js` (`PREVIEW_SITE`) names the Hosting site the sync script reads preview channels from. It has to match the project deploy.yml deploys previews to, or `dev_changes.preview` (and so the Try it, Open preview and Ready to try flows) loses the URL.

HTTP functions accept only their own project's origins (`functions/_web_origins.js`): the sandbox accepts its Hosting site and preview channels, and production never accepts a sandbox page.

### The sandbox backend

The sandbox's Cloud Functions, Firestore rules and indexes, and Storage rules are deployed from `main` by `.github/workflows/deploy-preview-sandbox.yml`. A preview therefore runs the PR's client code against `main`'s server code.

No server secrets are configured in the sandbox project. Everything that reads one through `readServerSecret()` (Stripe billing, SMTP/SES email, Twilio SMS, Gemini AI, and similar integrations) finds it missing and takes its existing "not configured" path, so nothing in a preview charges a card, sends an email, text or push notification, or calls an AI model.

### Seeding the requesting group

The sandbox holds copies, never live data. When a preview is opened for a request, the seeding code in `functions/_preview_sandbox.js` / `functions/preview_sandbox.js` copies the requesting group into the sandbox:

- the group's documents in every group-scoped collection, as listed in the policy table `security/collections.json`
- the group doc and its members' `users` docs and Auth accounts (password hashes included, so email/password sign-in works with the member's usual password)
- each linked ticket's requester (`requesterId`, else `creatorId`), even one who has since left the group. A group seeded within the last day is seeded again if a requester is missing from its copy.
- shared catalog collections, such as `apps`
- any new app an App Maker request on the PR built (the ticket's `builtAppId`). A new app is installed in production only once it ships, so after the group's seed (whether or not the seed ran this time) `installPreviewApps` copies the app's `apps/{appId}` doc from production, adds it to the copy's `installedApps` (and `availableApps` for a private app, using `availabilityGrants` as a production install does), and rebuilds the access index of every member in the group's seed marker. An app with no production `apps` doc is skipped and logged.

Every open preview also seeds the reviewer group (`REVIEWER_GROUP_ID`, the `developer` group behind Review Desk), so reviewers can sign in to any preview, including one with no linked ticket or only platform-owned tickets. The reviewer group's copy gets every app the PR's App Maker requests built.

Cloud Functions deploy only `functions/`, so the seed plans from `functions/_preview_sandbox_tables.json`, a copy of the policy tables generated by `security/generate_preview_sandbox.js` (run `node security/generate.js`). `functions/_deploy_bundle.test.js` fails if deployed functions code requires or reads a file outside `functions/`. A seed that fails at any step marks its group's marker in `preview_sandbox_seeds` as `failed` with the error.

Configuration for the sandbox lives in `config/preview_sandbox/`. Copies can be reset or refreshed at any time, and nothing written in the sandbox is copied back to production.

### Known gaps

1. **Server changes in a PR are not in its preview.** Cloud Functions, Firestore rules, Storage rules and indexes changed by the PR are not deployed to the sandbox; the preview runs them as they are on `main`. A PR whose feature depends on new server behaviour can look incomplete in its preview. The plan for closing this is `plans/preview-sandbox/PR_BACKEND_PREVIEWS.md`.
2. **Google sign-in is not enabled in the sandbox.** Email/password sign-in works with the member's usual password. Choosing Google in a preview build shows a notice (`FederatedSignIn.previewUnavailable`, on while `kPreviewFederatedSignInEnabled` in `app_environment.dart` is false), so a member who only signs in with Google can't sign in to a preview. Password reset doesn't help there: it sends email through the server, and the sandbox has no email.
3. **Platform admins see more than one group's copy.** The sandbox holds a copy of every group with an open preview. Platform-admin accounts in the sandbox keep their elevated roles, so they can see all of those copies, the same way they can see every group in production.
4. **Server-built public links point at production.** Links the app builds itself use `publicLinkHost` (`packages/shared_services/lib/cloud_functions.dart`), which is the preview's own host in a preview build, so sales pages, storefronts, portal, form and signature links and calendar feeds copied in a preview open the preview. The `public-link-host` rule in `scripts/check_gateways.js` keeps new links on it. Links the server builds (`publicUrl` in `functions/_function_regions.js`: RSVP and broker-answer links) still use `https://bluejay.gg`; they only go out in emails, which the sandbox doesn't send.
5. **Push notifications are off.** Preview builds pass no `FCM_VAPID_KEY` and install a no-op `firebase-messaging-sw.js` (`config/preview_sandbox/`).

## Wiki and BlueJI visibility

`documentation/feature_doc_mapping.json` entries may set `visibleWhen` to the name of a group condition. The Wiki (`packages/wiki/lib/wiki_group_conditions.dart`, applied in `WikiVisibility.computeAllowedSlugs` and `resolveVisibleSlugs`) and BlueJI (`WIKI_GROUP_CONDITIONS` in `functions/blue_ji.js`, applied in `isCandidateEntry`) resolve the name against the active group's document. An unknown name, or no active group, hides the entry. `devQueueAvailable` is false only for `devQueue.mode == 'managed'`, mirroring `shouldShowDevQueueChip`. `functions/blue_ji.test.js` and `packages/wiki/test/wiki_group_conditions_test.dart` check that every `visibleWhen` used in the registry is known on both sides.
