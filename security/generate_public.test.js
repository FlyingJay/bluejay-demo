'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { loadTable } = require('./generate');
const { JSON_PATH, publicCollections, projectionVersion, renderJson, DEFAULT_MAX_BYTES } = require('./generate_public');

test('functions/_public_collections.json is up to date (run `node security/generate.js`)', () => {
  assert.equal(fs.readFileSync(JSON_PATH, 'utf8'), renderJson(loadTable()));
});

test('every public entry reaches the server with its source app scope and defaults', () => {
  const table = { collections: {
    a: { apps: ['app-a'], publishTo: 'public_a' },
    public_a: { kind: 'public', source: 'a', projection: ['x', 'f'], fileFields: ['f'] },
    b: {},
  } };
  const out = publicCollections(table);
  assert.deepEqual(Object.keys(out), ['public_a']);
  assert.deepEqual(out.public_a, {
    source: 'a', apps: ['app-a'], projection: ['x', 'f'], publishTier: 'edit', publishWhen: {}, requiredFields: [],
    fileFields: ['f'], maxBytes: DEFAULT_MAX_BYTES, projectionVersion: out.public_a.projectionVersion,
  });
});

test('projectionVersion changes with the projection or the file fields, nothing else', () => {
  const base = { projection: ['x'], fileFields: [], publishTier: 'edit' };
  assert.equal(projectionVersion(base), projectionVersion({ ...base, publishTier: 'owner' }));
  assert.notEqual(projectionVersion(base), projectionVersion({ ...base, projection: ['x', 'y'] }));
  assert.notEqual(projectionVersion(base), projectionVersion({ ...base, fileFields: ['x'] }));
});

test('the marketplace and Storage app publish what the plan names (2.7)', () => {
  const out = publicCollections(loadTable());
  assert.deepEqual(Object.keys(out).sort(), ['public_files', 'public_vendor_market_categories', 'public_vendor_market_listings']);
  assert.equal(out.public_vendor_market_listings.publishWhen.status, 'published');
  assert.deepEqual(out.public_vendor_market_listings.fileFields, ['photoUrls']);
  assert.equal(out.public_files.publishTier, 'owner');
  for (const cfg of Object.values(out)) {
    for (const f of ['groupId', 'appId', 'creatorId', 'ownerIds']) assert.ok(!cfg.projection.includes(f), f);
  }
});
