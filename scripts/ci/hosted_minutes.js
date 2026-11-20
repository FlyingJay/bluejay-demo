#!/usr/bin/env node
/**
 * How many runner minutes the repository's workflows used over some days,
 * by workflow, counted the way GitHub bills them: every job that ran is
 * rounded up to a whole minute, so a ten-second job costs one. Minutes on
 * GitHub-hosted runners are reported apart from the ones on other runners
 * (the HEAVY_RUNNER the test suites use), which cost about a tenth as much.
 *
 * Use it to see what a CI change saved: run it for a few days before and a
 * few days after, and compare the hosted minutes per day.
 *
 *   node scripts/ci/hosted_minutes.js --from 2026-11-14 --to 2026-11-16 [--repo owner/name] [--json]
 *
 * Dates are UTC days, both included, by when the run was created. Reads
 * `/actions/runs` and each run's `/jobs` (one API call per run, so a busy
 * day is several hundred calls). Token: GH_TOKEN or GITHUB_TOKEN, else
 * `gh auth token`; it needs Actions: read.
 */

'use strict';

const { execFileSync } = require('child_process');

const DEFAULT_REPO = 'bluejayorg/bluejay';
/** Labels of the runners GitHub hosts and bills at its own rates. */
const HOSTED_LABEL = /^(ubuntu|windows|macos)-/;
const CONCURRENCY = 8;

/** Whole billed minutes for one job: 0 when it never ran, else at least 1. */
function billedMinutes(job) {
  if (job.conclusion === 'skipped' || !job.started_at || !job.completed_at) return 0;
  const ms = Date.parse(job.completed_at) - Date.parse(job.started_at);
  if (!Number.isFinite(ms) || ms < 0) return 0;
  return Math.max(1, Math.ceil(ms / 60000));
}

/** Whether a job ran on a GitHub-hosted runner (by its labels). */
function isHosted(job) {
  const labels = job.labels || [];
  return labels.length === 0 || labels.some((label) => HOSTED_LABEL.test(label));
}

/**
 * Totals for [runs] ({ name, event, jobs }): { hosted, other, runs,
 * workflows: [{ name, runs, hosted, other, jobs: [{ name, hosted, other }] }] },
 * workflows and jobs sorted by hosted minutes, most first. A called
 * workflow's jobs (`<caller job> / <job>`) are grouped under the caller job.
 */
function summarize(runs) {
  const workflows = new Map();
  for (const run of runs) {
    const key = run.name || '(unnamed)';
    if (!workflows.has(key)) workflows.set(key, { name: key, runs: 0, hosted: 0, other: 0, jobs: new Map() });
    const wf = workflows.get(key);
    wf.runs += 1;
    for (const job of run.jobs || []) {
      const minutes = billedMinutes(job);
      if (minutes === 0) continue;
      const kind = isHosted(job) ? 'hosted' : 'other';
      wf[kind] += minutes;
      const jobName = String(job.name).split(' / ')[0];
      if (!wf.jobs.has(jobName)) wf.jobs.set(jobName, { name: jobName, hosted: 0, other: 0 });
      wf.jobs.get(jobName)[kind] += minutes;
    }
  }
  const byHosted = (a, b) => b.hosted - a.hosted || b.other - a.other || a.name.localeCompare(b.name);
  const list = [...workflows.values()].map((wf) => ({ ...wf, jobs: [...wf.jobs.values()].sort(byHosted) })).sort(byHosted);
  return {
    hosted: list.reduce((sum, wf) => sum + wf.hosted, 0),
    other: list.reduce((sum, wf) => sum + wf.other, 0),
    runs: runs.length,
    workflows: list,
  };
}

/** Each UTC day from [from] to [to] (YYYY-MM-DD, both included). */
function daysBetween(from, to) {
  const days = [];
  for (let at = Date.parse(`${from}T00:00:00Z`); at <= Date.parse(`${to}T00:00:00Z`); at += 24 * 60 * 60 * 1000) {
    days.push(new Date(at).toISOString().slice(0, 10));
  }
  if (days.length === 0) throw new Error(`--from ${from} is after --to ${to}`);
  return days;
}

/** A Markdown report of [summary] over [dayCount] days. */
function report(summary, dayCount) {
  const perDay = (n) => Math.round(n / dayCount);
  const share = (n) => (summary.hosted ? `${Math.round((100 * n) / summary.hosted)}%` : '0%');
  const lines = [
    `Hosted minutes: ${summary.hosted} over ${dayCount} day(s), ${perDay(summary.hosted)} a day `
      + `(${summary.runs} runs; another ${summary.other} minutes on other runners).`,
    '',
    '| Workflow | Runs | Hosted min | A day | Share | Other min | Biggest hosted jobs |',
    '|---|---|---|---|---|---|---|',
  ];
  for (const wf of summary.workflows) {
    if (wf.hosted === 0 && wf.other === 0) continue;
    const jobs = wf.jobs.filter((job) => job.hosted > 0).slice(0, 4).map((job) => `${job.name} ${job.hosted}`).join(', ');
    lines.push(`| ${wf.name} | ${wf.runs} | ${wf.hosted} | ${perDay(wf.hosted)} | ${share(wf.hosted)} | ${wf.other} | ${jobs} |`);
  }
  return lines.join('\n');
}

function token() {
  return process.env.GH_TOKEN || process.env.GITHUB_TOKEN
    || execFileSync('gh', ['auth', 'token'], { encoding: 'utf8' }).trim();
}

async function fetchRuns({ repo, days, auth }) {
  const get = async (pathname) => {
    const response = await fetch(`https://api.github.com/repos/${repo}${pathname}`, {
      headers: { Authorization: `Bearer ${auth}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
    });
    if (!response.ok) throw new Error(`GitHub ${pathname} → ${response.status}: ${await response.text()}`);
    return response.json();
  };
  const runs = [];
  for (const day of days) {
    // One query per day: the runs list stops at 1,000 results a query.
    for (let page = 1; ; page += 1) {
      const body = await get(`/actions/runs?created=${day}..${day}&per_page=100&page=${page}`);
      runs.push(...body.workflow_runs);
      if (body.workflow_runs.length < 100) break;
    }
  }
  let next = 0;
  const worker = async () => {
    while (next < runs.length) {
      const run = runs[next];
      next += 1;
      run.jobs = [];
      for (let page = 1; ; page += 1) {
        // filter=all counts re-run attempts too; each one was billed.
        const body = await get(`/actions/runs/${run.id}/jobs?filter=all&per_page=100&page=${page}`);
        run.jobs.push(...body.jobs);
        if (body.jobs.length < 100) break;
      }
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return runs;
}

async function main(argv) {
  const arg = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
  const from = arg('--from');
  const to = arg('--to') || from;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from || '') || !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
    throw new Error('usage: hosted_minutes.js --from YYYY-MM-DD [--to YYYY-MM-DD] [--repo owner/name] [--json]');
  }
  const days = daysBetween(from, to);
  const runs = await fetchRuns({ repo: arg('--repo') || DEFAULT_REPO, days, auth: token() });
  const summary = summarize(runs);
  console.log(argv.includes('--json') ? JSON.stringify({ from, to, days: days.length, ...summary }, null, 2) : report(summary, days.length));
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}

module.exports = { billedMinutes, isHosted, summarize, daysBetween, report };
