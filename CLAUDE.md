# Working in this repo

## Pull requests

When you make code changes in this repo (bug fixes, features, refactors, config/rules
changes, etc.), open a pull request for them by default — do not wait to be asked. This
means: commit the change on a dedicated `claude/*` branch off `origin/main` (not onto
whatever branch happened to be checked out, unless it's already a fresh branch for this
exact change), push it, open it with `gh pr create --draft` and a real summary and test
plan, and mark it ready once the change is complete and verified, as described in
"Draft PRs, local checks and PR size" below.

This does not apply to:
- Exploratory or throwaway edits made purely to test something locally.
- Changes the user explicitly says to just commit, or not to commit/push at all.
- Anything the user asks you to push directly to `main`.

Every PR body that changes user-facing code needs a `**Release note:**` line: one
plain-language sentence an end user would notice plus `**Release apps:** <app-id>, ...`
(or `all`), or `**Release note:** none` if they wouldn't notice it. Notes become
What's New entries when the change goes live, so be selective. A CI check enforces the
line. See "And a release note" in `CHANGE_REQUEST_SCOPE.md` for what counts.

Still confirm before force-pushing, pushing to `main` directly, or any other
destructive/hard-to-reverse git operation — this instruction only changes the default
for *opening a PR after finishing a change*, not the general git safety rules.

## Draft PRs, local checks and PR size

CI skips draft PRs. It runs in full when a PR is marked ready and again on every later
push to it, about 100 billable minutes each time, so every push after `gh pr ready` costs
a full run.

1. **Open PRs as drafts** (`gh pr create --draft`) while the work is in progress. Push
   fix rounds to the draft as often as you need; they cost nothing.
2. **Run `scripts/ci/local_check.sh`** and fix everything it reports. It runs locally what
   CI would run for the branch's diff against `origin/main`: the Node suite, Flutter
   analyze and tests for the affected packages and the launcher app, the generated-rules
   and security checks, and the security tier audit. Add `--rules` when it prints the
   rules notice (the emulator tests need JDK 21).
3. **Mark it ready** with `gh pr ready <n>` once the check passes. That starts CI. Batch
   any later changes into as few pushes as you can.

**Run tests the way CI does.** Use `scripts/ci/local_check.sh` or
`scripts/ci/run_node_tests.sh`, which give each test file its own process and reinstall
any `node_modules` that is missing, symlinked or behind its lockfile. Don't symlink
`node_modules` into a worktree from another checkout, and don't count a bare `node --test`
across a whole folder as the suite: the main checkout's dependencies can be days behind
`origin/main`, and running against them fails tests that pass in CI. To find out whether
a failure is new, compare against the nightly `Tests` run on main (`gh run list
--workflow tests.yml --event schedule`). Don't compare against a local baseline built
from the same dependencies.

`tests` is a required check on `main`, so a PR merges only once it passes. When the
user asks for a merge without waiting for CI, use `gh pr merge --admin`.

**Prefer one larger PR for related work.** Put follow-ups, review fixes, docs and status
updates, and plan edits into the PR they belong to rather than opening a PR for each.
Open a separate PR only for an unrelated change, a production-risky change that must
deploy on its own, or an urgent fix that shouldn't wait on the rest.

**Unattended runs end with a ready PR**, so people see CI results: the ticket-dispatch
worker, scheduled sessions and sprint agents run the local check, then open the PR ready
or open it as a draft and mark it ready. The nightly docs batch opens its PR ready, since
the docs auto-merge leaves drafts alone.

## Working tree isolation

Multiple sessions frequently work on this repo at the same time. Before starting any
new code changes, check whether other agents are doing code work on this machine, using
the steps in the global `~/.claude/CLAUDE.md` ("Working tree isolation on a local
machine"): `ListAgents`, plus a scan for Claude Code processes other than this
session's own. If any are running, or you can't rule it out, use a dedicated git
worktree for the session (via the `EnterWorktree` tool, or `git worktree add` on a fresh
`claude/*` branch if that tool isn't available). This keeps concurrent sessions'
uncommitted edits, branch checkouts, and build artifacts from clobbering or
interleaving with each other. Exit/clean up the worktree (`ExitWorktree`) once the
change is committed and the PR is open.

If both checks show no other agent running, work in the current checkout and skip the
worktree. The PR rules still apply: put the change on a fresh `claude/*` branch off
`origin/main`.

This does not apply to:
- Read-only investigation, research, or answering questions with no file edits.
- Exploratory or throwaway edits the user explicitly says to make locally, in place.

## Cleaning up after yourself

Disk on this machine is limited, and leftovers pile up across sessions. Clean up as
you go, not only at the end:

- **Worktrees.** Remove a worktree (`git worktree remove`, or `ExitWorktree`) as soon
  as its work is committed and merged into its PR branch, along with what built up
  inside it (`node_modules`, `build/`, `.dart_tool`). An agent's worktree goes once its
  branch is merged; don't wait for the PR. Never remove another session's worktree or a
  branch with unmerged work, and check `git worktree list` before removing anything you
  didn't create.
- **Temporary files.** Delete scratch output when you're done with it: files and folders
  under `/tmp`, test captures and failure dumps, probe or harness builds, downloaded
  data, throwaway scripts, and local branches whose work has merged.
- **What stays.** Anything made for later use: plans and docs, reference files the user
  asked for, migration backups (`~/bluejay-migration-backups`), local secrets
  (`~/.config/bluejay`) and memory files. When unsure whether something is still
  wanted, ask before deleting it.
- **Disk.** Check `df -h /` before large builds, emulator runs or captures. If space is
  low, clear your own leftovers first.

## Rules emulator tests

Run them with `npm test` in `security/rules-tests` (or `scripts/ci/local_check.sh
--rules`). It queues behind a machine-wide lock and reuses one shared emulator, so
concurrent sessions don't each start their own JVMs. Don't hand-roll
`firebase emulators:exec` with a copied config to dodge a port clash.

A Java emulator process doesn't mean the suite is busy: check
`node security/rules-tests/scripts/shared_emulator.js status`, which shows the lock
holder, the shared emulator and any orphaned emulators. An emulator started outside
`npm test` outlives a shell that's killed (a tool call timing out), and launchd
adopts it. Orphans are stopped automatically: every rules run reaps those older
than two minutes before it starts, and the launchd job from
`scripts/ci/install_emulator_reaper.sh` reaps them every five minutes in between.
If you started an emulator yourself, still stop it before you finish; `node
security/rules-tests/scripts/shared_emulator.js reap` stops all orphans at once.

## Engineering philosophy

Never pick the narrower, more expedient fix *because* it's less work. When a change
surfaces an opportunity to close a whole class of problem — not just the one instance in
front of you — take it, even if it costs more effort than the minimal patch. If you
catch yourself writing a bespoke, one-off fix for something that clearly recurs
elsewhere in the codebase (same field names, same shape of bug, the same pattern
copy-pasted per app/package), that recurrence is itself the signal: the version of the
fix that also builds or extends a shared, generic mechanism is the *correct* fix, not an
optional extra layered on top of the "real" one. Aim for patterns that will last —
a shared function, a data-driven table, a single enforced convention — over ones that
only close the door for the one case you happened to be looking at.

This does not license unrelated scope creep. A fix for X should not casually start
refactoring Y. The distinction is: when the correct fix for X is inherently more general
than the narrowest possible patch, do the general version of fixing X — don't shrink the
fix to fit an arbitrary effort budget.

When you need to know how widely a pattern recurs before committing to a design (e.g.
"how many apps write this field directly, and do they all need the same protection?"),
dispatching an agent to audit the codebase for it first is expected practice, not
overkill — see the `Agent` tool usage notes for when to background vs. foreground that.

## Business messaging

Any copy that speaks for the business (landing pages under `bluejay.gg/about`, site and
link-preview text, marketing and sales copy, emails, one-pagers, decks) goes through the
`business-messaging` skill. It reads the current business plan from the private
`bluejayorg/bluejay-business` repository and checks every claim against the plan and the
product before anything is written.

## Brand and design

Bluejay's brand and style guide is `brand/BRAND_GUIDE.md` in the private
`bluejayorg/bluejay-business` repository (`bash .claude/skills/business-messaging/locate_business_repo.sh`
prints the checkout path). It is the single reference for the name, logo, colors, type,
shapes, imagery, voice and messaging, and how they apply to the app, the site, documents,
slides and email. Read it before writing user-facing text of any kind (UI strings, empty
states, errors, emails, store listings, release notes, landing pages) or designing anything
outside the app: a landing page, an email template, a link-preview image, a document.

Inside the app, `packages/bluejay_design` implements the guide's visual side, and its
README is the reference for building screens. The design system is the source of every
visual value in the guide: a change to its tokens regenerates
`packages/bluejay_design/design_tokens.json`, and the PR must say the brand guide needs
the same change, so the guide is updated the same day (its section 13;
`brand/tools/check_design_sync.py` there lists what differs). Without access to the
business repository, follow the design system README for visuals and this file's
writing style for text, and say the guide wasn't checked.

## Product vocabulary

Each thing Bluejay sells or shows has one name, listed in the brand guide's section 2
("Vocabulary"). The ones agents most often get wrong:

- **Developer agent**: a unit of development capacity, one of a group's requests being
  built at a time. Code and staff-only admin apps (Queue Management) call it a **slot**,
  and seat plans store it as `devQueues`. Customer- and group-admin-facing text says
  "developer agent", never "development queue", "dev queue", "slot" or "concurrent request".
- **Queue**: one person's own ordered list of their requests. Never the capacity.
- **Group**: a customer's own space. Not tenant, account or workspace in product text.
- **Plan**: what a group pays for (seats, developer agents, minimum security tier). The
  plans are Personal, Team and Business; a signup *package* is how a plan is shown at
  signup. Write plan names with "plan" and security tiers with "tier" ("the Business plan
  starts groups at the business tier"), since the two share words.
- **Request**: what someone asks to change; "ticket" only in staff tools.
- **Steward group** / **stewarded group**: `managedBy`.
- **Worker**: a computer running developer agents (Dev Workers app); staff-facing only.

New user-facing text uses these words. When you touch a screen that still uses an old
one, fix it in the same change.

## Writing style

Avoid AI-sounding rhetorical patterns in generated prose — marketing/pitch copy, docs,
PR descriptions, commit messages, code comments, any user-facing text. The most common
tell is the contrastive "X, not Y" / "it's not a X, it's a Y" construction (e.g. "a build
pipeline, not a backlog"; "not a tool you bolt onto everything else"; a section header
like "Proof, Not Promises"). State what something is directly instead of framing it
against what it isn't. A few of these can slip in unnoticed since each one reads fine in
isolation — the tell is density, so if more than one shows up in the same document, treat
that as the signal to rewrite, not just the individual line.

This applies everywhere Claude generates prose in this repo, not only in one-off
documents like the `pitch/` decks — reread a paragraph before finalizing it and cut this
pattern (and other stock AI-writing tics like it) wherever it shows up, the same as
checking for a bug.

- User-facing text uses Canadian spelling (colour, favourite, centre, behaviour,
  cancelled; -ize endings). Names in code and data, the app catalog, third-party names
  and text for a US-only audience keep US spelling (brand guide §8).
