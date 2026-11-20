'use strict';

// Runs the self-hosted runner's shell tests (infra/ci-runner/tests) and, when
// shellcheck is installed, lints every runner script. They live here so the
// Node suite (scripts/ci/run_node_tests.sh) picks them up without a workflow
// change.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { spawnSync } = require('child_process');

const DIR = path.resolve(__dirname, '..', '..', 'infra', 'ci-runner');
const SCRIPTS = [
  'bootstrap.sh',
  'bin/bluejay-runner',
  'lib/lib.sh',
  'image/entrypoint.sh',
  'tests/lib_test.sh',
  'tests/fake-bin/curl',
];

function has(cmd) {
  return spawnSync('sh', ['-c', `command -v ${cmd}`]).status === 0;
}

test('runner library tests pass', { skip: !(has('jq') && has('openssl')) && 'needs jq and openssl' }, () => {
  const r = spawnSync('bash', [path.join(DIR, 'tests', 'lib_test.sh')], { encoding: 'utf8' });
  assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
});

test('runner scripts are shellcheck-clean', { skip: !has('shellcheck') && 'shellcheck not installed' }, () => {
  const r = spawnSync('shellcheck', ['-x', ...SCRIPTS], { cwd: DIR, encoding: 'utf8' });
  assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
});
