'use strict';

// Every workflow that sets up Flutter pins one version, so CI tests and
// deploys build with the same SDK and a new stable release can't reach a
// deploy untested.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const WORKFLOWS = path.resolve(__dirname, '..', '..', '.github', 'workflows');

/** The `with:` block of each subosito/flutter-action step in [text]. */
function flutterSteps(text) {
  const steps = [];
  const pattern = /uses:\s*subosito\/flutter-action@\S+\s*\n(\s+)with:\s*\n((?:\1\s+.*\n|\s*#.*\n)*)/g;
  for (const match of text.matchAll(pattern)) steps.push(match[2]);
  return steps;
}

/** The version a step pins, resolving `${{ env.X }}` against the workflow's env. */
function pinnedVersion(text, block) {
  const raw = (block.match(/^\s+flutter-version:\s*(.+)$/m) || [])[1];
  if (!raw) return null;
  const value = raw.replace(/['"]/g, '').trim();
  const ref = value.match(/^\$\{\{\s*env\.(\w+)\s*\}\}$/);
  if (!ref) return value;
  const defined = text.match(new RegExp(`^\\s+${ref[1]}:\\s*['"]?([^'"\\s]+)`, 'm'));
  return defined ? defined[1] : value;
}

test('every Flutter setup in CI pins the same version', () => {
  const versions = new Map();
  for (const file of fs.readdirSync(WORKFLOWS).filter((f) => /\.ya?ml$/.test(f))) {
    const text = fs.readFileSync(path.join(WORKFLOWS, file), 'utf8');
    for (const block of flutterSteps(text)) {
      const version = pinnedVersion(text, block);
      assert.ok(version, `${file}: a subosito/flutter-action step has no flutter-version`);
      versions.set(`${file}:${versions.size}`, version);
    }
  }
  assert.ok(versions.size >= 2, 'expected the deploy and test workflows to set up Flutter');
  assert.equal(new Set(versions.values()).size, 1, `Flutter versions differ: ${JSON.stringify(Object.fromEntries(versions))}`);
});
