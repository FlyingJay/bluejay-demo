# Bluejay: showcase excerpt

Bluejay ([bluejay.gg](https://bluejay.gg)) is a multi-tenant platform for custom business software: one Flutter app shell hosting 130+ independently developed apps, on Firebase and Google Cloud. I've built it since November 2025 as tech lead and founding engineer, with AI coding agents as the main authors of the code.

This repository is a curated snapshot of the private Bluejay monorepo, published so people can read how it's built. It covers the parts that make agent-written code safe to ship. It doesn't build or run on its own.

| | |
|---|---|
| Commits on `main` since Nov 2025 | 5,000+ |
| Commits with an AI co-author | ~70% (mostly Claude Code) |
| Pull requests | 2,300+ |
| Features and fixes merged per day, Nov 2026 | 30+ |
| Deployable packages | 139 |
| User requests delivered to production through the development queue | 117 (30+ for client organizations) |

## How it works

Every change, from a person or an agent, goes through the same path: a pull request on a `claude/*` branch, CI gates and human review. The design goal is that an agent working from a short request can't ship something unsafe, because the things that matter are enforced by generators and checks instead of by the agent remembering a rule.

- **One declarative access schema.** [`security/collections.json`](security/collections.json) describes every Firestore collection's tenant scope, ownership and roles. [`security/generate.js`](security/generate.js) turns it into `firestore.rules`, `storage.rules` and typed Dart policies, and [`security/rules-tests/`](security/rules-tests) runs them against the emulator in CI. Nobody, human or agent, hand-writes an access rule.
- **A scoped data layer.** Apps read and write through [`ScopedCollection`](packages/shared_services/lib/scoped_collection.dart), which stamps tenant and ownership fields so documents always match what the rules expect.
- **Standing instructions for agents.** [`CLAUDE.md`](CLAUDE.md) and the skills in [`.claude/skills/`](.claude/skills) are the playbooks agents follow: scaffolding a new app, changing permissions, picking and implementing the highest-value improvement for an app, running a "dev team" of parallel agents, and the nightly documentation batch.
- **CI guardrails.** [`.github/workflows/`](.github/workflows) and [`scripts/ci/`](scripts/ci) gate every PR on tests, rules tests, a required release note ([`CHANGE_REQUEST_SCOPE.md`](CHANGE_REQUEST_SCOPE.md)), design-token and copy lint, and baseline checks that only allow known exceptions to shrink.
- **An autonomous worker pool.** [`scripts/dev_worker/`](scripts/dev_worker) sets up machines that pick up queued customer requests and return review-ready pull requests. The [`dev_queue`](packages/dev_queue) app is where those requests are filed and tracked.

## What's here

| Path | What it shows |
|---|---|
| `security/` | Access schema, rules/policy generators, rules tests |
| `packages/shared_services`, `shared_ui`, `bluejay_design` | Shared data layer, UI components and design tokens |
| `packages/projects`, `storage`, `notes`, `help_desk`, `improve_bluejay`, `dev_queue` | Representative apps built on the shared layer |
| `.claude/skills/`, `CLAUDE.md` | Agent playbooks and repo-wide instructions |
| `.github/workflows/`, `scripts/ci/`, `scripts/check_*.js` | CI gates and guardrail checks |
| `scripts/dev_worker/` | Autonomous agent worker setup |
| `documentation/` | Per-app user and developer docs (generated and maintained by agents) |

Left out: Cloud Functions and payment code, client-specific apps, infrastructure, deployment workflows, internal plans and git history. Customer names in test fixtures were replaced with placeholders.

A smaller, runnable example of the tenant-isolation approach is in [FlyingJay/firestore-tenant-isolation](https://github.com/FlyingJay/firestore-tenant-isolation).

## Rights

Copyright © 2025–2026 Jason Rivers. All rights reserved. This code is published for reading only; no license is granted to use, copy, modify or distribute it.
