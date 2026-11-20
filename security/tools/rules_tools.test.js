'use strict';

// Unit tests for the rules deploy pipeline's tools (plan T4). Every HTTP call
// goes to a fake; nothing reaches Google.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const api = require('./rules_api');
const rollback = require('./rollback_rules');
const deploy = require('./rules_deploy');
const smoke = require('./prod_smoke');

const P = 'projects/bluejay-d926f';
const FS_LIVE = `${P}/rulesets/fs-live`;
const ST_LIVE = `${P}/rulesets/st-live`;
const RULESETS = {
  'fs-live': { metadata: { services: ['cloud.firestore'] }, source: { files: [{ name: 'firestore.rules' }] } },
  'fs-old': { metadata: { services: ['cloud.firestore'] }, source: { files: [{ name: 'firestore.rules' }] } },
  'st-live': { metadata: { services: ['firebase.storage'] }, source: { files: [{ name: 'storage.rules' }] } },
  'st-old': { source: { files: [{ name: 'storage.rules' }] } },
};

/** A fake Rules API: records calls, serves releases and rulesets. */
function fakeRules({ releases } = {}) {
  const state = {
    releases: releases || [
      { name: `${P}/releases/cloud.firestore`, rulesetName: FS_LIVE, updateTime: '2025-12-16T18:42:28Z' },
      { name: `${P}/releases/firebase.storage/bluejay-d926f.firebasestorage.app`, rulesetName: ST_LIVE, updateTime: '2025-12-16T18:42:54Z' },
    ],
  };
  const calls = [];
  const request = async (opts) => {
    calls.push(opts);
    const url = new URL(opts.url);
    const p = decodeURIComponent(url.pathname).replace(/^\/v1\//, '');
    if (opts.method === 'PATCH') {
      const rel = state.releases.find((r) => r.name === p);
      if (!rel) return { status: 404, data: { error: { message: 'no release' } } };
      rel.rulesetName = opts.data.release.rulesetName;
      return { status: 200, data: rel };
    }
    if (p.endsWith(':test')) {
      const content = opts.data.source.files[0].content;
      return { status: 200, data: content.includes('BROKEN') ? { issues: [{ severity: 'ERROR', description: 'Unexpected', sourcePosition: { line: 3 } }] } : {} };
    }
    if (p === `${P}/releases`) return { status: 200, data: { releases: state.releases } };
    if (p === `${P}/rulesets`) {
      return {
        status: 200,
        data: {
          rulesets: [
            { name: `${P}/rulesets/fs-old`, createTime: '2025-12-16T15:27:31Z' },
            { name: FS_LIVE, createTime: '2025-12-16T18:42:28Z', metadata: { services: ['cloud.firestore'] } },
            { name: ST_LIVE, createTime: '2025-12-16T18:42:54Z' },
            { name: `${P}/rulesets/st-old`, createTime: '2025-12-16T15:34:01Z' },
          ],
        },
      };
    }
    const m = p.match(/rulesets\/(.+)$/);
    if (m && RULESETS[m[1]]) return { status: 200, data: { name: p, ...RULESETS[m[1]] } };
    if (p === 'projects/bluejay-d926f') return { status: 200, data: { projectNumber: '42' } };
    if (p.endsWith(':getIamPolicy')) return { status: 200, data: state.policy || { bindings: [] } };
    return { status: 404, data: { error: { message: `not found: ${p}` } } };
  };
  return { request, calls, state };
}

const quiet = () => {};

// ── rules_api ──────────────────────────────────────────────────────────────

test('currentReleases splits Firestore and per-bucket Storage releases', async () => {
  const { request } = fakeRules();
  const current = await api.currentReleases(request);
  assert.deepEqual(current.firestore.map((r) => [r.release, r.rulesetName]), [['cloud.firestore', FS_LIVE]]);
  assert.deepEqual(current.storage.map((r) => [r.release, r.rulesetName]), [['firebase.storage/bluejay-d926f.firebasestorage.app', ST_LIVE]]);
});

test('listRulesets sorts newest first', async () => {
  const { request } = fakeRules();
  const list = await api.listRulesets(request, { limit: 10 });
  assert.equal(list[0].name, ST_LIVE);
  assert.equal(list[list.length - 1].name, `${P}/rulesets/fs-old`);
});

test('API errors surface the status and message', async () => {
  const request = async () => ({ status: 403, data: { error: { message: 'The caller does not have permission' } } });
  await assert.rejects(api.listReleases(request), (err) => err.status === 403 && /does not have permission/.test(err.message));
});

test('patchRelease sends the full release with an update mask', async () => {
  const { request, calls } = fakeRules();
  await api.patchRelease(request, 'cloud.firestore', 'fs-old');
  const patch = calls.find((c) => c.method === 'PATCH');
  assert.match(patch.url, /\/v1\/projects\/bluejay-d926f\/releases\/cloud\.firestore$/);
  assert.deepEqual(patch.data, {
    release: { name: `${P}/releases/cloud.firestore`, rulesetName: `${P}/rulesets/fs-old` },
    updateMask: 'ruleset_name',
  });
});

// ── rollback_rules ─────────────────────────────────────────────────────────

test('parseArgs requires --list or --to and a known service', () => {
  assert.throws(() => rollback.parseArgs([]), /--list or --to/);
  assert.throws(() => rollback.parseArgs(['--list', '--service', 'rtdb']), /firestore or storage/);
  assert.throws(() => rollback.parseArgs(['--to']), /needs a value/);
  assert.deepEqual(rollback.parseArgs(['--to', 'x', '--service', 'storage']).service, 'storage');
});

test('--list shows the service\'s rulesets and marks the live one', async () => {
  const { request, calls } = fakeRules();
  const lines = [];
  const out = await rollback.main(['--list', '--service', 'storage'], { request, log: (l) => lines.push(l) });
  assert.deepEqual(out.rulesets.map((r) => r.name), [ST_LIVE, `${P}/rulesets/st-old`]);
  assert.ok(lines.some((l) => l.includes(ST_LIVE) && l.includes('[LIVE]')));
  assert.ok(!calls.some((c) => c.method === 'PATCH'));
});

test('--to re-points the Firestore release', async () => {
  const { request, state } = fakeRules();
  const results = await rollback.main(['--to', 'fs-old'], { request, log: quiet });
  assert.deepEqual(results, [{ release: 'cloud.firestore', from: FS_LIVE, to: `${P}/rulesets/fs-old`, changed: true }]);
  assert.equal(state.releases[0].rulesetName, `${P}/rulesets/fs-old`);
  assert.equal(state.releases[1].rulesetName, ST_LIVE, 'storage untouched');
});

test('--to refuses a ruleset of the other service', async () => {
  const { request, calls } = fakeRules();
  await assert.rejects(rollback.main(['--to', 'st-old'], { request, log: quiet }), /storage ruleset, not firestore/);
  assert.ok(!calls.some((c) => c.method === 'PATCH'));
});

test('--to with --dry-run patches nothing; already-live is a no-op', async () => {
  const { request, calls } = fakeRules();
  await rollback.main(['--to', 'st-old', '--service', 'storage', '--dry-run'], { request, log: quiet });
  const same = await rollback.main(['--to', FS_LIVE], { request, log: quiet });
  assert.equal(same[0].changed, false);
  assert.ok(!calls.some((c) => c.method === 'PATCH'));
});

test('rulesetService falls back to the file name when metadata is missing', () => {
  assert.equal(rollback.rulesetService(RULESETS['st-old']), 'storage');
  assert.equal(rollback.rulesetService({}), null);
});

// ── rules_deploy ───────────────────────────────────────────────────────────

function fakeFirestore() {
  const docs = {};
  const FieldValue = {
    serverTimestamp: () => '<ts>',
    arrayUnion: (...items) => ({ __union: items }),
  };
  const apply = (prev, data) => {
    const next = { ...prev };
    for (const [k, v] of Object.entries(data)) next[k] = v && v.__union ? [...(prev[k] || []), ...v.__union] : v;
    return next;
  };
  const ref = (id) => ({
    id,
    set: async (data, opts) => { docs[id] = opts && opts.merge ? apply(docs[id] || {}, data) : apply({}, data); },
  });
  const db = {
    collection: (name) => ({ doc: (id) => ref(`${name}/${id}`) }),
    runTransaction: async (fn) => fn({
      get: async (r) => ({ exists: !!docs[r.id], data: () => docs[r.id] }),
      set: (r, data) => { docs[r.id] = apply({}, data); },
      update: (r, data) => { docs[r.id] = apply(docs[r.id], data); },
    }),
  };
  return { docs, firestore: { db, FieldValue } };
}

test('services and --only targets', () => {
  assert.deepEqual(deploy.parseServices('both'), ['firestore', 'storage']);
  assert.throws(() => deploy.parseServices('rtdb'), /unknown service/);
  assert.equal(deploy.onlyTargets(['firestore']), 'firestore:rules');
  assert.equal(deploy.onlyTargets(['firestore', 'storage']), 'firestore:rules,storage');
  assert.throws(() => deploy.parseArgs(['before']), /needs --sha/);
  assert.throws(() => deploy.parseArgs(['after', '--sha', 'x']), /needs --status/);
});

test('compile fails on Rules API compile errors', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rules-'));
  fs.writeFileSync(path.join(root, 'firestore.rules'), 'ok');
  fs.writeFileSync(path.join(root, 'storage.rules'), 'BROKEN');
  const { request } = fakeRules();
  await deploy.compileAll(request, ['firestore'], { root, log: quiet });
  const lines = [];
  await assert.rejects(deploy.compileAll(request, ['storage'], { root, log: (l) => lines.push(l) }), /1 compile error/);
  assert.ok(lines.some((l) => l.startsWith('::error file=storage.rules,line=3::')));
});

test('preflight fails without the Storage cross-service role and passes with it', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rules-'));
  fs.writeFileSync(path.join(root, 'storage.rules'), 'allow read: if firestore.get(/x).data.y;');
  const fake = fakeRules();
  const missing = await deploy.preflight(fake.request, ['storage'], { root, log: quiet });
  assert.equal(missing.ok, false);
  assert.match(missing.command, /service-42@gcp-sa-firebasestorage.*firebaserules\.firestoreServiceAgent/);
  fake.state.policy = { bindings: [{ role: deploy.CROSS_SERVICE_ROLE, members: ['serviceAccount:service-42@gcp-sa-firebasestorage.iam.gserviceaccount.com'] }] };
  assert.equal((await deploy.preflight(fake.request, ['storage'], { root, log: quiet })).ok, true);
  assert.equal((await deploy.preflight(fake.request, ['firestore'], { root, log: quiet })).skipped, true);
});

test('before/after record releases; a re-run keeps the first rollback target', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rules-'));
  const fake = fakeRules();
  const { docs, firestore } = fakeFirestore();
  const env = { GITHUB_RUN_ID: '7', GITHUB_REPOSITORY: 'o/r', GITHUB_EVENT_NAME: 'workflow_dispatch' };
  const deps = { firestore, env, log: quiet, now: () => 'T' };
  const out = path.join(dir, 'before.json');
  await deploy.main(['before', '--sha', 'abc', '--out', out], { ...deps, request: fake.request });
  assert.deepEqual(JSON.parse(fs.readFileSync(out, 'utf8')).releases, {
    'cloud.firestore': FS_LIVE,
    'firebase.storage/bluejay-d926f.firebasestorage.app': ST_LIVE,
  });
  assert.equal(docs['rules_deployments/abc'].before['cloud.firestore'], FS_LIVE);
  assert.equal(docs['rules_deployments/abc'].runs[0].runUrl, 'https://github.com/o/r/actions/runs/7');

  // The deploy released a new ruleset.
  fake.state.releases[0].rulesetName = `${P}/rulesets/fs-new`;
  const smokeFile = path.join(dir, 'smoke.json');
  fs.writeFileSync(smokeFile, JSON.stringify({ ok: true, passed: 11, failed: 0, skipped: 0, expressionLimit: [] }));
  await deploy.main(['after', '--sha', 'abc', '--status', 'deployed', '--smoke', smokeFile], { ...deps, request: fake.request });
  const doc = docs['rules_deployments/abc'];
  assert.equal(doc.status, 'deployed');
  assert.equal(doc.after['cloud.firestore'], `${P}/rulesets/fs-new`);
  assert.equal(doc.smoke.passed, 11);

  // Re-running the same SHA must not make fs-new the rollback target.
  await deploy.main(['before', '--sha', 'abc', '--services', 'firestore'], { ...deps, request: fake.request });
  assert.equal(docs['rules_deployments/abc'].before['cloud.firestore'], FS_LIVE);
  assert.equal(docs['rules_deployments/abc'].runs.length, 3);
});

test('--no-firestore writes only the artifact', async () => {
  const { docs, firestore } = fakeFirestore();
  await deploy.main(['before', '--sha', 'x', '--no-firestore'], { request: fakeRules().request, firestore, log: quiet });
  assert.deepEqual(docs, {});
});

// ── prod_smoke ─────────────────────────────────────────────────────────────

test('classify: allow, deny, missing doc, expression limit, other errors', () => {
  assert.equal(smoke.classify(200, { name: 'x' }).outcome, 'ALLOW');
  assert.equal(smoke.classify(200, [{ readTime: 't' }]).outcome, 'ALLOW');
  assert.equal(smoke.classify(404, { error: { code: 404 } }).outcome, 'ALLOW');
  assert.equal(smoke.classify(403, { error: { code: 403, status: 'PERMISSION_DENIED', message: 'Missing or insufficient permissions.' } }).outcome, 'DENY');
  assert.equal(smoke.classify(403, [{ error: { code: 403, status: 'PERMISSION_DENIED' } }]).outcome, 'DENY');
  const limit = smoke.classify(403, { error: { code: 403, status: 'PERMISSION_DENIED', message: 'Null value error. The maximum of 1000 expressions to evaluate has been reached.' } });
  assert.equal(limit.outcome, 'EXPRESSION_LIMIT');
  assert.equal(smoke.judge({ expect: 'DENY' }, limit).ok, false, 'an expression-limit deny is never a pass');
  assert.equal(smoke.classify(500, { error: { message: 'boom' } }).outcome, 'ERROR');
});

test('personaProblems rejects platform roles, inactive accounts and overlapping groups', () => {
  const persona = { name: 'dev', uid: 'u', group: 'developer' };
  assert.deepEqual(smoke.personaProblems(persona, { status: 'ACTIVE', roles: [], groups: ['developer', 'bluejay'] }, ['games']), []);
  const problems = smoke.personaProblems(persona, { status: 'INACTIVE', roles: ['developer'], groups: ['games'] }, ['games']);
  assert.equal(problems.length, 4);
  assert.match(smoke.personaProblems(persona, null, [])[0], /no access index/);
});

test('collectionProbes: every declared collection gets an anonymous deny, plus cross-group denies from samples', () => {
  const table = { collections: { d: {}, a: { apps: ['x'] }, apps: { kind: 'platform' } } };
  assert.deepEqual(smoke.declaredCollections(table).map(([n]) => n), ['a', 'apps', 'd']);
  const personas = [{ name: 'p1' }, { name: 'p2' }];
  const { probes, skipped } = smoke.collectionProbes(table, personas, { a: { p1: { foreign: 'a/1', own: 'a/2' }, p2: { foreign: null, own: null } } });
  assert.deepEqual(probes.map((p) => [p.persona, p.path, p.expect, p.stage]), [
    [null, 'a/prod-smoke-probe', 'DENY', 'collections'],
    ['p1', 'a/1', 'DENY', 'collections'],
    ['p1', 'a/2', 'ALLOW', 'collections'],
    [null, 'apps/prod-smoke-probe', 'DENY', 'collections'],
    [null, 'd/prod-smoke-probe', 'DENY', 'collections'],
  ]);
  assert.equal(skipped.length, 3, 'p2 has no sample for a, nobody has one for d; platform kinds need none');
});

/** Fake Admin SDK (db reads + custom tokens) and fetch for a full smoke run. */
function smokeWorld({ index = {}, denyAll = false, limitOn = null } = {}) {
  const data = {
    'users/u1/metadata/access_index': { status: 'ACTIVE', roles: [], groups: ['developer'], entitlements: ['developer:notes'], ...index },
    'users/u2/metadata/access_index': { status: 'ACTIVE', roles: [], groups: ['games'], entitlements: ['games:notes'] },
    'groups/developer': { installedApps: ['notes'] },
    'groups/games': { installedApps: ['trivia'] },
  };
  const notes = [{ id: 'n1', groupId: 'developer', appId: 'notes' }, { id: 'n2', groupId: 'games', appId: 'notes' }];
  const query = (filters, lim) => ({
    where: (f, _op, v) => query([...filters, [f, v]], lim),
    limit: (n) => query(filters, n),
    get: async () => {
      const docs = notes.filter((d) => filters.every(([f, v]) => d[f] === v)).slice(0, lim).map((d) => ({ id: d.id, get: (f) => d[f] }));
      return { empty: !docs.length, docs };
    },
  });
  const admin = {
    auth: { createCustomToken: async (uid) => `ct-${uid}` },
    db: {
      doc: (p) => ({ get: async () => ({ exists: !!data[p], data: () => data[p] }) }),
      collection: () => query([], 1000),
    },
  };
  const requests = [];
  const fetchFn = async (url, opts) => {
    requests.push({ url, opts });
    const json = (status, body) => ({ status, text: async () => JSON.stringify(body) });
    if (url.includes('signInWithCustomToken')) {
      const { token } = JSON.parse(opts.body);
      return json(200, { idToken: token.replace('ct-', 'id-') });
    }
    const auth = opts.headers.authorization;
    if (limitOn && url.includes(limitOn)) return json(403, { error: { code: 403, status: 'PERMISSION_DENIED', message: 'The maximum of 1000 expressions to evaluate has been reached.' } });
    if (!auth || denyAll) return json(403, { error: { code: 403, status: 'PERMISSION_DENIED', message: 'Missing or insufficient permissions.' } });
    // A minimal "enforced" engine: a token may read notes only in its own group.
    const m = url.match(/documents\/notes\/(n\d)/);
    if (m) {
      const doc = notes.find((d) => d.id === m[1]);
      const group = auth === 'Bearer id-u1' ? 'developer' : 'games';
      if (doc.groupId !== group) return json(403, { error: { code: 403, status: 'PERMISSION_DENIED' } });
    }
    return json(200, url.endsWith(':runQuery') ? [{ readTime: 't' }] : { name: url });
  };
  return { admin, fetchFn, requests };
}

function accountsFile() {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-')), 'accounts.json');
  fs.writeFileSync(file, JSON.stringify({
    personas: [
      { name: 'developer-member', uid: 'u1', group: 'developer' },
      { name: 'games-member', uid: 'u2', group: 'games' },
    ],
  }));
  return file;
}

test('smoke run: core allows plus the anonymous deny pass with no declared collection', async () => {
  const { admin, fetchFn, requests } = smokeWorld();
  const summary = await smoke.main(['--accounts', accountsFile()], { admin, fetch: fetchFn, apiKey: 'k', table: { collections: {} }, log: quiet });
  assert.equal(summary.ok, true);
  assert.equal(summary.passed, 11);
  assert.ok(requests.every((r) => (r.opts.method || 'GET') === 'GET' || r.url.endsWith(':runQuery') || r.url.includes('signInWithCustomToken')), 'reads only');
});

test('smoke run: a declared collection probes an anonymous deny, a cross-group deny and an own-group allow', async () => {
  const { admin, fetchFn } = smokeWorld();
  const table = { collections: { notes: { apps: ['notes'] } } };
  const summary = await smoke.main(['--accounts', accountsFile()], { admin, fetch: fetchFn, apiKey: 'k', table, log: quiet });
  const probed = summary.results.filter((r) => r.stage === 'collections');
  assert.deepEqual(probed.map((r) => [r.persona, r.path, r.expect, r.outcome]), [
    [null, 'notes/prod-smoke-probe', 'DENY', 'DENY'],
    ['developer-member', 'notes/n2', 'DENY', 'DENY'],
    ['developer-member', 'notes/n1', 'ALLOW', 'ALLOW'],
    ['games-member', 'notes/n1', 'DENY', 'DENY'],
    ['games-member', 'notes/n2', 'ALLOW', 'ALLOW'],
  ]);
  assert.equal(summary.ok, true);
});

test('smoke run fails on denied core flows and flags the expression limit', async () => {
  const prev = process.exitCode;
  const denied = smokeWorld({ denyAll: true });
  const s1 = await smoke.main(['--accounts', accountsFile()], { admin: denied.admin, fetch: denied.fetchFn, apiKey: 'k', table: { collections: {} }, log: quiet });
  assert.equal(s1.ok, false);
  assert.equal(s1.failed, 10);

  const limited = smokeWorld({ limitOn: 'groups/developer' });
  const lines = [];
  const s2 = await smoke.main(['--accounts', accountsFile()], { admin: limited.admin, fetch: limited.fetchFn, apiKey: 'k', table: { collections: {} }, log: (l) => lines.push(l) });
  assert.deepEqual(s2.expressionLimit, ['developer-member: get own group']);
  assert.ok(lines.some((l) => l.startsWith('::error::"maximum of 1000 expressions"')));
  process.exitCode = prev;
});

test('smoke run refuses unsuitable accounts before signing in', async () => {
  const prev = process.exitCode;
  const { admin, fetchFn, requests } = smokeWorld({ index: { roles: ['admin'] } });
  const summary = await smoke.main(['--accounts', accountsFile()], { admin, fetch: fetchFn, apiKey: 'k', table: { collections: {} }, log: quiet });
  assert.equal(summary.ok, false);
  assert.match(summary.setupProblems[0], /platform role/);
  assert.equal(requests.length, 0);
  process.exitCode = prev;
});

test('the committed smoke accounts name two distinct groups', () => {
  const { personas } = JSON.parse(fs.readFileSync(path.join(__dirname, 'prod_smoke_accounts.json'), 'utf8'));
  const groups = personas.map((p) => p.group);
  assert.equal(groups.length, 2);
  assert.equal(new Set(groups).size, 2, `smoke personas share a group: ${groups.join(', ')}`);
  for (const p of personas) assert.match(p.uid, /^[A-Za-z0-9]{20,}$/);
});

test('pickSamples only counts an adminOnlyCollection doc as own when the persona holds the app :admin tier', async () => {
  // Fake Firestore: collection(name).where(field, '==', value).limit(n).get() over fixed docs.
  const docs = {
    audit_events: [
      { id: 'evUsers', data: { groupId: 'games', appId: 'users' } },
      { id: 'evChess', data: { groupId: 'games', appId: 'chess' } },
    ],
    notes: [{ id: 'n1', data: { groupId: 'games', appId: 'notes' } }],
  };
  const query = (rows, filters = []) => ({
    where: (field, _op, value) => query(rows, [...filters, [field, value]]),
    limit: () => query(rows, filters),
    get: async () => {
      const hit = rows.filter((r) => filters.every(([f, v]) => r.data[f] === v));
      return { empty: !hit.length, docs: hit.map((r) => ({ id: r.id, get: (k) => r.data[k] })) };
    },
  });
  const db = { collection: (name) => query(docs[name] || []) };
  const table = {
    collections: {
      audit_events: { kind: 'tenant', adminOnlyCollection: true },
      notes: { kind: 'tenant', app: 'notes' },
    },
  };
  const personas = [{ name: 'games-member', uid: 'u6', group: 'games' }];
  // A member of games who uses Users and Notes and administers Chess.
  const indexes = { 'games-member': { groups: ['games'], entitlements: ['games:users', 'games:notes', 'games:chess', 'games:chess:admin'] } };
  const samples = await smoke.pickSamples(db, table, personas, indexes);
  // Users events need games:users:admin, which the persona lacks; the Chess event is theirs.
  assert.equal(samples.audit_events['games-member'].own, 'audit_events/evChess');
  // Ordinary tenant collections still need only the base entitlement.
  assert.equal(samples.notes['games-member'].own, 'notes/n1');

  const memberOnly = { 'games-member': { groups: ['games'], entitlements: ['games:users', 'games:chess'] } };
  const none = await smoke.pickSamples(db, table, personas, memberOnly);
  assert.equal(none.audit_events['games-member'].own, null);
});

test('pickSamples counts an ownerScoped doc as own only when the persona owns it, and honours requiredClearance', async () => {
  const docs = {
    civ_empire_solo_games: [
      { id: 'theirs', data: { groupId: 'games', appId: 'civ-empire', creatorId: 'someone-else' } },
      { id: 'mine', data: { groupId: 'games', creatorId: 'u6' } },
    ],
    secrets: [{ id: 's1', data: { groupId: 'games', appId: 'vault' } }],
  };
  const query = (rows, filters = []) => ({
    where: (field, _op, value) => query(rows, [...filters, [field, value]]),
    limit: () => query(rows, filters),
    get: async () => {
      const hit = rows.filter((r) => filters.every(([f, v]) => r.data[f] === v));
      return { empty: !hit.length, docs: hit.map((r) => ({ id: r.id, get: (k) => r.data[k] })) };
    },
  });
  const db = { collection: (name) => query(docs[name] || []) };
  const table = {
    collections: {
      civ_empire_solo_games: { apps: ['civ-empire'], ownerScoped: true },
      secrets: { apps: ['vault'], requiredClearance: 2 },
    },
  };
  const personas = [{ name: 'games-member', uid: 'u6', group: 'games' }];
  const member = { groups: ['games'], entitlements: ['games:civ-empire', 'games:vault'], clearance_level: 1 };
  // The single-app scope comes from the table, so the doc without appId still counts.
  let samples = await smoke.pickSamples(db, table, personas, { 'games-member': member });
  assert.equal(samples.civ_empire_solo_games['games-member'].own, 'civ_empire_solo_games/mine');
  assert.equal(samples.secrets['games-member'].own, null);

  docs.civ_empire_solo_games.pop();
  samples = await smoke.pickSamples(db, table, personas, { 'games-member': { ...member, clearance_level: 2 } });
  assert.equal(samples.civ_empire_solo_games['games-member'].own, null);
  assert.equal(samples.secrets['games-member'].own, 'secrets/s1');

  // The app's :admin tier reads every member's doc.
  const admin = { ...member, entitlements: [...member.entitlements, 'games:civ-empire:admin'] };
  samples = await smoke.pickSamples(db, table, personas, { 'games-member': admin });
  assert.equal(samples.civ_empire_solo_games['games-member'].own, 'civ_empire_solo_games/theirs');
});
