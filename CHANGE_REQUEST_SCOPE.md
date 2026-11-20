# Deciding who a change is for

Any user of any app, in any group, can request a change to that app, and an
agent implements it in a PR. Every group runs the **same code** for an app, so
every implementation has to answer one question before it's written: *should
this change apply to every group that uses the app, or only to the group that
asked?* The agent proposes an answer; the developer reviewing the PR makes the
final call.

## Default: every group

Ship to every group that uses the app when the change is plausibly useful to
them, which is most of the time:

- **Bug fixes: always all groups.** A bug in shared code is a bug for
  everyone.
- **Features: all groups** when other groups would likely benefit, or at least
  not mind — a new option, a better screen, a missing field, an export.
- When unsure, lean toward all groups and say so in the PR; it's easy for the
  reviewer to ask for a setting instead.

## Behind a per-group setting: only when it would surprise others

Put the change behind a per-group setting — **on for the requesting group,
existing behavior for everyone else** — when it is:

- specific to how that client works (their rating rule, their wording, their
  workflow step, their branding);
- a change to behavior other groups rely on (a different default, a stricter
  validation, a removed option, a different price);
- in tension with another group's request for the same app — both get a value
  of the same setting rather than one winning.

### How (never branch on a group id)

1. Declare the setting in `functions/app_group_settings.json` under the app's
   entry (add the entry if the app has none):
   `"<camelCaseKey>": { "type": "boolean" | "number" | "string" | "enum",
   "default": <value that preserves today's behavior>, "label": "...",
   "description": "...", ... }`. The default must keep every other group
   exactly as it is. `functions/_app_group_settings.test.js` fails CI on a
   malformed entry.
2. Read it in the app through `AppGroupSettings` in
   `packages/shared_services/lib/app_group_settings.dart` — defaults come from
   the JSON, never from the call site:
   ```dart
   StreamBuilder<AppGroupSettingsValues>(
     stream: AppGroupSettings.watch(APP_ID), // active group; re-subscribes on switch
     builder: (context, snap) {
       if (!snap.hasData) return const SizedBox.shrink(); // wait; don't guess a default
       final bySize = snap.data!.boolValue('garagePricingBySize');
       ...
   ```
   (`AppGroupSettings.get(APP_ID)` for a one-off read; `numValue`/`stringValue`
   for other types.) Server-side, read the group's doc at `settingsDocPath`
   and pass its `settings` through `resolveValues` in
   `functions/_app_group_settings.js`.
3. Turn it on for the requesting group as data, not code: say in the PR body
   that a group admin (or the reviewer) should enable it under **App settings**
   in the launcher's profile menu (or Groups → group → App Settings for
   platform admins), which calls `appGroupSettingsUpdate`.

Never write `if (groupId == '<some group>')` or any other literal group id
into app or function code: that's a fork that nobody can see, review, or turn
on for the next client who wants the same thing.

## When the platform can't do it yet

Some requests need a capability Bluejay doesn't have yet: a connection to the
customer's own tools (see `plans/data-connections/DESIGN.md`), or something
hyper-specific to how they work. Build it; don't decline it. The developer
agrees the timing with the customer.

- Where possible, build the general capability, so every customer who needs
  the same kind of thing can use it.
- If the general version would take too long, first ship a quick version for
  the requesting customer so the request still lands in days. Make it its own
  app, or put it behind a per-group setting as above, never a literal group
  id. Then build the general capability, move the customer onto it without
  any disruption, and remove the quick version.
- A quick version that works well on its own may stay as a separate app,
  branched from the same source. Apps are built and managed separately, so
  this is fine.

Say in the PR which of these it is, and file the general capability as its
own request so it isn't lost.

## Say it at the top of the PR

The first line of every change-request PR body is its scope, with one line of
reasoning, e.g.:

> **Scope: all groups using Rented Dwelling** — fixes a rounding bug in the
> premium summary, which every group sees.

> **Scope: Globex only, behind setting `garagePricingBySize`
> (rented-dwelling; default off — other groups unchanged)** — Globex
> prices garages by square footage; other clients price them flat.

The reviewer can then ask for the other choice in the PR, and the agent
switches it: all groups ↔ behind a setting.

## And a release note

Every PR that changes user-facing code — not just change requests — says
whether the people who use the app will notice it. Right after the scope line
(or near the top of the body), either write one plain-language sentence about
what they'll notice, not how it was built, and name the apps it's for:

> **Release note:** Garage premiums now round to the nearest dollar on the
> quote summary.
> **Release apps:** rented-dwelling

or say it isn't something users would notice:

> **Release note:** none — internal refactor

Write it for people who aren't technical: no code, file or tool names, and
no details of a security problem ("Security improvements to help keep your
information safe." is enough). What's New and the launcher's "What's new"
pop-up also rewrite each note into friendly wording before showing it
(`functions/_release_friendly.js`), so a technical note still reads well,
but a plain one comes out closest to what you meant.

**Write a note** when the change alters how someone uses or experiences an
app: a new or changed screen, option, flow or field; different behavior or
results; a bug fix they could have run into; an error message or loading
state they'll now see differently; a speed-up they'd feel.

**Write "none"** for refactors, internal tooling, logging and metrics,
dependency bumps, admin-only plumbing nobody sees, security or rules changes
with no visible effect, and anything a user couldn't tell happened. When in
doubt between a tiny tweak and a note, prefer none — What's New should read
like a short list of things worth knowing, not a changelog.

`Release apps` takes `apps/{appId}`s (comma-separated), or `all` for
platform-wide changes such as the launcher or shared UI. A PR linked to a
ticket can omit it — the ticket names its app — but may add apps the ticket
doesn't.

When the change goes live the note becomes an entry in **What's New** for
every group with one of those apps (all groups for `all`; only groups with
the setting on for setting-scoped changes), and the group that asked always
sees it, credited to them.

The release note step of **PR Checks** (`pr-checks.yml`) fails a PR that touches user-facing code
without a `Release note:` line (or with a note but no apps and no ticket).
PRs that only touch docs, tests, CI or tooling pass automatically and never
produce an entry. The rules are in `functions/_release_notes.js`.
