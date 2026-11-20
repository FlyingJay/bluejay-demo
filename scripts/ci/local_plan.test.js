'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { planChecks } = require('./local_plan');

// A tiny package graph: notes and calendar depend on shared_services.
const packages = ['calendar', 'notes', 'shared_services'];
const reverse = new Map([
  ['shared_services', new Set(['calendar', 'notes'])],
  ['calendar', new Set()],
  ['notes', new Set()],
]);
const plan = (...names) => planChecks(names.map((filename) => ({ filename })), { packages, reverse });

test('an app package change plans that package, node, the root app and the tier audit, but not the rules suite', () => {
  // The tier audit reads app Dart (audited_callables.js), so lib/ changes plan it.
  assert.deepEqual(plan('packages/notes/lib/notes_screen.dart'), {
    files: 1, docsOnly: false, security: true, tierAudit: true, node: true, flutterRoot: true, rules: false,
    flutterPackages: ['notes'],
  });
});

test('a shared package change plans its dependents', () => {
  assert.deepEqual(plan('packages/shared_services/lib/x.dart').flutterPackages, ['calendar', 'notes', 'shared_services']);
});

test('a CI script change plans every package, as flutter_packages.js ALWAYS_ALL does', () => {
  assert.deepEqual(plan('scripts/ci/run_node_tests.sh').flutterPackages, packages);
});

test('a documentation-only change runs nothing', () => {
  const p = plan('documentation/notes/user.md');
  assert.equal(p.docsOnly, true);
  assert.deepEqual([p.node, p.flutterRoot, p.rules, p.security, p.flutterPackages.length], [false, false, false, false, 0]);
});

test('the policy table plans the security checks, the tier audit and the rules suite', () => {
  const p = plan('security/collections.json');
  assert.deepEqual([p.security, p.tierAudit, p.rules, p.node, p.flutterRoot], [true, true, true, true, false]);
});

test('a functions test file plans node and the tier audit (exerciseAuditedWrites credits callables); a top-level functions file also the rules', () => {
  const t = plan('functions/_dev_changes.test.js');
  assert.deepEqual([t.node, t.tierAudit, t.rules], [true, true, false]);
  const f = plan('functions/_shared.js');
  assert.deepEqual([f.node, f.tierAudit, f.rules, f.security], [true, true, true, true]);
});

test('no changes plan nothing', () => {
  const p = plan();
  assert.deepEqual([p.files, p.docsOnly, p.node, p.flutterRoot, p.flutterPackages.length], [0, false, false, false, 0]);
});
