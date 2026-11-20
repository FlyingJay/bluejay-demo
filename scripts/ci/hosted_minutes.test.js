'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { billedMinutes, isHosted, summarize, daysBetween, report } = require('./hosted_minutes');

const job = (name, seconds, extra = {}) => ({
  name,
  conclusion: 'success',
  labels: ['ubuntu-latest'],
  started_at: '2026-11-14T10:00:00Z',
  completed_at: new Date(Date.parse('2026-11-14T10:00:00Z') + seconds * 1000).toISOString(),
  ...extra,
});

test('billedMinutes rounds every job that ran up to a whole minute', () => {
  assert.equal(billedMinutes(job('a', 5)), 1);
  assert.equal(billedMinutes(job('a', 60)), 1);
  assert.equal(billedMinutes(job('a', 61)), 2);
  assert.equal(billedMinutes(job('a', 0)), 1, 'a job that started is billed a minute');
  assert.equal(billedMinutes(job('a', 300, { conclusion: 'skipped' })), 0);
  assert.equal(billedMinutes({ name: 'a', conclusion: 'cancelled', started_at: null, completed_at: null }), 0);
});

test('isHosted tells GitHub-hosted labels from other runners', () => {
  assert.equal(isHosted({ labels: ['ubuntu-latest'] }), true);
  assert.equal(isHosted({ labels: ['ubuntu-24.04'] }), true);
  assert.equal(isHosted({ labels: ['ubicloud-standard-4'] }), false);
  assert.equal(isHosted({ labels: ['self-hosted', 'linux'] }), false);
});

test('summarize totals hosted and other minutes per workflow, grouping called-workflow jobs under their caller', () => {
  const summary = summarize([
    { name: 'Deploy Production', jobs: [
      job('plan', 20),
      job('functions / deploy', 200),
      job('functions / verify', 30),
      job('finish', 90),
      job('rules / deploy', 0, { conclusion: 'skipped' }),
    ] },
    { name: 'Deploy Production', jobs: [job('plan', 10)] },
    { name: 'Tests', jobs: [job('plan', 30), job('node', 400, { labels: ['ubicloud-standard-4'] })] },
  ]);
  assert.equal(summary.hosted, 1 + 4 + 1 + 2 + 1 + 1);
  assert.equal(summary.other, 7);
  assert.equal(summary.runs, 3);
  assert.deepEqual(summary.workflows.map((wf) => [wf.name, wf.runs, wf.hosted, wf.other]),
    [['Deploy Production', 2, 9, 0], ['Tests', 1, 1, 7]]);
  assert.deepEqual(summary.workflows[0].jobs, [
    { name: 'functions', hosted: 5, other: 0 },
    { name: 'finish', hosted: 2, other: 0 },
    { name: 'plan', hosted: 2, other: 0 },
  ]);
  const text = report(summary, 2);
  assert.match(text, /^Hosted minutes: 10 over 2 day\(s\), 5 a day \(3 runs; another 7 minutes on other runners\)\./);
  assert.match(text, /\| Deploy Production \| 2 \| 9 \| 5 \| 90% \| 0 \| functions 5, finish 2, plan 2 \|/);
});

test('daysBetween lists each UTC day, both ends included', () => {
  assert.deepEqual(daysBetween('2026-11-14', '2026-11-16'), ['2026-11-14', '2026-11-15', '2026-11-16']);
  assert.deepEqual(daysBetween('2026-11-30', '2026-12-01'), ['2026-11-30', '2026-12-01']);
  assert.throws(() => daysBetween('2026-11-16', '2026-11-14'), /after/);
});
