'use strict';
/**
 * Runs matrix cases against the emulator with the raw JS SDK (the persona
 * clients from lib/personas.js; no Dart shim). Each case's fixture docs are
 * seeded with rules disabled, then the operation runs as the persona.
 */

const { setLogLevel } = require('firebase/firestore');

setLogLevel('silent');

const EXPRESSION_LIMIT = 'maximum of 1000 expressions';

/** Runs [fn] over [items] with at most [limit] in flight. */
async function pool(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

async function seed(adminDb, seeds) {
  const entries = Object.entries(seeds);
  const batches = [];
  for (let i = 0; i < entries.length; i += 450) batches.push(entries.slice(i, i + 450));
  await pool(batches, 8, async (chunk) => {
    const batch = adminDb.batch();
    for (const [path, data] of chunk) batch.set(adminDb.doc(path), data);
    await batch.commit();
  });
}

function deepEqual(a, b) {
  return JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b));
}
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  return v;
}

/**
 * Whether a write the SDK reported as denied was in fact applied. The JS SDK
 * re-sends unacknowledged writes when its write stream restarts (it does under
 * this load), and the re-sent copy is evaluated against the doc the first
 * copy already changed: a delete then meets a missing doc, a create an
 * existing one. A denied write never changes the doc, so the doc's state
 * tells the two apart.
 */
async function wasApplied(adminDb, c) {
  if (!adminDb || !['create', 'update', 'delete'].includes(c.op)) return false;
  const snap = await adminDb.doc(c.path).get();
  if (c.op === 'delete') return !snap.exists;
  if (c.op === 'create') return snap.exists;
  const before = c.seed[c.path];
  const after = { ...before, ...c.data };
  // A no-op update evaluates the same however often it is sent.
  return snap.exists && !deepEqual(before, after) && deepEqual(snap.data(), after);
}

/** Performs one case's operation as its persona. -> { allow, message } */
async function perform(db, c, adminDb) {
  try {
    if (c.op === 'get') await db.doc(c.path).get();
    else if (c.op === 'list') {
      let q = c.collectionGroup ? db.collectionGroup(c.collectionGroup) : db.collection(c.path);
      for (const [k, op, v] of c.where || []) q = q.where(k, op, v);
      await q.get();
    } else if (c.op === 'create') await db.doc(c.path).set(c.data);
    else if (c.op === 'update') await db.doc(c.path).update(c.data);
    else if (c.op === 'delete') await db.doc(c.path).delete();
    else throw new Error(`unknown op ${c.op}`);
    return { allow: true, message: '' };
  } catch (err) {
    if (err && err.code === 'permission-denied') {
      if (await wasApplied(adminDb, c)) return { allow: true, message: '', resent: true };
      return { allow: false, message: String(err.message || '') };
    }
    throw new Error(`${c.key}: unexpected ${err && err.code}: ${err && err.message}`);
  }
}

/**
 * Runs [cases] (seeding each first) and returns one result per case, in
 * order. Cases sharing a doc path (`exclusive`) run one at a time, each
 * re-seeded, after the rest. Between chunks it reloads the rules
 * (t.refreshRules, lib/personas.js), so the emulator's heap holds at most one
 * chunk's rules evaluations (lib/test_env.js).
 */
async function runCases(t, cases, { chunk = 4000, concurrency = 256 } = {}) {
  const results = new Array(cases.length);
  const parallel = [];
  const exclusive = [];
  cases.forEach((c, i) => (c.exclusive ? exclusive : parallel).push(i));
  const refresh = async () => { if (t.refreshRules) await t.refreshRules(); };

  for (let s = 0; s < parallel.length; s += chunk) {
    if (s > 0) await refresh();
    const idxs = parallel.slice(s, s + chunk);
    const seeds = {};
    for (const i of idxs) Object.assign(seeds, cases[i].seed);
    await seed(t.admin.db, seeds);
    await pool(idxs, concurrency, async (i) => {
      results[i] = await perform(t.clients[cases[i].persona].db, cases[i], t.admin.db);
    });
  }
  if (exclusive.length && parallel.length) await refresh();
  for (const i of exclusive) {
    const c = cases[i];
    await seed(t.admin.db, c.seed);
    if (c.op === 'create') await t.admin.db.doc(c.path).delete();
    results[i] = await perform(t.clients[c.persona].db, c, t.admin.db);
  }
  return results;
}

module.exports = { runCases, perform, seed, pool, EXPRESSION_LIMIT };
