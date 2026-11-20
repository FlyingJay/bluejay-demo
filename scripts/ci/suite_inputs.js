#!/usr/bin/env node
/**
 * Which CI suites a change can affect, from one table of each suite's
 * inputs. tests.yml's `plan` job uses it to skip `node` and `flutter_root`
 * on PRs that change nothing they read, both nightly suites (Tests and
 * Rules tests) use it to skip a night when main has no relevant commits
 * since the last successful scheduled run, and scripts/ci/local_plan.js
 * uses it to plan scripts/ci/local_check.sh.
 *
 * A suite lists either `inputs` (globs it reads; anything else can't affect
 * it) or `allExcept` (globs it never reads; anything else can). Globs follow
 * GitHub's `paths` syntax: `*` stays within a path segment, `**` crosses
 * segments. Use `allExcept` when the suite reads widely: the Node suite
 * scans every Dart file in lib/ and packages/ (check_gateways,
 * check_server_collections, check_app_ids, check_design_tokens), the docs
 * under documentation/ and the workflows, so listing its inputs would miss
 * some. A wrong entry there only runs the suite when it didn't need to.
 *
 * Usage:
 *   node scripts/ci/suite_inputs.js changed --base <ref> --suites node,flutter_root
 *     Prints `<suite>=true|false` per suite for the files changed since the
 *     merge base with <ref>.
 *   node scripts/ci/suite_inputs.js nightly --workflow tests.yml --suites node,flutter
 *       [--full-on-weekday 0]
 *     Prints `run=true|false`: false only when the workflow has a successful
 *     scheduled run on main and no file any listed suite reads changed since
 *     its commit. Needs GH_TOKEN (actions: read) and full git history. Any
 *     error prints `run=true`: a missed skip costs minutes, a wrong skip
 *     costs coverage. --full-on-weekday N (0 = Sunday, UTC) always runs on
 *     that day, so tests that rot with the date still run weekly.
 */

'use strict';

const path = require('path');
const { execFileSync } = require('child_process');
const { ALWAYS_ALL } = require('./flutter_packages');

const ROOT = path.resolve(__dirname, '..', '..');

/** Changes to these always run the suites tests.yml plans. */
const TESTS_WORKFLOW_INPUTS = ['.github/workflows/tests.yml', 'scripts/ci/**'];

/** The documentation bookkeeping files agentic-docs-on-main.yml commits; no test reads them. */
const DOCS_BOOKKEEPING = [
  'documentation/.pending_doc_changes.json',
  'documentation/.docs_batch_processed.json',
];

const SUITES = {
  // tests.yml `node`: scripts/ci/run_node_tests.sh.
  node: {
    allExcept: [
      'test/**',
      'assets/**',
      'android/**',
      'ios/**',
      'linux/**',
      'macos/**',
      'windows/**',
      'plans/**',
      ...DOCS_BOOKKEEPING,
    ],
  },
  // tests.yml `flutter_root`: analyze lib/ and run test/ for the launcher app,
  // which depends on packages/ by path. Several root tests read
  // documentation/ (documentation_assets_test and the *_documentation_test
  // files).
  flutter_root: {
    inputs: [
      ...TESTS_WORKFLOW_INPUTS,
      'lib/**',
      'test/**',
      'packages/**',
      'assets/**',
      'web/**',
      'pubspec.yaml',
      'pubspec.lock',
      'analysis_options.yaml',
      'documentation/**',
    ],
    except: DOCS_BOOKKEEPING,
  },
  // tests.yml `flutter`: the packages, planned per package by
  // flutter_packages.js (whose ALWAYS_ALL plans every package).
  flutter: {
    inputs: [
      'packages/**',
      ...ALWAYS_ALL.map((p) => (p.endsWith('/') ? `${p}**` : p)),
    ],
  },
  // rules-tests.yml: must equal its pull_request `paths` (workflow_triggers.test.js).
  rules: {
    inputs: [
      'firestore.rules',
      'storage.rules',
      'firebase.json',
      'security/**',
      'packages/shared_services/lib/generated/**',
      'functions/_shared.js',
      'functions/access_control.js',
      'functions/_guest_admission.js',
      'functions/_guest_identity.js',
      'functions/_corporate_access.js',
      'functions/_tenant_ids.js',
      'functions/_platform_access.js',
      '.github/workflows/rules-tests.yml',
    ],
  },
  // The security tier audit: pr-checks.yml runs it on a PR that changes one
  // of these, and the deploy train's security_audit target has the same
  // paths (workflow_triggers.test.js).
  tier_audit: {
    inputs: [
      'security/collections.json',
      'security/collections.schema.json',
      'security/generate.js',
      'security/storage_paths.json',
      'security/generate_storage.js',
      'functions/*.js',
      'documentation/feature_doc_mapping.json',
      'scripts/registered_app_ids.json',
      'scripts/security_tier_audit/**',
      'packages/*/lib/**',
    ],
  },
};

const globCache = new Map();

/** A GitHub `paths` glob as a RegExp over repo-relative paths. */
function globToRegExp(glob) {
  if (!globCache.has(glob)) {
    let re = '';
    for (let i = 0; i < glob.length; i++) {
      const c = glob[i];
      if (c === '*' && glob[i + 1] === '*') {
        re += '.*';
        i += 1;
      } else if (c === '*') {
        re += '[^/]*';
      } else {
        re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
      }
    }
    globCache.set(glob, new RegExp(`^${re}$`));
  }
  return globCache.get(glob);
}

const matchesAny = (file, globs) => globs.some((g) => globToRegExp(g).test(file));

/** Whether [file] (repo-relative) can affect [suite]. */
function suiteReads(suite, file) {
  const spec = SUITES[suite];
  if (!spec) throw new Error(`unknown suite: ${suite}`);
  if (spec.allExcept) return !matchesAny(file, spec.allExcept);
  return matchesAny(file, spec.inputs) && !matchesAny(file, spec.except || []);
}

/** Whether any of [files] can affect [suite]. */
function suiteAffected(suite, files) {
  return files.some((file) => suiteReads(suite, file));
}

function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}

/** Files changed between [from] and HEAD; with [mergeBase], since their merge base. */
function changedFiles(from, { mergeBase = false } = {}) {
  const range = mergeBase ? `${from}...HEAD` : `${from}..HEAD`;
  return git(['diff', '--no-renames', '--name-only', range]).split('\n').filter(Boolean);
}

/** The newest successful scheduled run of [workflow] on main, or null. */
function lastSuccessfulScheduledRun(workflow) {
  const repo = process.env.GITHUB_REPOSITORY;
  if (!repo) throw new Error('GITHUB_REPOSITORY is not set');
  const out = execFileSync('gh', [
    'api',
    `repos/${repo}/actions/workflows/${workflow}/runs?event=schedule&status=success&branch=main&per_page=1`,
  ], { encoding: 'utf8' });
  const run = (JSON.parse(out).workflow_runs || [])[0];
  return run ? { sha: run.head_sha, id: run.id, createdAt: run.created_at } : null;
}

/**
 * Pure: whether a nightly run should go ahead. [previous] is the last
 * successful scheduled run ({ sha }) or null; [changed] is the files changed
 * since its commit, or null when that couldn't be computed.
 */
function nightlyDecision({ suites, previous, changed, weekday, fullOnWeekday }) {
  if (fullOnWeekday !== undefined && weekday === fullOnWeekday) return { run: true, reason: 'weekly full run' };
  if (!previous) return { run: true, reason: 'no earlier successful scheduled run' };
  if (!changed) return { run: true, reason: `could not diff against ${previous.sha}` };
  const relevant = changed.filter((file) => suites.some((s) => suiteReads(s, file)));
  if (relevant.length) {
    return { run: true, reason: `${relevant.length} relevant file(s) changed since ${previous.sha.slice(0, 7)}, e.g. ${relevant[0]}` };
  }
  return { run: false, reason: `nothing ${suites.join('/')} reads changed since ${previous.sha.slice(0, 7)}` };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const arg = (name) => {
    const i = rest.indexOf(name);
    return i === -1 ? undefined : rest[i + 1];
  };
  const suites = (arg('--suites') || '').split(',').map((s) => s.trim()).filter(Boolean);
  for (const s of suites) if (!SUITES[s]) throw new Error(`unknown suite: ${s}`);
  if (!suites.length) throw new Error('--suites is required');
  return { command, arg, suites };
}

function main(argv) {
  const { command, arg, suites } = parseArgs(argv);
  if (command === 'changed') {
    const base = arg('--base');
    if (!base) throw new Error('changed needs --base <ref>');
    const files = changedFiles(base, { mergeBase: true });
    for (const suite of suites) {
      const affected = suiteAffected(suite, files);
      process.stdout.write(`${suite}=${affected}\n`);
      console.error(`${suite}=${affected} (${files.length} changed file(s))`);
    }
    return;
  }
  if (command === 'nightly') {
    const workflow = arg('--workflow');
    if (!workflow) throw new Error('nightly needs --workflow <file>');
    const weekdayArg = arg('--full-on-weekday');
    let decision;
    try {
      const previous = lastSuccessfulScheduledRun(workflow);
      let changed = null;
      if (previous) {
        try {
          changed = changedFiles(previous.sha);
        } catch (error) {
          console.error(`git diff against ${previous.sha} failed: ${error.message}`);
        }
      }
      decision = nightlyDecision({
        suites,
        previous,
        changed,
        weekday: new Date().getUTCDay(),
        fullOnWeekday: weekdayArg === undefined ? undefined : Number(weekdayArg),
      });
    } catch (error) {
      decision = { run: true, reason: `check failed, running anyway: ${error.message}` };
    }
    process.stdout.write(`run=${decision.run}\n`);
    console.error(`run=${decision.run} (${decision.reason})`);
    return;
  }
  throw new Error('usage: suite_inputs.js (changed --base <ref> | nightly --workflow <file>) --suites a,b');
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

module.exports = {
  SUITES,
  DOCS_BOOKKEEPING,
  globToRegExp,
  suiteReads,
  suiteAffected,
  nightlyDecision,
};
