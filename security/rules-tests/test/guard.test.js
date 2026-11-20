'use strict';
/**
 * Keeps the model honest without the emulator: lib/expected.js must model
 * every match block firestore.rules has, and the matrix must cover every
 * table entry, every dedicated block and the undeclared default.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const gen = require('../../generate');
const { generateMatrix, equivalenceClasses } = require('../lib/generate_matrix');
const { FIRESTORE_RULES } = require('../lib/personas');
const W = require('../lib/world');

/** Dedicated top-level blocks lib/expected.js models (besides the generic ones). */
const MODELLED_OWN_BLOCKS = [];

test('every top-level match block in firestore.rules is modelled', () => {
  const src = fs.readFileSync(FIRESTORE_RULES, 'utf8');
  // Top-level blocks sit at 4 spaces of indentation inside /databases/{database}/documents.
  const blocks = [...src.matchAll(/^ {4}match \/(\S+) \{/gm)].map((m) => m[1]);
  const generic = ['{collection}/{id}', '{path=**}/{group}/{id}'];
  for (const g of generic) assert.ok(blocks.includes(g), g);
  const named = blocks.filter((b) => !generic.includes(b)).map((b) => b.split('/')[0]).sort();
  assert.deepEqual(named, [...MODELLED_OWN_BLOCKS].sort(),
    'lib/expected.js must model exactly the dedicated blocks in firestore.rules');
});

test('the matrix covers every table entry, the default and every collection group', () => {
  const table = gen.loadTable();
  const { cases, collections } = generateMatrix({ table });
  const covered = new Set(cases.filter((c) => !c.collectionGroup).map((c) => c.collection));
  for (const name of [...Object.keys(table.collections), W.UNDECLARED]) {
    assert.ok(covered.has(name), `${name} has no matrix cases`);
  }
  assert.equal(covered.size, collections.length);
  for (const persona of W.PERSONA_IDS) {
    assert.ok(cases.some((c) => c.persona === persona && c.collection === W.UNDECLARED), persona);
  }
  // Subcollection cases run on each equivalence class's representative (its
  // members' policies, subcollections included, differ only by name).
  const subs = new Set(cases.filter((c) => c.sub).map((c) => `${c.collection}/${c.sub}`));
  const representativeOf = {};
  for (const members of Object.values(equivalenceClasses(table))) for (const m of members) representativeOf[m] = members[0];
  for (const [name, entry] of Object.entries(table.collections)) {
    for (const sub of Object.keys(entry.subcollections || {})) {
      assert.ok(subs.has(`${representativeOf[name]}/${sub}`), `${name}/${sub} (via ${representativeOf[name]})`);
    }
  }
  const groups = new Set(cases.filter((c) => c.collectionGroup).map((c) => c.collectionGroup));
  for (const name of Object.keys(gen.collectionGroups(table))) assert.ok(groups.has(name), name);
});
