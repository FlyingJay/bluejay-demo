'use strict';
/**
 * Test environment set-up: loads the repo's rules into the emulator, seeds
 * the world (lib/world.js) and builds every persona's access index with the
 * REAL builder, functions/_shared.js' buildUserAccessIndex (which calls
 * computeEntitlements), reading the seeded groups/memberships/apps/segments
 * from the emulator exactly as rebuildUserAccessIndex reads production. The
 * resulting index is written to users/{uid}/metadata/access_index, the doc
 * the rules read.
 *
 * Needs functions/node_modules (`npm ci` in functions/).
 */

const fs = require('fs');
const path = require('path');
const { accessIndexDb } = require('./access_index_db');
const { openTestEnv, releaseTestEnv, refreshFirestoreRules } = require('./test_env');
const world = require('./world');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const FIRESTORE_RULES = path.join(ROOT, 'firestore.rules');
const STORAGE_RULES = path.join(ROOT, 'storage.rules');

// eslint-disable-next-line import/no-dynamic-require
const { buildUserAccessIndex } = require(path.join(ROOT, 'functions', '_shared.js'));

/**
 * Runs [fn] with a rules-bypassing compat Firestore and holds it open until
 * release() is called (withSecurityRulesDisabled tears its app down when its
 * callback returns, so the callback waits on a promise).
 */
async function privilegedFirestore(env) {
  let release;
  const released = new Promise((resolve) => { release = resolve; });
  let ready;
  const got = new Promise((resolve) => { ready = resolve; });
  const done = env.withSecurityRulesDisabled(async (ctx) => {
    ready({ db: ctx.firestore(), storage: ctx.storage() });
    await released;
  });
  const handles = await got;
  return { ...handles, release: async () => { release(); await done; } };
}

/** Writes the world's groups, apps, memberships and segments. */
async function seedWorld(db) {
  const batch = db.batch();
  for (const [id, data] of Object.entries(world.GROUPS)) batch.set(db.doc(`groups/${id}`), data);
  for (const [id, data] of Object.entries(world.APPS)) batch.set(db.doc(`apps/${id}`), { appId: id, ...data });
  for (const [id, data] of Object.entries(world.SEGMENTS)) batch.set(db.doc(`app_access_segments/${id}`), data);
  for (const [id, data] of Object.entries(world.PORTAL_CONFIGS)) batch.set(db.doc(`portal_configs/${id}`), data);
  for (const [uid, persona] of Object.entries(world.PERSONAS)) {
    for (const [groupId, role] of Object.entries(persona.memberships || {})) {
      const fields = typeof role === 'string' ? { role } : role;
      batch.set(db.doc(`memberships/${groupId}_${uid}`), { groupId, userId: uid, ...fields });
    }
  }
  await batch.commit();
}

/**
 * Builds every persona's index with the real builder and writes it.
 * Returns { uid: index } (null for personas without one).
 */
async function buildIndexes(db) {
  const indexes = {};
  const quiet = console.log;
  console.log = () => {};
  try {
    for (const [uid, persona] of Object.entries(world.PERSONAS)) {
      if (persona.signedOut || persona.noIndex) {
        indexes[uid] = null;
        continue;
      }
      const platform = persona.platform || world.ACTIVE;
      const { index } = await buildUserAccessIndex(uid, {
        db: accessIndexDb(db),
        readAccess: async () => ({ ...platform }),
      });
      indexes[uid] = index;
      await db.doc(`users/${uid}/metadata/access_index`).set(index);
    }
  } finally {
    console.log = quiet;
  }
  return indexes;
}

/**
 * A ready test environment for [projectId]: rules loaded, world seeded,
 * indexes built. `rules` overrides the Firestore rules source (spikes);
 * `storage: true` loads storage.rules, or pass the Storage rules source.
 */
async function setup(projectId, { rules, storage = false } = {}) {
  const storageRules = typeof storage === 'string' ? storage : fs.readFileSync(STORAGE_RULES, 'utf8');
  const env = await openTestEnv({
    projectId,
    firestore: { rules: rules || fs.readFileSync(FIRESTORE_RULES, 'utf8') },
    ...(storage ? { storage: { rules: storageRules } } : {}),
  });
  const privileged = await privilegedFirestore(env);
  await seedWorld(privileged.db);
  const indexes = await buildIndexes(privileged.db);
  const clients = {};
  for (const [uid, persona] of Object.entries(world.PERSONAS)) {
    const ctx = persona.signedOut ? env.unauthenticatedContext() : env.authenticatedContext(uid);
    clients[uid] = { db: ctx.firestore(), storage: storage ? ctx.storage() : null };
  }
  return {
    env,
    indexes,
    clients,
    admin: privileged,
    /** Reloads the env's Firestore rules (lib/test_env.js: frees what the emulator kept). */
    refreshRules: () => refreshFirestoreRules(env),
    async teardown() {
      await privileged.release();
      await releaseTestEnv(env);
    },
  };
}

module.exports = { setup, seedWorld, buildIndexes, FIRESTORE_RULES, STORAGE_RULES };
