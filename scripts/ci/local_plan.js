#!/usr/bin/env node
/**
 * Plans what scripts/ci/local_check.sh runs: the checks CI would run for
 * this branch's diff against a base ref, decided by the same code CI uses
 * (docs_only_change.js's rule, suite_inputs.js's suite table and
 * flutter_packages.js's package graph), so the local plan and CI's can't
 * drift apart.
 *
 * By default the diff includes uncommitted and untracked files, so the check
 * covers what's about to be committed. --committed diffs only commits, as CI
 * does (base...HEAD).
 *
 * Usage:
 *   node scripts/ci/local_plan.js [--base origin/main] [--committed] [--shards N]
 *
 * Prints key=value lines:
 *   files=<number of changed files>
 *   docs_only=true|false
 *   security=true|false       generate.js --check and the security guards
 *   tier_audit=true|false     scripts/security_tier_audit --diff
 *   node=true|false           scripts/ci/run_node_tests.sh
 *   flutter_root=true|false   analyze lib/ + test/ for the launcher app
 *   rules=true|false          security/rules-tests (opt-in locally)
 *   flutter_count=<n>
 *   flutter_shard=<pkg pkg ...>   one line per shard, for parallel runs
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { suiteAffected } = require('./suite_inputs');
const { docsOnly } = require('./docs_only_change');
const {
  listPackages, reverseDependencies, affectedPackages, shard, packageWeight,
} = require('./flutter_packages');

const ROOT = path.resolve(__dirname, '..', '..');
const PACKAGES_DIR = path.join(ROOT, 'packages');

function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

const lines = (out) => out.split('\n').filter(Boolean);

/**
 * Changed files since the merge base with [base], in GitHub `pulls.listFiles`
 * shape (pubspec.yaml carries its patch, which the docs-only rule reads).
 */
function changedFiles(base, { committed = false } = {}) {
  const mergeBase = git(['merge-base', base, 'HEAD']).trim();
  const target = committed ? [`${mergeBase}...HEAD`] : [mergeBase];
  const names = new Set(lines(git(['diff', '--no-renames', '--name-only', ...target])));
  if (!committed) {
    for (const f of lines(git(['ls-files', '--others', '--exclude-standard']))) names.add(f);
  }
  return [...names].sort().map((filename) => (filename === 'pubspec.yaml'
    ? { filename, patch: git(['diff', '--no-renames', ...target, '--', filename]) }
    : { filename }));
}

/**
 * Pure: what to run for [files] (listFiles shape). Mirrors tests.yml's `plan`
 * job (a docs-only change skips node, flutter_root and the packages), plus
 * the path filter of rules-tests.yml and the tier audit's inputs
 * (pr-checks.yml runs the audit for the same suite), which suite_inputs.js
 * holds and workflow_triggers.test.js keeps equal.
 */
function planChecks(files, { packages, reverse }) {
  const names = files.map((f) => f.filename);
  const docs = names.length > 0 && docsOnly(files).docsOnly;
  const rules = suiteAffected('rules', names);
  const tierAudit = suiteAffected('tier_audit', names);
  let flutterPackages = [];
  if (!docs) {
    const affected = affectedPackages(names, packages, reverse);
    flutterPackages = affected === null ? packages : packages.filter((p) => affected.has(p));
  }
  return {
    files: names.length,
    docsOnly: docs,
    security: rules || tierAudit,
    tierAudit,
    node: !docs && suiteAffected('node', names),
    flutterRoot: !docs && suiteAffected('flutter_root', names),
    rules,
    flutterPackages,
  };
}

function format(plan, shardCount) {
  const out = [
    `files=${plan.files}`,
    `docs_only=${plan.docsOnly}`,
    `security=${plan.security}`,
    `tier_audit=${plan.tierAudit}`,
    `node=${plan.node}`,
    `flutter_root=${plan.flutterRoot}`,
    `rules=${plan.rules}`,
    `flutter_count=${plan.flutterPackages.length}`,
  ];
  for (const s of shard(plan.flutterPackages, shardCount, packageWeight)) out.push(`flutter_shard=${s.packages}`);
  return `${out.join('\n')}\n`;
}

function main(argv) {
  const arg = (name, fallback) => {
    const i = argv.indexOf(name);
    return i === -1 ? fallback : argv[i + 1];
  };
  const base = arg('--base', 'origin/main');
  const shardCount = Number(arg('--shards', 4));
  const packages = listPackages();
  const reverse = reverseDependencies(packages, (p) => fs.readFileSync(path.join(PACKAGES_DIR, p, 'pubspec.yaml'), 'utf8'));
  const files = changedFiles(base, { committed: argv.includes('--committed') });
  process.stdout.write(format(planChecks(files, { packages, reverse }), shardCount));
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

module.exports = { planChecks, changedFiles };
