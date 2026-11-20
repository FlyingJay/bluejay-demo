#!/usr/bin/env node
/**
 * Whether the changes since a base ref are documentation-only, by the same
 * rule the docs auto-merge uses (classifyFiles in docs_pr_automerge.js:
 * documentation/ files, plus pubspec.yaml changes that only add/remove
 * `- documentation/<dir>/` asset lines). tests.yml's `plan` job uses it to
 * skip the Node and Flutter suites on docs-only PRs; nothing a docs-only PR
 * can change is covered by them. A bad pubspec asset line breaks the web
 * build, which deploy.yml's build still checks (it runs on pubspec.yaml).
 *
 * Works from local git (no API calls): renames are split into a delete and
 * an add, so moving code into documentation/ counts as a code change.
 *
 * Usage: node scripts/ci/docs_only_change.js --base <git-ref>
 * Prints `docs_only=true|false` (append to $GITHUB_OUTPUT).
 */

'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const { classifyFiles } = require('./docs_pr_automerge');

const ROOT = path.resolve(__dirname, '..', '..');

function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

/** Changed files since `base`'s merge base, in GitHub `pulls.listFiles` shape. */
function changedFilesSince(base) {
  const range = `${base}...HEAD`;
  const names = git(['diff', '--no-renames', '--name-only', range]).split('\n').filter(Boolean);
  return names.map((filename) => (filename === 'pubspec.yaml'
    ? { filename, patch: git(['diff', '--no-renames', range, '--', filename]) }
    : { filename }));
}

/** { docsOnly, reason } for a list of changed files. */
function docsOnly(files) {
  const c = classifyFiles(files);
  return { docsOnly: c.eligible, reason: c.reason };
}

function main(argv) {
  const i = argv.indexOf('--base');
  const base = i === -1 ? undefined : argv[i + 1];
  if (!base) {
    console.error('usage: docs_only_change.js --base <git-ref>');
    process.exit(2);
  }
  const result = docsOnly(changedFilesSince(base));
  process.stdout.write(`docs_only=${result.docsOnly}\n`);
  console.error(`docs_only=${result.docsOnly} (${result.reason})`);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { changedFilesSince, docsOnly };
