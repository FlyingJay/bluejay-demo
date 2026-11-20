'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { loadStorageTable } = require('./generate_storage');
const { JSON_PATH, loadRawCollectionsTable, collectionsSlice, familiesSlice, renderJson } = require('./generate_preview_sandbox');

test('functions/_preview_sandbox_tables.json is up to date (run `node security/generate.js`)', () => {
  assert.equal(fs.readFileSync(JSON_PATH, 'utf8'), renderJson(loadRawCollectionsTable(), loadStorageTable()));
});

test('the slice keeps only kind, subcollections and their serverWritten flag', () => {
  const out = collectionsSlice({ collections: {
    b: { kind: 'personal', apps: ['x'], subcollections: { metadata: { serverWritten: true, comment: 'c' }, prefs: { selfKeyed: {} } } },
    a: { apps: ['y'], memberWrite: true },
  } });
  assert.deepEqual(Object.keys(out), ['a', 'b']);
  assert.deepEqual(out.a, {});
  assert.deepEqual(out.b, { kind: 'personal', subcollections: { metadata: { serverWritten: true }, prefs: {} } });
});

test('the families slice keeps paths and the migrate flag', () => {
  assert.deepEqual(familiesSlice({ families: { f: { paths: ['groups/{groupId}/x/**'], read: 'member' }, g: { migrate: true } } }),
    { f: { paths: ['groups/{groupId}/x/**'] }, g: { paths: [], migrate: true } });
});
