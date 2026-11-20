#!/usr/bin/env node
/**
 * Plans which Flutter packages CI checks (`flutter analyze` + `flutter test`)
 * and splits them into balanced shards for a job matrix.
 *
 * Packages are every `packages/<name>/` with a pubspec.yaml. The dependency
 * graph comes from their `path:` dependencies, so a change to a package also
 * re-checks every package that (transitively) depends on it — a change to
 * shared_services re-checks nearly everything, a change to one app checks
 * just that app.
 *
 * Usage:
 *   node scripts/ci/flutter_packages.js plan --all --shards 6
 *   node scripts/ci/flutter_packages.js plan --base <git-ref> --shards 6
 *
 * Prints GitHub Actions outputs (key=value lines, append to $GITHUB_OUTPUT):
 *   shards=[{"name":"1","packages":"calendar groups"}, ...]   (JSON)
 *   count=<number of packages planned>
 *
 * With --base, files changed since the merge base decide what runs; a change
 * to anything under ALWAYS_ALL (this script, the workflow, the shared lint
 * config) plans every package.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const PACKAGES_DIR = path.join(ROOT, 'packages');

/** Changed paths (prefixes) that re-check every package. */
const ALWAYS_ALL = [
  '.github/workflows/tests.yml',
  'scripts/ci/',
  'analysis_options.yaml',
];

/** Every package name with a pubspec.yaml. */
function listPackages(packagesDir = PACKAGES_DIR) {
  return fs
    .readdirSync(packagesDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && fs.existsSync(path.join(packagesDir, e.name, 'pubspec.yaml')))
    .map((e) => e.name)
    .sort();
}

/** Sibling packages [pubspecText] depends on through `path: ../<name>`. */
function pathDependencies(pubspecText) {
  const deps = new Set();
  for (const m of pubspecText.matchAll(/^\s*path:\s*['"]?\.\.\/([A-Za-z0-9_]+)\/?['"]?\s*$/gm)) {
    deps.add(m[1]);
  }
  return deps;
}

/** name → Set of packages that depend on it directly. */
function reverseDependencies(packages, readPubspec) {
  const reverse = new Map(packages.map((p) => [p, new Set()]));
  for (const pkg of packages) {
    for (const dep of pathDependencies(readPubspec(pkg))) {
      if (reverse.has(dep)) reverse.get(dep).add(pkg);
    }
  }
  return reverse;
}

/** [changed] packages plus everything that transitively depends on them. */
function withDependents(changed, reverse) {
  const out = new Set();
  const queue = [...changed];
  while (queue.length) {
    const pkg = queue.pop();
    if (out.has(pkg) || !reverse.has(pkg)) continue;
    out.add(pkg);
    queue.push(...reverse.get(pkg));
  }
  return out;
}

/**
 * Packages to check for [changedFiles] (repo-relative paths), or null when
 * a change affects every package.
 */
function affectedPackages(changedFiles, packages, reverse) {
  const changed = new Set();
  for (const file of changedFiles) {
    if (ALWAYS_ALL.some((prefix) => file === prefix || file.startsWith(prefix))) return null;
    const m = file.match(/^packages\/([^/]+)\//);
    if (m && packages.includes(m[1])) changed.add(m[1]);
  }
  return withDependents(changed, reverse);
}

/**
 * Splits [packages] into at most [count] shards of similar cost (greedy,
 * heaviest first). [weight] estimates a package's cost.
 */
function shard(packages, count, weight) {
  const shards = Array.from({ length: Math.max(1, Math.min(count, packages.length)) }, () => ({
    cost: 0,
    packages: [],
  }));
  const sorted = [...packages].sort((a, b) => weight(b) - weight(a) || a.localeCompare(b));
  for (const pkg of sorted) {
    const lightest = shards.reduce((min, s) => (s.cost < min.cost ? s : min), shards[0]);
    lightest.packages.push(pkg);
    lightest.cost += weight(pkg);
  }
  return shards
    .filter((s) => s.packages.length)
    .map((s, i) => ({ name: String(i + 1), packages: s.packages.sort().join(' ') }));
}

/** Rough cost: pub get + analyze, plus a share per test file. */
function packageWeight(pkg) {
  const testDir = path.join(PACKAGES_DIR, pkg, 'test');
  let tests = 0;
  const walk = (dir) => {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) walk(path.join(dir, e.name));
      else if (e.name.endsWith('_test.dart')) tests += 1;
    }
  };
  walk(testDir);
  return 3 + tests;
}

function changedFilesSince(base) {
  const out = execFileSync('git', ['diff', '--name-only', `${base}...HEAD`], { cwd: ROOT, encoding: 'utf8' });
  return out.split('\n').filter(Boolean);
}

function main(argv) {
  const [command, ...rest] = argv;
  if (command !== 'plan') {
    console.error('usage: flutter_packages.js plan (--all | --base <ref>) [--shards N]');
    process.exit(2);
  }
  const arg = (name) => {
    const i = rest.indexOf(name);
    return i === -1 ? undefined : rest[i + 1];
  };
  const shardCount = Number(arg('--shards') || 6);
  const packages = listPackages();
  let planned = packages;
  if (!rest.includes('--all')) {
    const base = arg('--base');
    if (!base) {
      console.error('plan needs --all or --base <ref>');
      process.exit(2);
    }
    const reverse = reverseDependencies(packages, (p) =>
      fs.readFileSync(path.join(PACKAGES_DIR, p, 'pubspec.yaml'), 'utf8'),
    );
    const affected = affectedPackages(changedFilesSince(base), packages, reverse);
    planned = affected === null ? packages : packages.filter((p) => affected.has(p));
  }
  const shards = shard(planned, shardCount, packageWeight);
  process.stdout.write(`shards=${JSON.stringify(shards)}\ncount=${planned.length}\n`);
  console.error(`Planned ${planned.length}/${packages.length} package(s) in ${shards.length} shard(s).`);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  ALWAYS_ALL,
  listPackages,
  pathDependencies,
  reverseDependencies,
  withDependents,
  affectedPackages,
  shard,
  packageWeight,
};
