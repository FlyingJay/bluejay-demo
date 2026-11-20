'use strict';
/**
 * Loads Firestore rules into the emulator through its REST endpoint, so a
 * project's rules can change without opening a new test environment
 * (lib/test_env.js, lib/cost.js).
 */

/** Loads [source] as [projectId]'s Firestore rules in the emulator. */
async function loadFirestoreRules(projectId, source) {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  if (!host) throw new Error('FIRESTORE_EMULATOR_HOST is not set (run under `firebase emulators:exec`)');
  const res = await fetch(`http://${host}/emulator/v1/projects/${projectId}:securityRules`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rules: { files: [{ name: 'firestore.rules', content: source }] } }),
  });
  if (!res.ok) throw new Error(`loading rules failed: ${res.status} ${await res.text()}`);
}

module.exports = { loadFirestoreRules };
