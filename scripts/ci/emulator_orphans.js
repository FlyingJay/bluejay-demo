'use strict';
/**
 * Finds Firebase emulator processes nobody owns any more.
 *
 * An emulator started outside the shared rules-test emulator
 * (security/rules-tests/scripts/shared_emulator.js) — `firebase
 * emulators:exec` or `emulators:start` run by hand or by an agent session,
 * or `RULES_TESTS_ISOLATED=1 npm test` — is a Java process under the
 * firebase CLI. When whatever ran the CLI is killed (a terminal closed, an
 * agent's shell timing out), the CLI goes but the Java emulator stays,
 * adopted by launchd (parent pid 1), holding its ports and 1-3 GB of memory
 * until someone kills it. These are its leftovers.
 *
 * Orphans are stopped promptly, two ways: every rules-test run reaps them
 * before it starts (security/rules-tests/scripts/run.js), and a launchd job
 * runs `node emulator_orphans.js reap` every few minutes
 * (scripts/ci/install_emulator_reaper.sh). Only an emulator whose launcher is
 * gone counts, and only after a grace period; the shared rules-test
 * emulator's ports are left alone while its supervisor is alive.
 *
 * No dependencies beyond Node's own modules: the launchd job runs a copy of
 * this file from outside any checkout.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

/** How old an orphan must be before it's stopped (seconds). */
const DEFAULT_GRACE_SECONDS = Number(process.env.EMULATOR_ORPHAN_GRACE_SEC || 120);
const STATE_FILE = path.join(process.env.RULES_TESTS_STATE_DIR || path.join(os.homedir(), '.cache', 'bluejay-rules-tests'), 'state.json');

/** Java processes running a Firebase emulator (Firestore, Storage rules, ...). */
const EMULATOR_COMMAND = /\bjava\b.*(cloud-firestore-emulator|cloud-storage-rules-runtime|firebase-database-emulator|pubsub-emulator)/;

/** `[[d-]hh:]mm:ss` (ps etime) in seconds, or null. */
function elapsedSeconds(etime) {
  const m = /^(?:(\d+)-)?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})$/.exec(String(etime || '').trim());
  if (!m) return null;
  const [, d, h, mi, s] = m;
  return Number(d || 0) * 86400 + Number(h || 0) * 3600 + Number(mi) * 60 + Number(s);
}

/** The `--port N` and `--rules PATH` an emulator was started with. */
function emulatorArgs(command) {
  const port = /--port[ =](\d+)/.exec(command);
  const rules = /--rules[ =](\S+)/.exec(command);
  return { port: port ? Number(port[1]) : null, rules: rules ? rules[1] : null };
}

/**
 * The orphaned emulators in `ps -axo pid=,ppid=,etime=,command=` output:
 * `[{pid, ageSeconds, port, rules, command}]`, oldest first. Pure.
 */
function findOrphans(psOutput, { keep = [] } = {}) {
  const kept = new Set(keep.map(Number));
  const out = [];
  for (const line of String(psOutput || '').split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const [, pid, ppid, etime, command] = m;
    if (Number(ppid) !== 1 || kept.has(Number(pid)) || !EMULATOR_COMMAND.test(command)) continue;
    out.push({ pid: Number(pid), ageSeconds: elapsedSeconds(etime), ...emulatorArgs(command), command });
  }
  return out.sort((a, b) => (b.ageSeconds ?? 0) - (a.ageSeconds ?? 0));
}

/** The orphaned emulators on this machine right now (macOS and Linux `ps`). */
function orphanedEmulators({ keep = [] } = {}) {
  try {
    return findOrphans(execFileSync('ps', ['-axo', 'pid=,ppid=,etime=,command='], { encoding: 'utf8' }), { keep });
  } catch {
    return [];
  }
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

/** The shared rules-test emulator's ports while its supervisor is alive (never reaped). */
function sharedEmulatorPorts(stateFile = STATE_FILE) {
  try {
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    return state && alive(state.pid) ? [state.firestorePort, state.storagePort].filter(Number.isFinite) : [];
  } catch {
    return [];
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Stops orphaned emulators at least [graceSeconds] old, leaving the shared
 * emulator's [keepPorts]: SIGTERM, then SIGKILL for any still running after
 * [waitMs]. Returns the orphans it stopped. [list] and [kill] are for tests.
 */
async function reapOrphans({
  graceSeconds = DEFAULT_GRACE_SECONDS,
  keepPorts = sharedEmulatorPorts(),
  list = orphanedEmulators,
  kill = (pid, sig) => process.kill(pid, sig),
  isAlive = alive,
  waitMs = 10_000,
  log = () => {},
} = {}) {
  const targets = list().filter((o) => !keepPorts.includes(o.port) && (o.ageSeconds ?? 0) >= graceSeconds);
  const stopped = [];
  for (const o of targets) {
    try {
      kill(o.pid, 'SIGTERM');
      stopped.push(o);
      log(`stopped orphaned emulator: ${describe(o)}`);
    } catch (err) {
      log(`couldn't stop pid ${o.pid}: ${err.message}`);
    }
  }
  for (let waited = 0; waited < waitMs && stopped.some((o) => isAlive(o.pid)); waited += 250) await sleep(250);
  for (const o of stopped.filter((x) => isAlive(x.pid))) {
    try {
      kill(o.pid, 'SIGKILL');
    } catch {
      // Gone in the meantime.
    }
  }
  return stopped;
}

/** One line per orphan, for warnings and `status`. */
function describe(orphan) {
  const hours = orphan.ageSeconds == null ? '?' : (orphan.ageSeconds / 3600).toFixed(1);
  return `pid ${orphan.pid}, port ${orphan.port ?? '?'}, ${hours} h old, rules ${orphan.rules ?? '?'}`;
}

module.exports = {
  findOrphans, orphanedEmulators, reapOrphans, sharedEmulatorPorts, elapsedSeconds, emulatorArgs, describe, EMULATOR_COMMAND,
};

// `node emulator_orphans.js reap` (the launchd job) or `list`.
if (require.main === module) {
  const cmd = process.argv[2];
  if (cmd === 'list') {
    for (const o of orphanedEmulators()) console.log(describe(o));
  } else if (cmd === 'reap') {
    const stamp = () => new Date().toISOString();
    reapOrphans({ log: (line) => console.log(`${stamp()} ${line}`) }).catch((err) => {
      console.error(`${stamp()} ${err.message || err}`);
      process.exit(1);
    });
  } else {
    console.error('usage: node emulator_orphans.js list|reap');
    process.exit(2);
  }
}
