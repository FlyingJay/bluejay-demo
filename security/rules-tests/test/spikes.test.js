'use strict';
/**
 * T2 phase-1 spikes (plan 4.8 and 7.3), kept as tests so the findings stay
 * true: results are written up in plans/firestore-rules/IMPLEMENTATION_PLAN.md
 * under "T2 spike results".
 *
 * 1. The emulator enforces the 1000-expression limit (canary for
 *    test/cost.test.js and the matrix's cost check).
 * 2. List-query provability with the app scope derived from the collection:
 *    `groupId ==` alone proves a single-app collection's tenant + detail.
 * 3. __admin_only / __required_clearance in list queries: `.get(f, default)`
 *    on an unconstrained field takes the default (the flagged docs leak);
 *    the strict forms make every ordinary query unprovable.
 * 4. T6's enforced rules: the flags are table-level, so get and list agree.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const { setLogLevel } = require('firebase/firestore');
const { EXPRESSION_LIMIT } = require('../lib/run');

setLogLevel('silent');

const INDEX = {
  status: 'ACTIVE', roles: [], groups: ['g1'], denied_scopes: [], clearance_level: 0,
  entitlements: ['g1:notes', 'g1:announcements', 'g1:spike_default'],
};

async function env(projectId, rules) {
  const e = await openTestEnv({ projectId, firestore: { rules } });
  await e.withSecurityRulesDisabled((ctx) => ctx.firestore().doc('users/u1/metadata/access_index').set(INDEX));
  return e;
}

async function outcome(promise) {
  try {
    const snap = await promise;
    return snap && typeof snap.size === 'number' ? `ALLOW(${snap.size})` : 'ALLOW';
  } catch (err) {
    if (err.code !== 'permission-denied') throw err;
    return err.message.includes(EXPRESSION_LIMIT) ? 'LIMIT' : 'DENY';
  }
}

test('spike 1: the emulator enforces the 1000-expression limit', async () => {
  const keys = Array.from({ length: 1200 }, (_, i) => `'k${i}': ${i}`).join(', ');
  const rules = `rules_version = '2';
service cloud.firestore { match /databases/{database}/documents {
  function big() { return {${keys}}; }
  match /cheap/{id} { allow read: if true; }
  match /dear/{id} { allow read: if big().get('k1', -1) == 1; }
} }`;
  const e = await env('demo-spike-limit', rules);
  try {
    const db = e.authenticatedContext('u1').firestore();
    assert.equal(await outcome(db.doc('cheap/x').get()), 'ALLOW');
    assert.equal(await outcome(db.doc('dear/x').get()), 'LIMIT');
  } finally {
    await releaseTestEnv(e);
  }
});

// Collection -> [no filter, groupId == g1, groupId == g2 (not a member),
// groupId+appId, groupId + __admin_only == false, groupId + __required_clearance <= 0].
// Decisions are the same with no docs, plain docs, and flagged docs (rules
// are not filters); the counts below are for the flagged data set.
const LIST_SPIKE = {
  spike_notes: ['DENY', 'ALLOW(3)', 'DENY', 'ALLOW(3)', 'ALLOW(1)', 'ALLOW(1)'],
  spike_default: ['DENY', 'ALLOW(3)', 'DENY', 'ALLOW(3)', 'ALLOW(1)', 'ALLOW(1)'],
  spike_ctl: ['DENY', 'DENY', 'DENY', 'DENY', 'DENY', 'DENY'],
  spike_ao_get: ['DENY', 'ALLOW(3)', 'DENY', 'ALLOW(3)', 'ALLOW(1)', 'ALLOW(1)'],
  spike_ao_strict: ['DENY', 'DENY', 'DENY', 'DENY', 'ALLOW(1)', 'DENY'],
  spike_ao_ne: ['DENY', 'ALLOW(3)', 'DENY', 'ALLOW(3)', 'ALLOW(1)', 'ALLOW(1)'],
  spike_cl_get: ['DENY', 'ALLOW(3)', 'DENY', 'ALLOW(3)', 'ALLOW(1)', 'ALLOW(1)'],
  spike_cl_strict: ['DENY', 'DENY', 'DENY', 'DENY', 'DENY', 'ALLOW(1)'],
};

test('spikes 2-3: list provability with collection->app scope, and flags in list queries', async () => {
  const rules = fs.readFileSync(path.join(__dirname, '..', 'spikes', 'list_provability.rules'), 'utf8');
  const e = await env('demo-spike-lists', rules);
  try {
    const base = { groupId: 'g1', appId: 'notes', x: 1 };
    await e.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      for (const c of Object.keys(LIST_SPIKE)) {
        await db.doc(`${c}/plain`).set({ ...base, __admin_only: false, __required_clearance: 0 });
        await db.doc(`${c}/adminOnly`).set({ ...base, __admin_only: true });
        await db.doc(`${c}/clearance3`).set({ ...base, __required_clearance: 3 });
        await db.doc(`${c}/otherGroup`).set({ groupId: 'g2', appId: 'notes', x: 1 });
      }
    });
    const db = e.authenticatedContext('u1').firestore();
    const got = {};
    for (const c of Object.keys(LIST_SPIKE)) {
      const col = db.collection(c);
      got[c] = [];
      for (const q of [
        col,
        col.where('groupId', '==', 'g1'),
        col.where('groupId', '==', 'g2'),
        col.where('groupId', '==', 'g1').where('appId', '==', 'notes'),
        col.where('groupId', '==', 'g1').where('__admin_only', '==', false),
        col.where('groupId', '==', 'g1').where('__required_clearance', '<=', 0),
      ]) got[c].push(await outcome(q.get()));
    }
    assert.deepEqual(got, LIST_SPIKE);

    // The leak in spike_ao_get / spike_cl_get, doc by doc: get is refused.
    assert.equal(await outcome(db.doc('spike_ao_get/adminOnly').get()), 'DENY');
    assert.equal(await outcome(db.doc('spike_cl_get/clearance3').get()), 'DENY');
  } finally {
    await releaseTestEnv(e);
  }
});

test('spike 4, resolved (T6): enforced rules ignore per-doc __admin_only / clearance, so get and list agree', async () => {
  // T2 found the per-doc flags fail open in list queries (a list returned
  // docs a get refused). T6 moved them into the table (adminOnlyCollection,
  // requiredClearance, ownerScoped), so the tenant rule never reads them and
  // a list can't see more than a get. (announcements: a plain tenant
  // collection, no ownerScoped.)
  const gen = require('../../generate');
  const e = await env('demo-spike-today', fs.readFileSync(gen.RULES_PATH, 'utf8'));
  try {
    const base = { groupId: 'g1', appId: 'announcements', creatorId: 'u2', ownerIds: ['u2'] };
    await e.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc('announcements/plain').set(base);
      await db.doc('announcements/adminOnly').set({ ...base, __admin_only: true });
      await db.doc('announcements/clearance3').set({ ...base, __required_clearance: 3 });
    });
    const db = e.authenticatedContext('u1').firestore();
    assert.equal(await outcome(db.collection('announcements').where('groupId', '==', 'g1').where('appId', '==', 'announcements').get()), 'ALLOW(3)');
    assert.equal(await outcome(db.doc('announcements/adminOnly').get()), 'ALLOW');
    assert.equal(await outcome(db.doc('announcements/clearance3').get()), 'ALLOW');
    // Today's ScopedCollection.query shape (groupId only) is provable now: announcements is a single-app collection.
    assert.equal(await outcome(db.collection('announcements').where('groupId', '==', 'g1').get()), 'ALLOW(3)');
    assert.equal(await outcome(db.collection('announcements').where('groupId', '==', 'g2').get()), 'DENY');
    assert.equal(await outcome(db.collection('announcements').get()), 'DENY');
  } finally {
    await releaseTestEnv(e);
  }
});
