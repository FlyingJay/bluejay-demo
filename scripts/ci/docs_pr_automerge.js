#!/usr/bin/env node
/**
 * Auto-merges documentation-only pull requests, public page content PRs
 * (web/about/ and the landing page), and the prose and copy-only PRs advisor
 * rounds open (claude/advisor-* branches). Which PR is in which
 * lane, and which files always need the owner, is in pr_lanes.js.
 *
 * Used by .github/workflows/auto-merge-docs-pr.yml in two modes:
 *   --pr <number>   right after a PR is opened / updated / marked ready, or
 *                   its build/test checks finish
 *   --sweep         after a docs merge to main, on a schedule, or on demand:
 *                   every open PR that is eligible
 *
 * A PR is eligible when every changed file (both sides of a rename) is under
 * documentation/, or is pubspec.yaml with only `- documentation/<dir>/` asset lines added or
 * removed (Flutter assets aren't recursive, so each new documentation folder
 * needs its own line, and the docs agent adds it).
 *
 * Merging is retried with backoff when the base branch moved underneath it
 * ("Base branch was modified"), which is what happens when several docs PRs
 * land within minutes of each other. The sweep that runs after every docs
 * merge to main catches anything a PR-event run couldn't finish, so a docs PR
 * can't stay stuck.
 *
 * PRs that touch pubspec.yaml are only merged once their checks have passed
 * (a bad asset line breaks the web build); pure documentation/ PRs merge
 * immediately, as before.
 *
 * Runs from the default branch's copy of this file (pull_request_target),
 * never the PR's, so a PR can't rewrite its own eligibility.
 *
 * Env: GH_TOKEN (writes: label, approve, merge — the repo PAT),
 *      GH_READ_TOKEN (reads: PRs, files, check runs — the workflow's GITHUB_TOKEN,
 *      which has `checks: read`; the PAT doesn't), GITHUB_REPOSITORY.
 */
'use strict';

// Shared with the release-note check, so the two never disagree about a docs PR.
const { isDocsAssetOnlyPatch } = require('../../functions/_docs_assets');
const { classifyFiles, classifyPr } = require('./pr_lanes');

const OK_CONCLUSIONS = new Set(['success', 'skipped', 'neutral']);
const SELF_CHECK_NAME = 'Auto-merge if documentation-only';
const MERGE_RETRY_DELAYS_MS = [5000, 10000, 20000, 40000, 60000];

/** Label and approval text for each lane the script merges. */
const LANES = {
  docs: { label: 'documentation', approval: 'Auto-approved: documentation-only change (documentation/ files, plus documentation asset lines in pubspec.yaml).' },
  pages: { label: 'auto-merge: pages', approval: 'Auto-approved: public page content only (web/about/ and the landing page, with no script, event handler or embed changed), after checks passed.' },
  prose: { label: 'auto-merge: prose', approval: 'Auto-approved: an advisor prose change (markdown only, no guarded files), after checks passed.' },
  copy: { label: 'auto-merge: copy', approval: 'Auto-approved: an advisor copy-only change (only comments and prose strings changed; see scripts/ci/copy_only_diff.js), after checks passed.' },
};
/** Label on an advisor PR that needs the owner, so the round feed can show it as waiting. */
const REVIEW_LABEL = 'needs owner review';

/**
 * 'passed' | 'pending' | 'failed' for a commit's check runs, ignoring this
 * workflow's own job. A check that ran more than once on the commit (a
 * re-run, or a workflow re-triggered by a PR edit, e.g. the release-note
 * check) is judged by its latest run only, as GitHub's UI does.
 */
function summarizeChecks(checkRuns) {
  const latest = new Map();
  for (const r of checkRuns) {
    if (r.name === SELF_CHECK_NAME) continue;
    const key = `${r.app && r.app.slug || ''}|${r.name}`;
    const prev = latest.get(key);
    if (!prev || runOrder(r) > runOrder(prev)) latest.set(key, r);
  }
  const runs = [...latest.values()];
  if (runs.some((r) => r.status === 'completed' && !OK_CONCLUSIONS.has(r.conclusion))) return 'failed';
  if (runs.some((r) => r.status !== 'completed')) return 'pending';
  return 'passed';
}

/** Sort key for "which run of this check is newest": start time, then id. */
function runOrder(r) {
  const t = Date.parse(r.started_at || r.completed_at || '') || 0;
  return t * 1e6 + (Number(r.id) || 0) % 1e6;
}

/** Whether a merge error is worth retrying (base moved / not yet mergeable). */
function isRetryableMergeError(err) {
  const msg = String(err && err.message || '');
  return err && (err.status === 405 || err.status === 409) &&
    /base branch was modified|try the merge again|not mergeable|head branch was modified/i.test(msg);
}

// ---------------------------------------------------------------------------
// GitHub API
// ---------------------------------------------------------------------------

function api(token, repo) {
  const base = `https://api.github.com/repos/${repo}`;
  async function call(method, path, body) {
    const res = await fetch(path.startsWith('https://') ? path : `${base}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const err = new Error((data && data.message) || `${method} ${path} -> ${res.status}`);
      err.status = res.status;
      throw err;
    }
    return data;
  }
  async function paginate(path) {
    const out = [];
    for (let page = 1; ; page++) {
      const sep = path.includes('?') ? '&' : '?';
      const batch = await call('GET', `${path}${sep}per_page=100&page=${page}`);
      const items = Array.isArray(batch) ? batch : (batch.check_runs || []);
      out.push(...items);
      if (items.length < 100) return out;
    }
  }
  const graphql = (query, variables) => call('POST', 'https://api.github.com/graphql', { query, variables });
  return { call, paginate, graphql };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Whether a PR's title marks it as still being written: an author who opens
 * a PR titled "[WIP] …" renames it when it finishes, and a docs PR merged
 * before that can be half-written. (The workflow re-runs on
 * `edited`, so the rename itself triggers the merge.)
 */
function isWorkInProgress(title) {
  return /^\s*\[\s*wip\s*\]/i.test(String(title || ''));
}

/**
 * Reads a file at the PR's merge base or head through the contents API
 * (files over 1 MB come back without content, so they read as null).
 */
function fileReader(gh, pr) {
  let mergeBase;
  return async (path, side) => {
    if (side === 'base' && !mergeBase) {
      const cmp = await gh.call('GET', `/compare/${pr.base.sha}...${pr.head.sha}`);
      mergeBase = cmp.merge_base_commit.sha;
    }
    const ref = side === 'base' ? mergeBase : pr.head.sha;
    try {
      const data = await gh.call('GET', `/contents/${path.split('/').map(encodeURIComponent).join('/')}?ref=${ref}`);
      return data && data.encoding === 'base64' ? Buffer.from(data.content, 'base64').toString('utf8') : null;
    } catch (err) {
      return null;
    }
  };
}

async function processPr(gh, number, { requireChecks = false, log = console.log } = {}) {
  const pr = await gh.call('GET', `/pulls/${number}`);
  if (pr.state !== 'open') return log(`#${number}: not open; skipping.`);
  if (isWorkInProgress(pr.title)) return log(`#${number}: title starts with [WIP]; waiting until it's renamed.`);
  // A draft is its author saying the PR isn't finished, and CI skips drafts,
  // so its checks would pass without having run. Marking it ready is a
  // ready_for_review event, which runs this again.
  if (pr.draft) return log(`#${number}: draft; waiting until it's marked ready.`);
  const files = await gh.paginate(`/pulls/${number}/files`);
  const c = await classifyPr({ files, branch: pr.head.ref, readFile: fileReader(gh, pr) });
  if (c.lane === 'review') {
    if (/^claude\/advisor-/.test(pr.head.ref)) {
      await gh.call('POST', `/issues/${number}/labels`, { labels: [REVIEW_LABEL] }).catch(() => {});
    }
    return log(`#${number}: not eligible (${c.reason}).`);
  }
  const lane = LANES[c.lane];

  // Labelled before the checks gate, so the advisor round feed can show an
  // open prose/copy PR as merging on its own while its checks run.
  await gh.call('POST', `/issues/${number}/labels`, { labels: [lane.label] }).catch(() => {});
  await gh.call('DELETE', `/issues/${number}/labels/${encodeURIComponent(REVIEW_LABEL)}`).catch(() => {});

  if (pr.mergeable === false) return log(`#${number}: has merge conflicts; needs manual resolution.`);

  if (requireChecks || c.requireChecks) {
    const runs = await gh.paginate(`/commits/${pr.head.sha}/check-runs`);
    const state = summarizeChecks(runs);
    if (state !== 'passed') {
      return log(`#${number}: ${c.lane} lane, but checks are ${state}; will retry when they finish or on the next sweep.`);
    }
  }

  const reviews = await gh.paginate(`/pulls/${number}/reviews`);
  if (!reviews.some((r) => r.state === 'APPROVED')) {
    await gh.call('POST', `/pulls/${number}/reviews`, {
      event: 'APPROVE',
      body: lane.approval,
    }).catch((e) => log(`#${number}: approve skipped (${e.message}).`));
  }

  for (let attempt = 0; ; attempt++) {
    try {
      await gh.call('PUT', `/pulls/${number}/merge`, { merge_method: 'squash', sha: undefined });
      return log(`#${number}: merged (${c.lane} lane).`);
    } catch (err) {
      if (isRetryableMergeError(err) && attempt < MERGE_RETRY_DELAYS_MS.length) {
        log(`#${number}: merge attempt ${attempt + 1} failed (${err.message}); retrying.`);
        await sleep(MERGE_RETRY_DELAYS_MS[attempt]);
        continue;
      }
      return log(`#${number}: could not merge (${err.message}); the next sweep will try again.`);
    }
  }
}

async function main(argv = process.argv.slice(2)) {
  const token = process.env.GH_TOKEN;
  const repo = process.env.GITHUB_REPOSITORY;
  if (!token || !repo) throw new Error('GH_TOKEN and GITHUB_REPOSITORY are required.');
  // Reads (incl. check runs, which the PAT can't see) use the workflow token;
  // writes use the PAT so merges trigger downstream workflows.
  const writer = api(token, repo);
  const reader = api(process.env.GH_READ_TOKEN || token, repo);
  const gh = {
    call: (method, path, body) => (method === 'GET' ? reader : writer).call(method, path, body),
    paginate: reader.paginate,
    graphql: writer.graphql,
  };
  const prIdx = argv.indexOf('--pr');
  if (prIdx !== -1) {
    await processPr(gh, Number(argv[prIdx + 1]));
  } else if (argv.includes('--sweep')) {
    const open = await gh.paginate('/pulls?state=open');
    // Oldest first, so the backlog drains in order.
    for (const pr of open.sort((a, b) => a.number - b.number)) {
      try {
        await processPr(gh, pr.number, { requireChecks: true });
      } catch (err) {
        console.log(`#${pr.number}: error (${err.message}); continuing.`);
      }
    }
  } else {
    throw new Error('Usage: docs_pr_automerge.js --pr <number> | --sweep');
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
}

module.exports = { classifyFiles, classifyPr, isDocsAssetOnlyPatch, summarizeChecks, isRetryableMergeError, isWorkInProgress, processPr };
