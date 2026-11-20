'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { ALWAYS_ALL } = require('./flutter_packages');
const {
  SUITES, globToRegExp, suiteReads, suiteAffected, nightlyDecision,
} = require('./suite_inputs');

const ROOT = path.resolve(__dirname, '..', '..');

test('globs follow GitHub paths syntax', () => {
  assert.ok(globToRegExp('security/**').test('security/rules-tests/a.js'));
  assert.ok(!globToRegExp('security/**').test('securityx/a.js'));
  assert.ok(globToRegExp('packages/*/bluejay_app.json').test('packages/notes/bluejay_app.json'));
  assert.ok(!globToRegExp('packages/*/bluejay_app.json').test('packages/notes/lib/bluejay_app.json'));
  assert.ok(globToRegExp('firebase.json').test('firebase.json'));
  assert.ok(!globToRegExp('firebase.json').test('firebaseXjson'));
});

test('node runs for any Dart, functions, scripts or docs change, and skips platform-only changes', () => {
  for (const file of [
    'functions/x.js', 'scripts/check_gateways.js', 'security/collections.json', 'demo/seed/notes.js',
    'packages/notes/lib/notes_screen.dart', 'packages/notes/pubspec.yaml', 'lib/routing/app_router.dart', 'web/index.html',
    'firebase.json', 'firestore.rules', 'SECRETS.md', 'documentation/notes/developer.md',
    '.github/workflows/tests.yml', 'scripts/ci/suite_inputs.js', 'mail-proxy/index.js',
  ]) {
    assert.equal(suiteReads('node', file), true, file);
  }
  for (const file of [
    'test/favorites_dock_test.dart', 'assets/images/logo.png', 'ios/Runner/Info.plist',
    'plans/development-queue/README.md',
    'documentation/.pending_doc_changes.json',
  ]) {
    assert.equal(suiteReads('node', file), false, file);
  }
});

test('flutter_root runs for app, package and docs changes, and skips backend-only changes', () => {
  for (const file of [
    'lib/main.dart', 'test/favorites_dock_test.dart', 'packages/notes/lib/x.dart', 'pubspec.yaml',
    'analysis_options.yaml', 'assets/a.png', 'documentation/wiki/user.md',
    '.github/workflows/tests.yml', 'scripts/ci/flutter_packages.js',
  ]) {
    assert.equal(suiteReads('flutter_root', file), true, file);
  }
  for (const file of [
    'functions/_shared.js', 'security/collections.json', 'firestore.rules', 'scripts/check_gateways.js',
    '.github/workflows/deploy.yml', 'documentation/.docs_batch_processed.json',
  ]) {
    assert.equal(suiteReads('flutter_root', file), false, file);
  }
  assert.equal(suiteAffected('flutter_root', ['functions/a.js', 'firestore.rules']), false);
  assert.equal(suiteAffected('flutter_root', ['functions/a.js', 'lib/a.dart']), true);
});

test('the flutter suite reads what flutter_packages.js plans on', () => {
  for (const prefix of ALWAYS_ALL) {
    const file = prefix.endsWith('/') ? `${prefix}x.js` : prefix;
    assert.equal(suiteReads('flutter', file), true, file);
  }
  assert.equal(suiteReads('flutter', 'packages/notes/lib/x.dart'), true);
  assert.equal(suiteReads('flutter', 'functions/x.js'), false);
});

test('nightly: skips only when a successful run exists and nothing relevant changed', () => {
  const previous = { sha: 'abcdef1234567' };
  const base = { suites: ['rules'], previous, weekday: 3 };
  assert.equal(nightlyDecision({ ...base, changed: [] }).run, false);
  assert.equal(nightlyDecision({ ...base, changed: ['lib/main.dart', 'documentation/a.md'] }).run, false);
  assert.equal(nightlyDecision({ ...base, changed: ['lib/main.dart', 'security/collections.json'] }).run, true);
  assert.equal(nightlyDecision({ ...base, previous: null, changed: null }).run, true);
  assert.equal(nightlyDecision({ ...base, changed: null }).run, true);
  assert.equal(nightlyDecision({ ...base, changed: [], fullOnWeekday: 3 }).run, true);
  assert.equal(nightlyDecision({ ...base, changed: [], fullOnWeekday: 0 }).run, false);
  // Documentation bookkeeping commits alone never wake the Tests nightly.
  assert.equal(nightlyDecision({
    suites: ['node', 'flutter', 'flutter_root'], previous, weekday: 3,
    changed: ['documentation/.pending_doc_changes.json', 'documentation/.docs_batch_processed.json'],
  }).run, false);
});

/** Node test files, as scripts/ci/run_node_tests.sh finds them. */
function nodeTestFiles() {
  const out = [];
  for (const dir of ['functions', 'functions/test', 'functions/scripts']) {
    for (const f of fs.readdirSync(path.join(ROOT, dir))) if (f.endsWith('.test.js')) out.push(path.join(dir, f));
  }
  const walk = (dir) => {
    for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
      const rel = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name !== 'node_modules' && rel !== path.join('security', 'rules-tests')) walk(rel);
      } else if (e.name.endsWith('.test.js')) out.push(rel);
    }
  };
  walk('scripts');
  walk('security');
  return out;
}

test('every repo file a Node test reads by a literal path is a node input', () => {
  // path.join(__dirname, '..', 'packages', 'shared_services', ...) and similar.
  const literal = /path\.(?:join|resolve)\(\s*__dirname((?:\s*,\s*'[^']*')+)\s*\)/g;
  let checked = 0;
  for (const file of nodeTestFiles()) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    for (const m of text.matchAll(literal)) {
      const parts = [...m[1].matchAll(/'([^']*)'/g)].map((p) => p[1]);
      const rel = path.relative(ROOT, path.resolve(ROOT, path.dirname(file), ...parts));
      if (rel.startsWith('..') || !fs.existsSync(path.join(ROOT, rel))) continue;
      const probe = fs.statSync(path.join(ROOT, rel)).isDirectory() ? `${rel}/x` : rel;
      assert.equal(suiteReads('node', probe), true, `${file} reads ${rel}, which SUITES.node.allExcept skips`);
      checked += 1;
    }
  }
  assert.ok(checked > 10, `only ${checked} literal paths found; did the pattern break?`);
});

test('every documentation/ file a root Flutter test names is a flutter_root input', () => {
  for (const f of fs.readdirSync(path.join(ROOT, 'test'))) {
    if (!f.endsWith('.dart')) continue;
    const text = fs.readFileSync(path.join(ROOT, 'test', f), 'utf8');
    for (const m of text.matchAll(/'(documentation\/[^'$]+)'/g)) {
      assert.equal(suiteReads('flutter_root', m[1]), true, `test/${f} reads ${m[1]}`);
    }
  }
});

test('every suite is well formed', () => {
  for (const [name, spec] of Object.entries(SUITES)) {
    assert.ok(Boolean(spec.inputs) !== Boolean(spec.allExcept), `${name}: exactly one of inputs / allExcept`);
    for (const g of [...(spec.inputs || []), ...(spec.allExcept || []), ...(spec.except || [])]) {
      assert.ok(!g.startsWith('/') && !g.startsWith('./'), `${name}: ${g} must be repo-relative`);
    }
  }
});
