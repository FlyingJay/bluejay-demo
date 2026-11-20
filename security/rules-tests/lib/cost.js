'use strict';
/**
 * Expression headroom of single requests under Firestore's
 * 1000-expressions-per-request limit, which the emulator enforces (T2 spike).
 *
 * Neither the emulator nor production reports a request's expression count
 * (the emulator's rule-coverage report counts evaluated nodes, a different
 * and much larger number), so headroom is measured directly: a copy of the
 * rules whose isAuthenticated(), the first call of every rule, also
 * evaluates a list literal of N items, and a binary search for the largest N
 * at which the request still gets its normal decision. Firestore counts
 * every list item it evaluates, so N approximates the expressions to spare.
 * A rule that calls isAuthenticated() k times spends the padding k times, so
 * headroom is a lower bound per call, which is the conservative direction.
 *
 * Loading rules is the slow part (the emulator compiles the whole ruleset,
 * about 0.4 s), so headrooms() runs the binary searches of many requests
 * together: each round loads every padding the unfinished searches need
 * next once, and runs every request that needs it.
 */

const { loadFirestoreRules: loadRules } = require('./emulator_rules');

const AUTH_FN = 'function isAuthenticated() { return request.auth != null; }';

function paddedRules(source, n) {
  if (!source.includes(AUTH_FN)) throw new Error('firestore.rules no longer defines isAuthenticated() as expected; update lib/cost.js');
  const list = `[${new Array(Math.max(n, 1)).fill('0').join(',')}]`;
  return source.replace(AUTH_FN,
    `function isAuthenticated() { return request.auth != null && ${n > 0 ? `${list}.size() > 0` : 'true'}; }`);
}

/**
 * Runs [fn] on every item at once, except that items with the same `key`
 * (the same doc) run one after another, in order.
 */
async function byKey(items, fn) {
  const chains = new Map();
  for (const item of items) {
    if (!chains.has(item.key)) chains.set(item.key, []);
    chains.get(item.key).push(item);
  }
  await Promise.all([...chains.values()].map(async (chain) => {
    for (const item of chain) await fn(item);
  }));
}

/**
 * Headroom of each request in [requests] ([{ key, attempt }]): the largest
 * padding (0..max) under which attempt() still returns true, or -1 if it
 * fails even unpadded. attempt() must re-seed its own fixture; requests
 * sharing a `key` never run at the same time. Leaves [source] loaded.
 */
async function headrooms(projectId, source, requests, { max = 1000 } = {}) {
  const state = requests.map((r) => ({ ...r, lo: 0, hi: max, room: null }));
  await loadRules(projectId, source);
  await byKey(state, async (s) => {
    if (!(await s.attempt())) s.room = -1;
  });
  for (;;) {
    const open = state.filter((s) => s.room === null && s.lo < s.hi);
    if (open.length === 0) break;
    const byMid = new Map();
    for (const s of open) {
      const mid = Math.ceil((s.lo + s.hi) / 2);
      if (!byMid.has(mid)) byMid.set(mid, []);
      byMid.get(mid).push(s);
    }
    for (const [mid, group] of [...byMid.entries()].sort((a, b) => a[0] - b[0])) {
      await loadRules(projectId, paddedRules(source, mid));
      await byKey(group, async (s) => {
        if (await s.attempt()) s.lo = mid;
        else s.hi = mid - 1;
      });
    }
  }
  await loadRules(projectId, source);
  return state.map((s) => (s.room === null ? s.lo : s.room));
}

module.exports = { headrooms, byKey, loadRules, paddedRules };
