'use strict';

/**
 * Every `appId` written as a string literal, in Cloud Functions or in app
 * code, names a registered app. A doc stamped with an unregistered id (Convo
 * Starter's server-written history said 'convo_starter' where the app is
 * 'convo-starter') falls outside the app's queries, rules and usage
 * attribution without any error.
 *
 * Known ids are each package's `APP_ID` (packages/<pkg>/lib/constants.dart)
 * plus every app named in security/collections.json. A literal that is
 * deliberately not an app id goes in ALLOWED with the reason.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');

const ALLOWED = {
  me: 'the profile screen\'s pseudo app id (profile pictures, storage attribution)',
  parser: 'Parser\'s AI metering id (packages/parser has no constants.dart)',
  'exchange-rates': 'Exchange Rates\' registered id (packages/exchange has no constants.dart)',
  recorder: 'storage attribution for a removed app whose files are still in the bucket',
  'video-editor': 'storage attribution for a removed app whose files are still in the bucket',
  '*': 'Automations\' engine-wide event types (record.*, schedule.fired), which belong to no single app',
  '~unmetered': 'metered_firestore\'s sentinel for reads charged to no app',
};

function knownAppIds() {
  const ids = new Set();
  const policy = JSON.parse(fs.readFileSync(path.join(ROOT, 'security', 'collections.json'), 'utf8'));
  for (const entry of Object.values(policy.collections)) {
    for (const app of entry.apps || []) ids.add(app);
  }
  for (const pkg of fs.readdirSync(path.join(ROOT, 'packages'))) {
    const file = path.join(ROOT, 'packages', pkg, 'lib', 'constants.dart');
    if (!fs.existsSync(file)) continue;
    const match = fs.readFileSync(file, 'utf8').match(/APP_ID\s*=\s*'([^']+)'/);
    if (match) ids.add(match[1]);
  }
  return ids;
}

function walk(dir, ext, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.') || entry.name === 'build') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, ext, out);
    else if (entry.name.endsWith(ext) && !entry.name.includes('.test.') && !entry.name.endsWith('_test.dart')) out.push(full);
  }
  return out;
}

function sourceFiles() {
  const files = fs.readdirSync(path.join(ROOT, 'functions'))
    .filter((f) => f.endsWith('.js') && !f.includes('.test.'))
    .map((f) => path.join(ROOT, 'functions', f));
  files.push(...walk(path.join(ROOT, 'lib'), '.dart'));
  for (const pkg of fs.readdirSync(path.join(ROOT, 'packages'))) {
    const lib = path.join(ROOT, 'packages', pkg, 'lib');
    if (fs.existsSync(lib)) files.push(...walk(lib, '.dart'));
  }
  return files;
}

/** `appId: 'x'`, `'appId': 'x'`, `appId = 'x'`, `APP_ID = 'x'` (JS objects, Dart maps, named args, constants). */
const LITERAL = /['"]?\b(?:appId|APP_ID)['"]?\s*[:=]\s*['"]([^'"$]+)['"]/g;

function findLiterals(source) {
  const found = [];
  source.split('\n').forEach((line, i) => {
    for (const m of line.matchAll(LITERAL)) found.push({ line: i + 1, value: m[1] });
  });
  return found;
}

test('findLiterals reads JS, Dart map and named-argument forms', () => {
  const src = "x({ appId: 'a' });\nfinal m = {'appId': 'b'};\nconst appId = 'c';\nconst APP_ID = 'd';\nappId: \"$id\"";
  assert.deepEqual(findLiterals(src).map((f) => f.value), ['a', 'b', 'c', 'd']);
});

test('every appId string literal names a registered app', () => {
  const known = knownAppIds();
  assert.ok(known.has('convo-starter'), 'the known-id sources should include convo-starter');
  const bad = [];
  for (const file of sourceFiles()) {
    for (const { line, value } of findLiterals(fs.readFileSync(file, 'utf8'))) {
      if (!known.has(value) && !(value in ALLOWED)) bad.push(`${path.relative(ROOT, file)}:${line}: '${value}'`);
    }
  }
  assert.deepEqual(bad, [], 'appId literals that are not a registered app id (use the package APP_ID, or add to ALLOWED with a reason)');
});
