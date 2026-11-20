'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  listPackages,
  pathDependencies,
  reverseDependencies,
  withDependents,
  affectedPackages,
  shard,
} = require('./flutter_packages');

const PUBSPECS = {
  shared_services: 'name: shared_services\n',
  shared_ui: 'dependencies:\n  shared_services:\n    path: ../shared_services\n',
  groups: 'dependencies:\n  shared_ui:\n    path: ../shared_ui\n',
  rented_dwelling: "dependencies:\n  groups:\n    path: '../groups'\n  shared_services:\n    path: ../shared_services/\n",
  calendar: 'dependencies:\n  intl: ^0.20.2\n',
};
const packages = Object.keys(PUBSPECS).sort();
const reverse = reverseDependencies(packages, (p) => PUBSPECS[p]);

test('reads sibling path dependencies only', () => {
  assert.deepEqual([...pathDependencies(PUBSPECS.rented_dwelling)].sort(), ['groups', 'shared_services']);
  assert.deepEqual([...pathDependencies('flutter:\n  sdk: flutter\nfoo:\n  path: packages/foo\n')], []);
});

test('a change re-checks its transitive dependents', () => {
  assert.deepEqual([...withDependents(['shared_ui'], reverse)].sort(), ['groups', 'rented_dwelling', 'shared_ui']);
  assert.deepEqual([...withDependents(['calendar'], reverse)], ['calendar']);
});

test('maps changed files to packages; CI config changes plan everything', () => {
  assert.deepEqual(
    [...affectedPackages(['packages/groups/lib/x.dart', 'functions/x.js', 'README.md'], packages, reverse)].sort(),
    ['groups', 'rented_dwelling'],
  );
  assert.deepEqual([...affectedPackages(['functions/x.js'], packages, reverse)], []);
  assert.equal(affectedPackages(['scripts/ci/flutter_packages.js'], packages, reverse), null);
  assert.equal(affectedPackages(['.github/workflows/tests.yml'], packages, reverse), null);
  assert.equal(affectedPackages(['analysis_options.yaml'], packages, reverse), null);
});

test('shards balance cost and cover every package once', () => {
  const weights = { a: 10, b: 9, c: 2, d: 2, e: 1 };
  const shards = shard(Object.keys(weights), 2, (p) => weights[p]);
  assert.equal(shards.length, 2);
  const all = shards.flatMap((s) => s.packages.split(' ')).sort();
  assert.deepEqual(all, ['a', 'b', 'c', 'd', 'e']);
  assert.deepEqual(shard([], 4, () => 1), []);
  assert.equal(shard(['a'], 4, () => 1).length, 1);
});

test('lists the real repo packages', () => {
  const real = listPackages();
  assert.ok(real.includes('shared_services'));
  assert.ok(real.length > 50);
});
