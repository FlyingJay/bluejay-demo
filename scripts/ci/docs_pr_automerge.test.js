'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  classifyFiles, isDocsAssetOnlyPatch, summarizeChecks, isRetryableMergeError, isWorkInProgress, processPr,
} = require('./docs_pr_automerge');

const PUBSPEC_NEW_DOCS_DIR = [
  '@@ -380,6 +380,7 @@ flutter:',
  '     - documentation/language_learner/',
  '+    - documentation/usage_meter/',
  '     - documentation/notes/',
].join('\n');

test('documentation/ files are eligible', () => {
  const c = classifyFiles([{ filename: 'documentation/notes/user.md' }]);
  assert.deepEqual(c, { eligible: true, touchesPubspec: false, reason: 'documentation-only' });
});

test('pubspec.yaml adding only documentation asset dirs is eligible (PR #2689 / #2633 shape)', () => {
  assert.equal(isDocsAssetOnlyPatch(PUBSPEC_NEW_DOCS_DIR), true);
  const c = classifyFiles([
    { filename: 'documentation/usage_meter/user.md' },
    { filename: 'pubspec.yaml', patch: PUBSPEC_NEW_DOCS_DIR },
  ]);
  assert.equal(c.eligible, true);
  assert.equal(c.touchesPubspec, true);
});

test('any other pubspec.yaml change is not eligible', () => {
  for (const line of ['+  http: ^1.2.0', '+    - assets/images/', '-  flutter_stripe: ^12.0.0',
    '+    - documentation/../lib/', '+    - documentation/notes/secret.md']) {
    assert.equal(isDocsAssetOnlyPatch(`@@ -1,1 +1,1 @@\n${line}`), false, line);
  }
  assert.equal(isDocsAssetOnlyPatch('@@ -1 +1 @@\n+    - documentation/a_b-c/sub/'), true);
  assert.equal(isDocsAssetOnlyPatch(''), false, 'missing patch (too large) is rejected');
  assert.equal(isDocsAssetOnlyPatch(undefined), false);
  const mixed = `${PUBSPEC_NEW_DOCS_DIR}\n+  http: ^1.2.0`;
  assert.equal(classifyFiles([{ filename: 'pubspec.yaml', patch: mixed }]).eligible, false);
});

test('non-documentation files are not eligible', () => {
  assert.equal(classifyFiles([{ filename: 'documentation/a.md' }, { filename: 'lib/main.dart' }]).eligible, false);
  assert.equal(classifyFiles([]).eligible, false);
});

test('a rename moving code into documentation/ is not eligible', () => {
  const c = classifyFiles([{ filename: 'documentation/x.dart', previous_filename: 'lib/x.dart', status: 'renamed' }]);
  assert.equal(c.eligible, false);
  assert.match(c.reason, /lib\/x\.dart/);
  assert.equal(classifyFiles([{ filename: 'documentation/b.md', previous_filename: 'documentation/a.md' }]).eligible, true);
});

test('check summary ignores this workflow and treats skipped/neutral as ok', () => {
  assert.equal(summarizeChecks([
    { name: 'build_and_preview', status: 'completed', conclusion: 'success' },
    { name: 'flutter (1)', status: 'completed', conclusion: 'skipped' },
    { name: 'Auto-merge if documentation-only', status: 'in_progress', conclusion: null },
  ]), 'passed');
  assert.equal(summarizeChecks([{ name: 'tests', status: 'queued' }]), 'pending');
  assert.equal(summarizeChecks([{ name: 'tests', status: 'completed', conclusion: 'failure' }]), 'failed');
});

test('a re-run check is judged by its latest run (PR #2689: release-note check failed, then passed)', () => {
  assert.equal(summarizeChecks([
    { id: 1, name: 'check', status: 'completed', conclusion: 'failure', started_at: '2026-11-05T11:57:00Z' },
    { id: 2, name: 'check', status: 'completed', conclusion: 'cancelled', started_at: '2026-11-05T11:58:00Z' },
    { id: 3, name: 'check', status: 'completed', conclusion: 'success', started_at: '2026-11-05T12:13:00Z' },
    { id: 4, name: 'build_and_preview', status: 'completed', conclusion: 'success', started_at: '2026-11-05T12:00:00Z' },
  ]), 'passed');
  assert.equal(summarizeChecks([
    { id: 1, name: 'check', status: 'completed', conclusion: 'success', started_at: '2026-11-05T11:57:00Z' },
    { id: 2, name: 'check', status: 'completed', conclusion: 'failure', started_at: '2026-11-05T12:13:00Z' },
  ]), 'failed', 'a newer failure still fails');
});

test('base-branch-modified merge errors are retried; others are not', () => {
  assert.equal(isRetryableMergeError({ status: 405, message: 'Base branch was modified. Review and try the merge again.' }), true);
  assert.equal(isRetryableMergeError({ status: 405, message: 'Pull Request is not mergeable' }), true);
  assert.equal(isRetryableMergeError({ status: 403, message: 'Resource not accessible' }), false);
  assert.equal(isRetryableMergeError({ status: 422, message: 'Validation Failed' }), false);
});

function fakeGh({ files, checks = [], mergeErrors = [], pr = {} }) {
  const calls = [];
  let mergeAttempts = 0;
  const gh = {
    calls,
    async call(method, path, body) {
      calls.push(`${method} ${path}`);
      if (method === 'GET' && /^\/pulls\/\d+$/.test(path)) {
        return { state: 'open', draft: false, mergeable: true, head: { sha: 'abc' }, node_id: 'N', ...pr };
      }
      if (method === 'PUT' && path.endsWith('/merge')) {
        const err = mergeErrors[mergeAttempts++];
        if (err) throw Object.assign(new Error(err.message), { status: err.status });
        return { merged: true };
      }
      return {};
    },
    async paginate(path) {
      if (path.endsWith('/files')) return files;
      if (path.includes('/check-runs')) return checks;
      return [];
    },
    async graphql() { calls.push('graphql'); return {}; },
  };
  return gh;
}

test('processPr retries a base-branch-modified merge until it succeeds', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const gh = fakeGh({
    files: [{ filename: 'documentation/x.md' }],
    mergeErrors: [{ status: 405, message: 'Base branch was modified. Review and try the merge again.' }],
  });
  const logs = [];
  const done = processPr(gh, 1, { log: (m) => logs.push(m) });
  await new Promise((r) => setImmediate(r));
  t.mock.timers.tick(5000);
  await done;
  assert.equal(gh.calls.filter((c) => c.endsWith('/merge')).length, 2);
  assert.match(logs.at(-1), /merged/);
});

test('processPr waits for checks before merging a pubspec.yaml docs PR', async () => {
  const gh = fakeGh({
    files: [{ filename: 'pubspec.yaml', patch: PUBSPEC_NEW_DOCS_DIR }],
    checks: [{ name: 'build_and_preview', status: 'in_progress' }],
  });
  const logs = [];
  await processPr(gh, 2, { log: (m) => logs.push(m) });
  assert.equal(gh.calls.some((c) => c.endsWith('/merge')), false);
  assert.match(logs[0], /checks are pending/);
});

test('processPr never merges a draft (CI skips drafts, so its checks never ran)', async () => {
  const gh = fakeGh({
    files: [{ filename: 'documentation/x.md' }, { filename: 'pubspec.yaml', patch: PUBSPEC_NEW_DOCS_DIR }],
    checks: [{ name: 'build_and_preview', status: 'completed', conclusion: 'skipped' }],
    pr: { draft: true },
  });
  const logs = [];
  await processPr(gh, 3, { log: (m) => logs.push(m) });
  assert.equal(gh.calls.includes('graphql'), false, 'left in draft');
  assert.equal(gh.calls.some((c) => c.endsWith('/merge')), false);
  assert.match(logs.at(-1), /draft/);
});

test('processPr leaves conflicting PRs alone', async () => {
  const gh = fakeGh({ files: [{ filename: 'documentation/x.md' }], pr: { mergeable: false } });
  const logs = [];
  await processPr(gh, 4, { log: (m) => logs.push(m) });
  assert.equal(gh.calls.some((c) => c.endsWith('/merge')), false);
  assert.match(logs[0], /merge conflicts/);
});

test('a [WIP] title is never merged; the rename re-triggers it', async () => {
  for (const t of ['[WIP] Update documentation for notes', '[wip] x', '  [ WIP ] x']) assert.equal(isWorkInProgress(t), true, t);
  for (const t of ['Update documentation for notes', 'Fix [WIP] parsing', '']) assert.equal(isWorkInProgress(t), false, t);
  const gh = fakeGh({ files: [{ filename: 'documentation/x.md' }], pr: { title: '[WIP] Update documentation for x' } });
  const logs = [];
  await processPr(gh, 7, { log: (m) => logs.push(m) });
  assert.equal(gh.calls.some((c) => c.endsWith('/merge')), false);
  assert.match(logs[0], /\[WIP\]/);
});
