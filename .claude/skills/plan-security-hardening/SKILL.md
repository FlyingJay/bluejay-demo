---
name: plan-security-hardening
description: Given one or more bluejay app/feature names, read their improvements-security.md (plus developer.md/interfaces.md for blast-radius context), classify every open item by effort and real risk, and hand back a phased hardening plan — planning only, no code changes. Use when the user says things like "what security fixes should we do for X before launch", "harden <app> for production", "give me a security punch list for <feature>", "what's the low-hanging fruit here security-wise", or names an app/feature and asks about security readiness. Companion to implement-feature-improvement (executes a single picked item) and change-firestore-permissions (executes any Firestore/Storage rules fix this plan surfaces) — this skill only reads and ranks, across every item in the security doc(s) at once, and never edits code, rules, or opens a PR itself.
---

# Plan Security Hardening

Reproduces, as a repeatable skill, the process of: resolve an app → read what its docs already say is wrong from a security standpoint → weigh each item by how cheap and how risky it actually is → hand the user a ranked, phased plan they can approve before anything gets touched. It never implements — that's deliberately left to `implement-feature-improvement` and `change-firestore-permissions`, which already have PR/review discipline built in.

## Inputs

Parse from the user's request:
- **app(s)/feature(s)** (required, one or more): a `documentationSlug` or `name` from `documentation/feature_doc_mapping.json`. If the user names something fuzzy (e.g. "Policy Editor"), resolve it against the mapping and the docs themselves before proceeding — don't guess a slug. Note: some product-facing names don't map 1:1 to a package directory (e.g. "Policy Editor" is the `insurance_admin` package's in-app name; the launcher tile still routes through `policy-editor`). Confirm the resolved slug with the user if there's any ambiguity.
- **scope** (optional, default: security-fixes only): the user may ask to also fold in `improvements-performance.md` or others, but default to `improvements-security.md` unless told otherwise — this skill's contract is security hardening.

## Steps

1. **Resolve each named app** against `documentation/feature_doc_mapping.json`. If a name doesn't resolve cleanly, grep the docs tree (`grep -ril "<name>" documentation/`) the way you would for any unfamiliar product name — package names and product names diverge in this repo (see Policy Editor example above).

2. **Read, per app:**
   - `documentation/<slug>/improvements-security.md` — the source list of open items. If this file doesn't exist or is empty, say so plainly and don't invent findings.
   - The app's computed tier and failing checks: `node scripts/security_tier_audit/audit.js --app <appId> --with-declared` (needs `GOOGLE_APPLICATION_CREDENTIALS`; without it Tier 3/4 can't pass). Each failing check is an item: `sharedEditingFalse` (app config), `guestsConfined` (`guestWritable`/`guestShareable`/`guestWritableFolders`), `hasAuditTrail` (`auditTrail` on every owned collection, writes through the stamping shim), `noHardDelete` (`blockDelete`, after checking what deletes today). See `SECURITY_TIERS.md`.
   - `documentation/<slug>/developer.md` and `interfaces.md` — needed to judge whether an item that *reads* simply is actually contained, or touches a shared helper/Cloud Function used by other packages (e.g. a fix inside `insurance_admin` that's actually implemented in a function shared with `commercial_property` and `rented_dwelling`).

3. **Classify every item** on two independent axes:
   - **Effort tier**: `trivial` (single UI/logic tweak, one file), `small` (one function or one contained write path, still app-code or a single Cloud Function), `rules-only` (Firestore/Storage rules change — small in line count but always its own care tier, never bundle with app code), `medium` (spans client + function, or extends existing infra to new surface area), `large` (new server-side infrastructure, or a change spanning many call sites/flows).
   - **Real risk if left unfixed**: is this a live, exploitable gap (auth bypass, arbitrary-recipient/arbitrary-target action, PII exposed to unauthorized readers) versus a defense-in-depth/robustness/observability improvement. State this distinction explicitly per item — don't let "small effort" and "low risk" collapse into the same thing, and don't let a `large`-effort live vulnerability get buried under trivial items just because it scores worse on effort.

4. **Rank.** Low-hanging fruit = `trivial`/`small`/`rules-only` effort AND a real, non-trivial risk reduction. Surface any live exploitable vulnerability at the top of the list regardless of its effort tier, with an explicit callout that effort and priority are being weighed separately for that item.

5. **Phase the plan** by blast radius and who executes it, not just by app:
   - **Phase A — app-code-only, trivial/small, no auth/rules/Cloud Function surface touched.** Safe to batch multiple items into one `implement-feature-improvement` pass per app (that skill still does one improvement per run — note this constraint to the user rather than assuming a full phase happens in one shot).
   - **Phase B — Firestore/Storage rules changes.** Tier 3/4 gaps land here: they are table keys (`guestWritable`, `auditTrail`, `blockDelete`, `serverWritten`). Always route through `change-firestore-permissions`, never propose editing `firestore.rules` directly in this plan — that skill exists specifically because rules changes have a documented history of drifting from what's deployed.
   - **Phase C — Cloud Functions/callable endpoints that touch money, PII, or auth decisions.** One `implement-feature-improvement` run per item, not batched, even if several items are individually small — isolated review matters more than throughput here.
   - **Phase D — medium-lift items.** Call out separately with a one-line note on why they're contained despite the higher tier (e.g. "extends an existing proxy to new platforms" reads very differently from "build a new proxy").
   - **Explicitly out of scope for this pass — large/architectural items.** List them by name with a one-line reason, so the user knows they were seen and deliberately deferred, not missed.

6. **Present the plan in chat only.** Output a ranked table (App | Item | Effort tier | Real risk if unfixed | One-line fix) followed by the phased plan referencing which existing skill executes each phase. Do not write files, create branches, or open a PR — this skill's entire output is the plan itself, for the user to approve.

7. **Ask, don't assume.** End by asking which item or phase the user wants to start with. Do not proceed to `implement-feature-improvement` or `change-firestore-permissions` automatically — those are separate, explicit next steps the user triggers.

## Constraints

- Never edit code, rules, or docs, and never open a PR — planning only. If the user asks you to also implement, treat that as a new, separate request and hand off to the appropriate execution skill per the phase table above.
- Always cross-reference `developer.md`/`interfaces.md` before calling an item "trivial" — shared-helper blast radius is the most common way a simple-sounding fix turns out to be `medium`.
- Don't silently drop items into a generic middle tier — every item needs an explicit effort tier *and* an explicit real-risk call, stated separately, since a cheap fix for a low-risk issue and a cheap fix for a live vulnerability should not read the same in the output.
- If an app has no `improvements-security.md`, or it's empty, report that plainly rather than fabricating findings from `developer.md` alone.
- When multiple apps are requested in one run, still produce one unified ranked table across all of them (not one table per app) so the user can see true cross-app priority — this mirrors how the items were actually compared in the originating conversation for this skill.
