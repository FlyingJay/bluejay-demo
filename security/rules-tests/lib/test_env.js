'use strict';
/**
 * Opening and releasing emulator test environments. Every suite goes through
 * here so the emulator's data is cleared when a suite is done with it: every
 * suite of a run shares one Firestore emulator JVM, and data left behind by one
 * suite (a matrix shard seeds a full world) stays in its heap for the rest of
 * the run.
 *
 * openTestEnv(config) is initializeTestEnvironment(config), tracked.
 * releaseTestEnv(env) clears the env's Firestore project (and Storage bucket,
 * when the env has Storage), then cleans it up; it is idempotent. Any env a
 * test file leaves open (a test that threw before releasing it) is released
 * by an after() hook once the file's tests finish. Opening an env clears its
 * project's data first: locally the emulator outlives a run
 * (scripts/shared_emulator.js), and a run that was killed never released its
 * environments.
 *
 * Clearing data is not enough on its own. The Firestore emulator keeps
 * every rules evaluation (the values of the expressions it evaluated, about
 * 10 KB a request) for as long as the ruleset that made it stays loaded, and
 * clearFirestore() keeps the ruleset. Loading a ruleset drops what the
 * previous one kept. So releasing an env also replaces its rules with
 * RELEASED_RULES, and refreshFirestoreRules(env) reloads an open env's own
 * rules: callers that send many requests (lib/run.js' runCases) call it
 * between batches. Before this, every request of a run stayed in the heap
 * (~190k matrix requests, close to the emulator's default heap of a quarter
 * of the runner's memory), and each matrix shard ran slower than the one
 * before it.
 *
 * Only test files load this module (node:test's after() registers on the
 * file's root test).
 */

const { after } = require('node:test');
const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { loadFirestoreRules } = require('./emulator_rules');

const open = new Map(); // env -> { storage: boolean, firestoreRules: string | undefined }

/** What a released env's project is left with: denies everything. */
const RELEASED_RULES = `rules_version = '2';
service cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if false; } } }`;

async function openTestEnv(config) {
  const env = await initializeTestEnvironment(config);
  open.set(env, { storage: Boolean(config.storage), firestoreRules: config.firestore && config.firestore.rules });
  await clearData(env, Boolean(config.storage));
  return env;
}

/**
 * Reloads an open env's own Firestore rules, which drops the evaluations the
 * emulator kept for them (above). No-op for an env opened without rules.
 */
async function refreshFirestoreRules(env) {
  const entry = open.get(env);
  if (entry && entry.firestoreRules) await loadFirestoreRules(env.projectId, entry.firestoreRules);
}

async function deleteStorageTree(ref) {
  const { items, prefixes } = await ref.listAll();
  await Promise.all(items.map((item) => item.delete()));
  for (const prefix of prefixes) await deleteStorageTree(prefix);
}

// A failed clear is only logged: it must not replace the test's own result.
async function clearData(env, storage) {
  try {
    await env.clearFirestore();
  } catch (err) {
    console.warn(`test_env: clearing Firestore project ${env.projectId} failed: ${err.message || err}`);
  }
  if (storage) {
    try {
      await env.withSecurityRulesDisabled((ctx) => deleteStorageTree(ctx.storage().ref()));
    } catch (err) {
      console.warn(`test_env: clearing Storage for ${env.projectId} failed: ${err.message || err}`);
    }
  }
}

async function releaseTestEnv(env) {
  const entry = open.get(env);
  if (!entry) return;
  open.delete(env);
  await clearData(env, entry.storage);
  if (entry.firestoreRules) {
    try {
      await loadFirestoreRules(env.projectId, RELEASED_RULES);
    } catch (err) {
      console.warn(`test_env: replacing the rules of ${env.projectId} failed: ${err.message || err}`);
    }
  }
  await env.cleanup();
}

after(async () => {
  for (const env of [...open.keys()]) await releaseTestEnv(env);
});

module.exports = { openTestEnv, releaseTestEnv, refreshFirestoreRules };
