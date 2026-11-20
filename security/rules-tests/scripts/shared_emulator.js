'use strict';
/**
 * The machine-wide rules-test lock and the shared local emulator.
 *
 * Several checkouts (worktrees, agent sessions) on one machine run this suite.
 * Each `firebase emulators:exec` starts its own Firestore JVM and Storage rules
 * JVM (1-3 GB each) and a pool of test workers, and three of those at once push
 * a 16 GB machine into swap. Locally, `npm test` (scripts/run.js) instead:
 *
 * - takes a machine-wide lock, so one run executes at a time and the others
 *   wait their turn;
 * - reuses one long-lived Firestore + Storage emulator on dedicated ports
 *   (8782/9782, away from firebase.json's dev ports), started on first use by a
 *   detached supervisor (`node shared_emulator.js serve`) that stops it after
 *   RULES_TESTS_EMULATOR_IDLE_MIN minutes (default 20) without a run.
 *
 * Every suite loads its own rules into its own project id and clears its data
 * on open and release (lib/test_env.js), so a run never depends on what an
 * earlier run, or another checkout's rules, left in the emulator.
 *
 * State lives in ~/.cache/bluejay-rules-tests/: run.lock/ (the lock, with the
 * holder's pid and checkout), state.json (the supervisor's pid and ports),
 * last_used (touched when a run ends), emulator.log and the emulators' logs.
 *
 * `node shared_emulator.js stop` stops the shared emulator;
 * `node shared_emulator.js status` prints the lock holder, emulator state and
 * any orphaned emulators; `node shared_emulator.js reap` stops the orphans.
 *
 * Orphans (scripts/ci/emulator_orphans.js) are emulators started outside this
 * file (`firebase emulators:exec`/`start`, RULES_TESTS_ISOLATED=1) whose
 * launcher was killed, e.g. an agent shell that timed out: launchd adopts the
 * Java process and it keeps its ports and memory. Every local run stops the
 * ones past their grace period before it starts, and the launchd reaper
 * (scripts/ci/install_emulator_reaper.sh) catches them between runs.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const orphans = require('../../../scripts/ci/emulator_orphans');

const STATE_DIR = process.env.RULES_TESTS_STATE_DIR || path.join(os.homedir(), '.cache', 'bluejay-rules-tests');
const LOCK_DIR = path.join(STATE_DIR, 'run.lock');
const LOCK_OWNER = path.join(LOCK_DIR, 'owner.json');
const STATE_FILE = path.join(STATE_DIR, 'state.json');
const LAST_USED = path.join(STATE_DIR, 'last_used');
const SUPERVISOR_LOG = path.join(STATE_DIR, 'emulator.log');

const FIRESTORE_PORT = Number(process.env.RULES_TESTS_FIRESTORE_PORT || 8782);
const STORAGE_PORT = Number(process.env.RULES_TESTS_STORAGE_PORT || 9782);
// The emulator hub and logging ports would otherwise default to 4400/4500 and
// collide with a dev `firebase emulators:start` in any checkout.
const HUB_PORT = Number(process.env.RULES_TESTS_HUB_PORT || 4782);
const LOGGING_PORT = Number(process.env.RULES_TESTS_LOGGING_PORT || 4783);
const IDLE_MS = Number(process.env.RULES_TESTS_EMULATOR_IDLE_MIN || 20) * 60_000;
// Caps both emulator JVMs (the JVM's default is a quarter of the machine's
// memory). 1.5 GB ran out with two test files at a time.
const HEAP = process.env.RULES_TESTS_EMULATOR_HEAP || '3g';
// A full run writes about 1 GB of emulator logs; past this the next run gets
// a fresh emulator (and fresh logs).
const MAX_LOG_BYTES = Number(process.env.RULES_TESTS_EMULATOR_MAX_LOG_MB || 1024) * 1024 * 1024;
const LOG_FILES = ['firestore-debug.log', 'firebase-debug.log', 'storage-debug.log'].map((f) => path.join(STATE_DIR, f));

const RULES_TESTS_DIR = path.resolve(__dirname, '..');
const REPO_ROOT = path.resolve(RULES_TESTS_DIR, '../..');

function logBytes() {
  return LOG_FILES.reduce((n, f) => {
    try {
      return n + fs.statSync(f).size;
    } catch {
      return n;
    }
  }, 0);
}

/**
 * Every Storage emulator keeps its blobs in $TMPDIR/firebase/storage/blobs and
 * deletes that directory when it stops, so two emulators sharing a TMPDIR
 * break each other (ENOENT on upload, and the CLI exits). Give each its own.
 */
function privateTmpdir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function alive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function firebaseToolsVersion() {
  return require(path.join(RULES_TESTS_DIR, 'node_modules/firebase-tools/package.json')).version;
}

// --- the lock ----------------------------------------------------------------

function lockHolder() {
  if (!fs.existsSync(LOCK_DIR)) return null;
  return readJson(LOCK_OWNER) || { pid: 0 };
}

function tryLock() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  try {
    fs.mkdirSync(LOCK_DIR);
  } catch (err) {
    if (err.code !== 'EEXIST') throw err;
    const holder = lockHolder();
    // A holder that died without releasing (SIGKILL, a crash). An owner file
    // not written yet belongs to a run that is starting: give it a moment.
    const age = Date.now() - fs.statSync(LOCK_DIR).mtimeMs;
    if (holder && (holder.pid ? !alive(holder.pid) : age > 10_000)) {
      fs.rmSync(LOCK_DIR, { recursive: true, force: true });
      return tryLock();
    }
    return false;
  }
  fs.writeFileSync(LOCK_OWNER, JSON.stringify({ pid: process.pid, cwd: REPO_ROOT, started: new Date().toISOString() }));
  return true;
}

/** Waits for the machine-wide lock; returns a release function. */
async function acquireLock({ timeoutMs = Number(process.env.RULES_TESTS_LOCK_TIMEOUT_MIN || 90) * 60_000 } = {}) {
  const start = Date.now();
  let announced = null;
  while (!tryLock()) {
    const holder = lockHolder();
    const key = holder && holder.pid;
    if (key && key !== announced) {
      console.log(`rules-tests: waiting for another run (pid ${holder.pid}, ${holder.cwd}, since ${holder.started})...`);
      announced = key;
    }
    if (Date.now() - start > timeoutMs) {
      throw new Error(`rules-tests: gave up waiting for the run lock after ${Math.round(timeoutMs / 1000)}s (${LOCK_DIR})`);
    }
    await sleep(2000);
  }
  if (announced) console.log(`rules-tests: lock acquired after ${Math.round((Date.now() - start) / 1000)}s.`);
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    const holder = readJson(LOCK_OWNER);
    if (holder && holder.pid === process.pid) fs.rmSync(LOCK_DIR, { recursive: true, force: true });
    fs.writeFileSync(LAST_USED, new Date().toISOString());
  };
  process.on('exit', release);
  return release;
}

// --- the shared emulator -----------------------------------------------------

async function responds(port) {
  try {
    // Any HTTP answer means it's listening (Storage answers / with 501).
    await fetch(`http://127.0.0.1:${port}/`, { signal: AbortSignal.timeout(2000) });
    return true;
  } catch {
    return false;
  }
}

async function healthy(state) {
  return Boolean(state && alive(state.pid) && (await responds(state.firestorePort)) && (await responds(state.storagePort)));
}

async function stop() {
  const state = readJson(STATE_FILE);
  if (state && alive(state.pid)) {
    process.kill(state.pid, 'SIGTERM');
    for (let i = 0; i < 60 && alive(state.pid); i++) await sleep(500);
    if (alive(state.pid)) process.kill(state.pid, 'SIGKILL');
  }
  fs.rmSync(STATE_FILE, { force: true });
}

/**
 * Returns the shared emulator's hosts, starting it (or restarting one built
 * from a different firebase-tools) when needed. Call only while holding the lock.
 */
async function ensureEmulator(env = process.env) {
  const version = firebaseToolsVersion();
  let state = readJson(STATE_FILE);
  if (state && state.firebaseTools !== version) {
    console.log(`rules-tests: shared emulator runs firebase-tools ${state.firebaseTools}, this checkout has ${version}; restarting it.`);
    await stop();
    state = null;
  } else if (state && logBytes() > MAX_LOG_BYTES) {
    console.log(`rules-tests: shared emulator logs passed ${Math.round(MAX_LOG_BYTES / 1048576)} MB; restarting it.`);
    await stop();
    state = null;
  }
  if (!(await healthy(state))) {
    if (state) await stop();
    console.log(`rules-tests: starting the shared emulator (Firestore :${FIRESTORE_PORT}, Storage :${STORAGE_PORT}; log ${SUPERVISOR_LOG})...`);
    fs.mkdirSync(STATE_DIR, { recursive: true });
    const log = fs.openSync(SUPERVISOR_LOG, 'w');
    const child = spawn(process.execPath, [__filename, 'serve'], { detached: true, stdio: ['ignore', log, log], env });
    child.unref();
    const deadline = Date.now() + 180_000;
    for (;;) {
      await sleep(1000);
      state = readJson(STATE_FILE);
      if (state && state.pid === child.pid && (await healthy(state))) break;
      if (!alive(child.pid) || Date.now() > deadline) {
        const tail = fs.readFileSync(SUPERVISOR_LOG, 'utf8').split('\n').slice(-30).join('\n');
        throw new Error(`rules-tests: the shared emulator did not start. ${SUPERVISOR_LOG}:\n${tail}`);
      }
    }
  }
  return { firestore: `127.0.0.1:${state.firestorePort}`, storage: `127.0.0.1:${state.storagePort}` };
}

/** The detached supervisor: runs the emulators, stops them when idle. */
async function serve() {
  // The emulators need a config with rules files; each suite loads its own
  // rules, so these copies only have to parse.
  fs.copyFileSync(path.join(REPO_ROOT, 'firestore.rules'), path.join(STATE_DIR, 'firestore.rules'));
  fs.copyFileSync(path.join(REPO_ROOT, 'storage.rules'), path.join(STATE_DIR, 'storage.rules'));
  fs.writeFileSync(path.join(STATE_DIR, 'firebase.json'), JSON.stringify({
    firestore: { rules: 'firestore.rules' },
    storage: { rules: 'storage.rules' },
    emulators: {
      firestore: { host: '127.0.0.1', port: FIRESTORE_PORT },
      storage: { host: '127.0.0.1', port: STORAGE_PORT },
      hub: { host: '127.0.0.1', port: HUB_PORT },
      logging: { host: '127.0.0.1', port: LOGGING_PORT },
      ui: { enabled: false },
      singleProjectMode: false,
    },
  }, null, 2));

  for (const f of LOG_FILES) fs.rmSync(f, { force: true });
  const javaOpts = [process.env.JAVA_TOOL_OPTIONS, `-Xmx${HEAP}`].filter(Boolean).join(' ');
  // Its own process group, so stopping it also stops the JVMs the CLI started
  // (a CLI that crashes otherwise leaves the Firestore JVM running).
  const emu = spawn(path.join(RULES_TESTS_DIR, 'node_modules/.bin/firebase'),
    ['emulators:start', '--only', 'firestore,storage', '--project', 'demo-bluejay', '--config', 'firebase.json'],
    {
      cwd: STATE_DIR,
      stdio: 'inherit',
      detached: true,
      env: { ...process.env, JAVA_TOOL_OPTIONS: javaOpts, TMPDIR: privateTmpdir(path.join(STATE_DIR, 'tmp')) },
    });
  const killGroup = (sig) => {
    try {
      process.kill(-emu.pid, sig);
    } catch {}
  };

  fs.writeFileSync(STATE_FILE, JSON.stringify({
    pid: process.pid,
    firestorePort: FIRESTORE_PORT,
    storagePort: STORAGE_PORT,
    firebaseTools: firebaseToolsVersion(),
    startedFrom: REPO_ROOT,
    started: new Date().toISOString(),
  }));
  fs.writeFileSync(LAST_USED, new Date().toISOString());

  let stopping = false;
  const shutdown = (why) => {
    if (stopping) return;
    stopping = true;
    console.log(`shared emulator: stopping (${why})`);
    killGroup('SIGINT');
    setTimeout(() => killGroup('SIGKILL'), 20_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  emu.on('exit', (code) => {
    killGroup('SIGKILL');
    const state = readJson(STATE_FILE);
    if (state && state.pid === process.pid) fs.rmSync(STATE_FILE, { force: true });
    console.log(`shared emulator: emulators exited (${code})`);
    process.exit(0);
  });

  const idleCheck = setInterval(() => {
    if (lockHolder()) return;
    let last = 0;
    try {
      last = fs.statSync(LAST_USED).mtimeMs;
    } catch {}
    if (Date.now() - last > IDLE_MS) {
      clearInterval(idleCheck);
      shutdown(`idle for ${IDLE_MS / 60_000} min`);
    }
  }, 30_000);
}

/** Orphaned emulators, leaving out the shared emulator's own while it's healthy. */
async function orphanedEmulators() {
  const state = readJson(STATE_FILE);
  const ours = (await healthy(state)) ? [state.firestorePort, state.storagePort] : [];
  return orphans.orphanedEmulators().filter((o) => !ours.includes(o.port));
}

/** The shared emulator's ports while it's healthy: never reaped. */
async function keptPorts() {
  const state = readJson(STATE_FILE);
  return (await healthy(state)) ? [state.firestorePort, state.storagePort] : [];
}

/** Before a run: stops orphans past their grace period, saying so. */
async function reapBeforeRun() {
  await orphans.reapOrphans({ keepPorts: await keptPorts(), log: (line) => console.warn(`rules-tests: ${line}`) });
}

/** Stops every orphaned emulator now, whatever its age. */
async function reap() {
  const stopped = await orphans.reapOrphans({ graceSeconds: 0, keepPorts: await keptPorts(), log: (line) => console.log(line) });
  if (!stopped.length) console.log('no orphaned emulators');
}

async function status() {
  const holder = lockHolder();
  console.log(holder ? `lock: held by pid ${holder.pid} (${holder.cwd}, since ${holder.started})` : 'lock: free');
  const state = readJson(STATE_FILE);
  if (await healthy(state)) {
    console.log(`emulator: running (supervisor pid ${state.pid}, Firestore :${state.firestorePort}, Storage :${state.storagePort}, firebase-tools ${state.firebaseTools}, since ${state.started})`);
  } else {
    console.log('emulator: not running');
  }
  const found = await orphanedEmulators();
  console.log(found.length ? `orphaned emulators: ${found.length} (stop them with \`reap\`)` : 'orphaned emulators: none');
  for (const o of found) console.log(`  ${orphans.describe(o)}`);
}

module.exports = { acquireLock, ensureEmulator, stop, privateTmpdir, reapBeforeRun };

if (require.main === module) {
  const cmd = process.argv[2];
  const run = { serve, stop, status, reap }[cmd];
  if (!run) {
    console.error('usage: node shared_emulator.js serve|stop|status|reap');
    process.exit(2);
  }
  run().catch((err) => {
    console.error(err.message || err);
    process.exit(1);
  });
}
