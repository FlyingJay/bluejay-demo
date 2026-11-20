'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { findOrphans, elapsedSeconds, emulatorArgs, reapOrphans } = require('./emulator_orphans');

const JAVA = 'java -Dgoogle.cloud_firestore.debug_log_level=FINE -jar /Users/me/.cache/firebase/emulators/cloud-firestore-emulator-v1.22.0.jar --host 127.0.0.1';

const ps = [
  // Orphaned (parent launchd), started by an agent from a deleted worktree.
  `50160     1 09:59:15 ${JAVA} --port 8181 --websocket_port 9150 --rules /wt/agent-x/firestore.rules`,
  `21465     1 08:18:15 ${JAVA} --port 9181 --websocket_port 9151 --rules /private/tmp/pr3148/firestore.rules`,
  // A dev emulator still under its firebase CLI (parent 4242): in use.
  `31000  4242 00:05:00 ${JAVA} --port 8181 --rules /repo/firestore.rules`,
  // The shared rules-test emulator: detached on purpose, kept.
  `40000     1 1-02:00:00 ${JAVA} --port 8782 --rules /cache/firestore.rules`,
  // Not an emulator.
  '   99     1 3-00:00:00 /usr/sbin/cfprefsd agent',
  '',
].join('\n');

test('only emulators adopted by launchd count, minus the ones to keep, oldest first', () => {
  const orphans = findOrphans(ps, { keep: [40000] });
  assert.deepEqual(orphans.map((o) => o.pid), [50160, 21465]);
  assert.equal(orphans[0].port, 8181);
  assert.equal(orphans[0].rules, '/wt/agent-x/firestore.rules');
  assert.equal(orphans[0].ageSeconds, 9 * 3600 + 59 * 60 + 15);
  assert.deepEqual(findOrphans(ps).map((o) => o.pid), [40000, 50160, 21465]);
  assert.deepEqual(findOrphans(''), []);
});

test('ps elapsed times and emulator arguments', () => {
  assert.equal(elapsedSeconds('05:07'), 307);
  assert.equal(elapsedSeconds('1-02:00:00'), 93600);
  assert.equal(elapsedSeconds('junk'), null);
  assert.deepEqual(emulatorArgs('java -jar x.jar --port=8782 --rules=/a/b.rules'), { port: 8782, rules: '/a/b.rules' });
  assert.deepEqual(emulatorArgs('java -jar x.jar'), { port: null, rules: null });
});

test('reaping stops orphans past the grace period, leaves the shared emulator, and forces stragglers', async () => {
  const orphans = [
    { pid: 1, port: 8181, ageSeconds: 3600 },
    { pid: 2, port: 9181, ageSeconds: 30 }, // too new: its launcher may only just have gone
    { pid: 3, port: 8782, ageSeconds: 7200 }, // the shared rules-test emulator
    { pid: 4, port: 5000, ageSeconds: 900 }, // ignores SIGTERM
  ];
  const signals = [];
  const running = new Set([1, 2, 3, 4]);
  const stopped = await reapOrphans({
    graceSeconds: 120,
    keepPorts: [8782, 9782],
    list: () => orphans,
    kill: (pid, sig) => {
      signals.push(`${pid}:${sig}`);
      if (sig === 'SIGKILL' || pid !== 4) running.delete(pid);
    },
    isAlive: (pid) => running.has(pid),
    waitMs: 500,
  });
  assert.deepEqual(stopped.map((o) => o.pid), [1, 4]);
  assert.deepEqual(signals, ['1:SIGTERM', '4:SIGTERM', '4:SIGKILL']);
  assert.ok(running.has(2) && running.has(3));
});

test('reaping with nothing orphaned does nothing', async () => {
  assert.deepEqual(await reapOrphans({ list: () => [], kill: () => assert.fail('nothing to kill'), keepPorts: [] }), []);
});
