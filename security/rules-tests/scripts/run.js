'use strict';
/**
 * `npm test`. With RULES_TESTS_ISOLATED=1 it runs the suite under its own
 * `firebase emulators:exec` on firebase.json's ports. Otherwise it waits for the machine-wide run lock, reuses the shared
 * emulator (scripts/shared_emulator.js) and runs at most
 * RULES_TESTS_CONCURRENCY test files at once (default 2). A local run that
 * takes longer than RULES_TESTS_RUN_TIMEOUT_MIN (default 45) is stopped, so a
 * hung run can't hold the lock; after any failed run the shared emulator is
 * stopped, and the next run starts a fresh one.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { acquireLock, ensureEmulator, stop, privateTmpdir, reapBeforeRun } = require('./shared_emulator');

const RULES_TESTS_DIR = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(RULES_TESTS_DIR, '../..');
const TEST_FILES = fs.readdirSync(path.join(RULES_TESTS_DIR, 'test'))
  .filter((f) => f.endsWith('.test.js'))
  .sort()
  .map((f) => path.join('security/rules-tests/test', f));

function run(cmd, args, env, { timeoutMs } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: REPO_ROOT, stdio: 'inherit', env });
    const forward = (sig) => child.kill(sig);
    process.on('SIGINT', forward);
    process.on('SIGTERM', forward);
    const timer = timeoutMs && setTimeout(() => {
      console.error(`rules-tests: the run passed ${Math.round(timeoutMs / 60_000)} min; stopping it.`);
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 10_000).unref();
    }, timeoutMs);
    child.on('exit', (code, signal) => {
      if (timer) clearTimeout(timer);
      resolve(code ?? (signal ? 1 : 0));
    });
  });
}

function withJava(env) {
  // The emulators need a JDK; Homebrew's openjdk@21 isn't on PATH by default.
  if (!env.JAVA_HOME && fs.existsSync('/opt/homebrew/opt/openjdk@21')) env.JAVA_HOME = '/opt/homebrew/opt/openjdk@21';
  if (env.JAVA_HOME) env.PATH = `${path.join(env.JAVA_HOME, 'bin')}${path.delimiter}${env.PATH}`;
  return env;
}

async function main() {
  const env = withJava({ ...process.env });

  if (process.env.RULES_TESTS_ISOLATED === '1') {
    // Its own TMPDIR: Storage emulators sharing one delete each other's blobs.
    env.TMPDIR = privateTmpdir(fs.mkdtempSync(path.join(os.tmpdir(), 'rules-tests-')));
    return run(path.join(RULES_TESTS_DIR, 'node_modules/.bin/firebase'),
      ['emulators:exec', '--only', 'firestore,storage', '--project', 'demo-bluejay', `node --test ${TEST_FILES.join(' ')}`],
      env);
  }

  // Emulators other runs left behind hold memory this run needs.
  await reapBeforeRun();
  const release = await acquireLock();
  try {
    const hosts = await ensureEmulator(env);
    const concurrency = process.env.RULES_TESTS_CONCURRENCY || '2';
    console.log(`rules-tests: running ${TEST_FILES.length} files, ${concurrency} at a time, against the shared emulator (Firestore ${hosts.firestore}).`);
    const code = await run(process.execPath, [`--test-concurrency=${concurrency}`, '--test', ...TEST_FILES], {
      ...env,
      FIRESTORE_EMULATOR_HOST: hosts.firestore,
      FIREBASE_STORAGE_EMULATOR_HOST: hosts.storage,
      GCLOUD_PROJECT: 'demo-bluejay',
    }, { timeoutMs: Number(process.env.RULES_TESTS_RUN_TIMEOUT_MIN || 45) * 60_000 });
    // A failure may have left the emulator unhealthy (out of memory, a crashed
    // Storage emulator): don't hand it to the next run.
    if (code !== 0) await stop();
    return code;
  } finally {
    release();
  }
}

main().then((code) => process.exit(code), (err) => {
  console.error(err.message || err);
  process.exit(1);
});
