'use strict';
/**
 * The committed storage.rules against lib/expected_storage.js (plan T16).
 *
 * Every path family x persona x get / list / create / forge (new file
 * stamped with someone else's uid) / overwrite (upload over an existing
 * file) / update (metadata) / retag (metadata groupId changed) / delete.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { setup } = require('../lib/personas');
const { pool } = require('../lib/run');
const { evaluateStorage, targetDecision, CLOSED_ISSUES, OPS } = require('../lib/expected_storage');
const gs = require('../../generate_storage');
const W = require('../lib/world');

const BYTES = new Uint8Array([1, 2, 3]);
const COMMITTED = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'storage.rules'), 'utf8');
const TABLE = gs.loadStorageTable();

const tenantMeta = (g, a, creatorId) => ({ creatorId, groupId: g, appId: a });
const t = (g, a) => (name) => ({
  path: (actor, op) => `groups/${g}/apps/${a}/f/${name}-${op}-${actor}.txt`,
  meta: (actor) => tenantMeta(g, a, name.startsWith('own') ? actor : W.AUTHOR),
  upload: (actor) => tenantMeta(g, a, actor),
});
const platform = (pathFor, opts = {}) => ({
  path: pathFor,
  meta: (actor) => ({ creatorId: opts.ownedBy ? opts.ownedBy(actor) : W.AUTHOR, groupId: '~none', appId: 'x' }),
  upload: (actor) => ({ creatorId: actor, groupId: '~none', appId: 'x' }),
  shared: opts.shared,
  generic: opts.generic,
});
const generic = (pathFor, opts = {}) => platform(pathFor, { ...opts, generic: true });

/**
 * Personas. The generic signedIn/none families depend only on being signed
 * in, so they run with GENERIC_PERSONAS (signed out, signed in with no index,
 * a member); the tenant and block families run with every persona whose
 * index differs in a way the rules read.
 */
const GENERIC_PERSONAS = ['anon', 'u-no-index', 'u-member'];
const TARGET_PERSONAS = ['anon', 'u-no-index', 'u-member', 'u-editor', 'u-owner', 'u-group-admin', 'u-guest',
  'u-member-b', 'u-removed', 'u-frozen', 'u-suspended', 'u-admin', 'u-admin-suspended', 'u-developer'];

/** Path families: name -> { path(actor, op), meta(actor) stored, upload(actor) sent, shared }. */
const FIXTURES = {
  own: t(W.GROUP_A, W.APP_BETA)('own'),
  other: t(W.GROUP_A, W.APP_BETA)('other'),
  otherEditableApp: t(W.GROUP_A, W.APP_ALPHA)('other'),
  groupB: t(W.GROUP_B, W.APP_BETA)('other'),
  publicB: { ...t(W.GROUP_B, W.APP_BETA)('public'), meta: () => ({ ...tenantMeta(W.GROUP_B, W.APP_BETA, W.AUTHOR), visibility: 'public' }) },
  frozenOwn: t(W.GROUP_FROZEN, W.APP_BETA)('own'),
  guestAppOwn: t(W.GROUP_A, W.APP_GAMMA)('own'),
  guestAppOther: t(W.GROUP_A, W.APP_GAMMA)('other'),
  noMetadata: { ...t(W.GROUP_A, W.APP_ALPHA)('nometa'), meta: () => ({}) },
  logo: platform(() => `groups/${W.GROUP_A}/logo.jpg`, { shared: true }),
  tempLogo: platform((a) => `groups/temp_${a}/logo.jpg`, { shared: true }),
  logoThumb: generic((a, op) => `groups/${W.GROUP_B}/logo_thumb.png`, { shared: true }),
  logoVersion: generic(() => `groups/${W.GROUP_B}/logos/v1/logo.jpg`, { shared: true }),
  appsDir: generic((a, op) => `groups/${W.GROUP_A}/apps/x-${op}-${a}.txt`),
  groupMisc: generic((a, op) => `groups/${W.GROUP_A}/misc/${op}-${a}.txt`),
  profileOwn: platform((a, op) => `profile_pictures/${a}/${op}.jpg`, { ownedBy: (a) => a }),
  profileCoMember: platform((a, op) => `profile_pictures/u-member/${op}-${a}.jpg`, { ownedBy: () => 'u-member' }),
  profileStranger: platform((a, op) => `profile_pictures/u-member-b/${op}-${a}.jpg`, { ownedBy: () => 'u-member-b' }),
  profileFlat: platform((a, op) => `profile_pictures/${W.AUTHOR}-${op}-${a}.jpg`),
  appIcon: platform((a, op) => `app_icons/icon-${op}-${a}.png`),
  appIconThumb: generic((a, op) => `app_icons_thumbs/icon-${op}-${a}.png`),
  appScreenshot: generic((a, op) => `app_screenshots/lists/list-${op}-${a}_phone_light.png`),
  published: generic((a, op) => `published/${W.GROUP_B}/${W.APP_BETA}/p-${op}-${a}.jpg`),
  chatImage: generic((a, op) => `chat_images/img-${op}-${a}.jpg`),
  serverOnly: generic((a, op) => `warehouse_private/${W.GROUP_A}/f-${op}-${a}.csv`),
  legacyGallery: generic((a, op) => `gallery_photos/g-${op}-${a}.jpg`),
  legacyUsers: generic((a, op) => `users/${a}/files/u-${op}.bin`),
  removedApp: generic((a, op) => `recorder_audio/${a}/r-${op}.m4a`),
  unmatched: generic((a, op) => `zz_elsewhere/f-${op}-${a}.txt`),
};

async function attempt(ref, op, upload) {
  try {
    if (op === 'get') await ref.getMetadata();
    else if (op === 'list') await ref.parent.list({ maxResults: 1 });
    else if (op === 'create' || op === 'overwrite' || op === 'forge') await ref.put(BYTES, { customMetadata: upload });
    else if (op === 'update') await ref.updateMetadata({ customMetadata: { note: 'changed' } });
    else if (op === 'retag') await ref.updateMetadata({ customMetadata: { groupId: W.GROUP_B } });
    else await ref.delete();
    return true;
  } catch (err) {
    if (err.code === 'storage/unauthorized') return false;
    throw new Error(`${ref.fullPath} ${op}: ${err.code} ${err.message}`);
  }
}

/** The tenant and block families get TARGET_PERSONAS. */
function buildCases() {
  const cases = [];
  for (const [name, fx] of Object.entries(FIXTURES)) {
    for (const persona of fx.generic ? GENERIC_PERSONAS : TARGET_PERSONAS) {
      const actor = persona === 'anon' ? 'anon' : persona;
      for (const op of OPS) {
        const p = fx.path(actor, op);
        const stored = fx.meta(actor);
        let upload = fx.upload(actor);
        if (op === 'forge') upload = { ...upload, creatorId: W.AUTHOR };
        const exists = !['create', 'forge'].includes(op);
        let newMeta = upload;
        if (op === 'update') newMeta = { ...stored, note: 'changed' };
        if (op === 'retag') newMeta = { ...stored, groupId: W.GROUP_B };
        cases.push({
          persona, actor, name, op, shared: fx.shared,
          path: p,
          // A list request is evaluated on the listed prefix.
          evalPath: op === 'list' ? p.split('/').slice(0, -1).join('/') : p,
          stored, upload, exists, newMeta,
        });
      }
    }
  }
  return cases;
}

function expected(c, indexes) {
  const ownerOf = c.evalPath.startsWith('profile_pictures/') ? c.evalPath.split('/')[1] : null;
  const g = c.evalPath.startsWith('groups/') ? c.evalPath.split('/')[1] : null;
  return evaluateStorage({
    uid: c.persona === 'anon' ? null : c.persona,
    index: indexes[c.persona],
    subjectIndex: ownerOf ? indexes[ownerOf] : null,
    groupAdminIds: g && W.GROUPS[g] ? W.GROUPS[g].adminIds : [],
    op: c.op,
    path: c.evalPath,
    meta: c.exists && c.op !== 'list' ? c.stored : null,
    newMeta: c.newMeta,
  }, { table: TABLE }).allow;
}

/** Runs every case under [rules] and returns the mismatches against [want]. */
async function runAll(label, rules, want) {
  const t = await setup('demo-bluejay', { storage: rules });
  try {
    const cases = buildCases();
    const run = async (c) => {
      const admin = t.admin.storage.ref(c.path);
      if (c.exists) await admin.put(BYTES, { customMetadata: c.stored });
      else await admin.delete().catch(() => {});
      return attempt(t.clients[c.persona].storage.ref(c.path), c.op, c.upload);
    };
    const results = new Map();
    const parallel = cases.filter((c) => !c.shared);
    const got = await pool(parallel, 64, run);
    parallel.forEach((c, i) => results.set(c, got[i]));
    for (const c of cases.filter((x) => x.shared)) results.set(c, await run(c));

    const mismatches = [];
    let allowed = 0;
    for (const c of cases) {
      const w = want(c, t.indexes);
      if (w) allowed += 1;
      if (results.get(c) !== w) {
        mismatches.push(`${c.name} | ${c.persona} | ${c.op} (${c.evalPath}): rules ${results.get(c) ? 'ALLOW' : 'DENY'}, expected ${w ? 'ALLOW' : 'DENY'}`);
      }
    }
    console.log(`storage ${label}: ${cases.length} cases, ${allowed} allowed`);
    return { mismatches, cases, indexes: t.indexes };
  } finally {
    await t.teardown();
  }
}

const report = (m) => `${m.length} storage case(s) differ:\n  ${m.slice(0, 40).join('\n  ')}`;

test('the committed storage.rules match the model', { timeout: 15 * 60 * 1000 }, async () => {
  const { mismatches, cases, indexes } = await runAll('committed', COMMITTED, (c, ix) => expected(c, ix));
  assert.equal(mismatches.length, 0, report(mismatches));

  // The T2 known issues are closed in the target (CLOSED_ISSUES).
  const find = (name, persona, op) => cases.find((c) => c.name === name && c.persona === persona && c.op === op);
  const target = (c) => expected(c, indexes);
  const closures = {
    'KI-STORAGE-BARE-SCOPE-EDIT': [find('other', 'u-member', 'delete'), find('other', 'u-member', 'overwrite')],
    'KI-STORAGE-OWNERSHIP-OUTSIDE-TENANT': [find('own', 'u-removed', 'create'), find('own', 'u-member-b', 'create'), find('own', 'u-removed', 'get')],
    'KI-STORAGE-OVERWRITE-AS-CREATE': [find('other', 'u-member', 'overwrite'), find('groupB', 'u-member', 'overwrite')],
    'KI-STORAGE-PUBLIC-CROSS-TENANT': [find('publicB', 'u-member', 'get')],
    'KI-STORAGE-PROFILE-PICTURES': [find('profileCoMember', 'u-editor', 'create'), find('profileFlat', 'u-member', 'overwrite')],
  };
  assert.deepEqual(Object.keys(closures).sort(), Object.keys(CLOSED_ISSUES).sort());
  for (const [ki, list] of Object.entries(closures)) {
    for (const c of list) assert.equal(target(c), false, `${ki}: ${c.name} | ${c.persona} | ${c.op} must be denied`);
  }
  // ...without losing the intended grants.
  for (const [name, persona, op] of [
    ['own', 'u-member', 'create'], ['own', 'u-member', 'delete'], ['other', 'u-member', 'get'],
    ['other', 'u-editor', 'delete'], ['otherEditableApp', 'u-member', 'overwrite'],
    ['profileOwn', 'u-member', 'create'], ['profileCoMember', 'u-editor', 'get'], ['appIcon', 'u-developer', 'create'],
  ]) {
    assert.equal(target(find(name, persona, op)), true, `${name} | ${persona} | ${op} must stay allowed`);
  }
  // Guests reach only their app's guestWritableFolders, and the synthetic app has none.
  assert.equal(target(find('guestAppOwn', 'u-guest', 'create')), false, 'a guest uploads only in guestWritableFolders');
});

test('the model and the generated classifier agree on every fixture family', () => {
  const families = new Set(buildCases().map((c) => gs.familyOfPath(TABLE, c.evalPath)));
  for (const p of TARGET_PERSONAS) assert.ok(W.PERSONA_IDS.includes(p), p);
  for (const name of Object.keys(TABLE.families)) {
    if (name.startsWith('legacy_') && !['legacy_gallery_photos', 'legacy_users'].includes(name)) continue;
    assert.ok(families.has(name), `no storage fixture exercises family ${name}`);
  }
  assert.equal(typeof targetDecision, 'function');
});

// Stage 5 (rules plan §8.3, D1) ahead of stage 6: the Storage side of the
// embeddable apps' guest flows, with the real guest personas
// (lib/guests.js), against the committed storage.rules. Its Firestore side
// is in app_query_shapes.test.js.
test('stage 5: embeddable-app guests in Storage', { timeout: 5 * 60 * 1000 }, async () => {
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const guests = require('../lib/guests');
  const { G, GUEST, OTHER_GUEST, UNATTESTED } = guests;
  const env = await openTestEnv({
    // The project the emulators run (emulators:exec --project): the Storage
    // rules' firestore.get() reads the access index from its Firestore, so
    // only this file's suites use demo-bluejay.
    projectId: 'demo-bluejay',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', '..', '..', 'firestore.rules'), 'utf8') },
    storage: { rules: COMMITTED },
  });
  const meta = (appId, uid) => ({ creatorId: uid, groupId: G, appId });
  // ScopedStorage paths: groups/{g}/apps/{appId}/{folder}/...
  const propertyImage = (key, uid) => `groups/${G}/apps/rented-dwelling/property_images/${key}/${uid}.jpg`;
  const cocImage = (key, uid) => `groups/${G}/apps/course-of-construction/property_images/${key}/${uid}.jpg`;
  const naicInput = (uid, jobId) => `groups/${G}/apps/naic-sight/naic_sight/${uid}/${jobId}/input_f.csv`;
  const theirs = {
    [propertyImage('k1', OTHER_GUEST)]: meta('rented-dwelling', OTHER_GUEST),
    [naicInput(OTHER_GUEST, 'j1')]: meta('naic-sight', OTHER_GUEST),
    [naicInput(GUEST, 'j0')]: meta('naic-sight', GUEST),
    [`groups/${G}/logo.jpg`]: meta('groups', 'staff'),
  };
  await env.withSecurityRulesDisabled(async (ctx) => {
    await guests.seedGuests(ctx.firestore());
    for (const [p, customMetadata] of Object.entries(theirs)) await ctx.storage().ref(p).put(BYTES, { customMetadata });
  });
  const as = (uid) => env.authenticatedContext(uid).storage();
  const put = (uid, p, m) => () => as(uid).ref(p).put(BYTES, { customMetadata: m });
  const ok = [
    ['rd: guest persists a property image (AddressCacheService)', put(GUEST, propertyImage('k2', GUEST), meta('rented-dwelling', GUEST))],
    ['rd: guest reads their image back (getDownloadURL)', () => as(GUEST).ref(propertyImage('k2', GUEST)).getMetadata()],
    ['coc: guest persists a property image', put(GUEST, cocImage('k2', GUEST), meta('course-of-construction', GUEST))],
    ['naic: guest uploads a job input', put(GUEST, naicInput(GUEST, 'j2'), meta('naic-sight', GUEST))],
    ['naic: guest reads their own input', () => as(GUEST).ref(naicInput(GUEST, 'j0')).getMetadata()],
    ['naic: guest replaces their own input', put(GUEST, naicInput(GUEST, 'j0'), meta('naic-sight', GUEST))],
    ['guest reads the group logo (policy documents)', () => as(GUEST).ref(`groups/${G}/logo.jpg`).getMetadata()],
    ['rd: unattested guest persists a property image (public app)', put(UNATTESTED, propertyImage('k3', UNATTESTED), meta('rented-dwelling', UNATTESTED))],
  ];
  const deny = [
    ['rd: guest reads another guest\'s property image', () => as(GUEST).ref(propertyImage('k1', OTHER_GUEST)).getMetadata()],
    ['rd: guest overwrites another guest\'s property image', put(GUEST, propertyImage('k1', OTHER_GUEST), meta('rented-dwelling', GUEST))],
    ['rd: guest uploads in another uid\'s name', put(GUEST, propertyImage('k4', GUEST), meta('rented-dwelling', OTHER_GUEST))],
    ['rd: guest uploads outside the app\'s guestWritableFolders', put(GUEST, `groups/${G}/apps/rented-dwelling/policy_documents/p.pdf`,
      meta('rented-dwelling', GUEST))],
    ['naic: guest uploads outside the app\'s guestWritableFolders', put(GUEST, `groups/${G}/apps/naic-sight/exports/x.csv`,
      meta('naic-sight', GUEST))],
    ['rd: guest uploads under an app they aren\'t admitted to', put(GUEST, `groups/${G}/apps/warehouse-imports/files/x.csv`, meta('warehouse-imports', GUEST))],
    ['rd: guest lists the app\'s images', () => as(GUEST).ref(`groups/${G}/apps/rented-dwelling/property_images/k1`).list({ maxResults: 1 })],
    ['naic: guest reads another guest\'s input', () => as(GUEST).ref(naicInput(OTHER_GUEST, 'j1')).getMetadata()],
    ['naic: guest deletes another guest\'s input', () => as(GUEST).ref(naicInput(OTHER_GUEST, 'j1')).delete()],
    ['naic: unattested guest uploads (corporate app, not admitted)', put(UNATTESTED, naicInput(UNATTESTED, 'j3'), meta('naic-sight', UNATTESTED))],
    ['naic: guest writes the legacy naic_sight/ prefix', put(GUEST, `naic_sight/${GUEST}/j4/input_f.csv`, meta('naic-sight', GUEST))],
    ['guest replaces the group logo', put(GUEST, `groups/${G}/logo.jpg`, meta('groups', GUEST))],
  ];
  const fails = [];
  const outcome = async (f) => {
    try { await f(); return true; } catch (err) {
      if (err.code === 'storage/unauthorized') return false;
      throw err;
    }
  };
  for (const [n, f] of ok) if (!(await outcome(f))) fails.push(`ALLOW expected: ${n}`);
  for (const [n, f] of deny) if (await outcome(f)) fails.push(`DENY expected: ${n}`);
  await releaseTestEnv(env);
  console.log(`stage 5 storage: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  assert.equal(fails.length, 0, fails.join('\n'));
});

// retainedFolders (security/storage_paths.json): attachments regulated
// records point at are kept. Uploads work as before; nobody deletes,
// overwrites or retags a stored file there from a client, its uploader and
// the app's editors included. Other folders of the same app are unchanged.
test('retained folders: attachments are never deleted or replaced from a client', { timeout: 5 * 60 * 1000 }, async () => {
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const { doc, setDoc } = require('firebase/firestore');
  const env = await openTestEnv({
    projectId: 'demo-bluejay',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', '..', '..', 'firestore.rules'), 'utf8') },
    storage: { rules: COMMITTED },
  });
  const G = 'g-retain';
  const ACTIVE = { status: 'ACTIVE', roles: [], groups: [G], guest_groups: [], denied_scopes: [], clearance_level: 0 };
  const index = {
    'r-member': { ...ACTIVE, entitlements: [`${G}:improve-apps`, `${G}:app-maker`, `${G}:signatures`] },
    'r-editor': { ...ACTIVE, entitlements: [`${G}:improve-apps`, `${G}:improve-apps:edit`, `${G}:signatures`, `${G}:signatures:admin`] },
  };
  const meta = (appId, uid) => ({ creatorId: uid, groupId: G, appId });
  const bugFile = (name) => `groups/${G}/apps/improve-apps/bug_reports_media/${name}`;
  const ideaFile = (name) => `groups/${G}/apps/improve-apps/feature_request_media/${name}`;
  const requestFile = (name) => `groups/${G}/apps/app-maker/app_request_media/${name}`;
  const signedPdf = (name) => `groups/${G}/apps/signatures/signature_documents/${name}`;
  const loose = (name) => `groups/${G}/apps/improve-apps/scratch/${name}`;
  const stored = {
    [bugFile('mine.png')]: meta('improve-apps', 'r-member'),
    [ideaFile('mine.png')]: meta('improve-apps', 'r-member'),
    [requestFile('mine.png')]: meta('app-maker', 'r-member'),
    [signedPdf('contract.pdf')]: meta('signatures', 'r-member'),
    [loose('mine.png')]: meta('improve-apps', 'r-member'),
  };
  await env.withSecurityRulesDisabled(async (ctx) => {
    for (const [uid, ix] of Object.entries(index)) await setDoc(doc(ctx.firestore(), `users/${uid}/metadata/access_index`), ix);
    for (const [p, customMetadata] of Object.entries(stored)) await ctx.storage().ref(p).put(BYTES, { customMetadata });
  });
  const as = (uid) => env.authenticatedContext(uid).storage();
  const put = (uid, p, m) => () => as(uid).ref(p).put(BYTES, { customMetadata: m });
  const ok = [
    ['member attaches a new file to a bug', put('r-member', bugFile('new.png'), meta('improve-apps', 'r-member'))],
    ['member attaches a new file to an app request', put('r-member', requestFile('new.png'), meta('app-maker', 'r-member'))],
    ['member uploads a document to sign', put('r-member', signedPdf('new.pdf'), meta('signatures', 'r-member'))],
    ['member reads an attachment', () => as('r-member').ref(bugFile('mine.png')).getMetadata()],
    ['member deletes their own file outside a retained folder', () => as('r-member').ref(loose('mine.png')).delete()],
  ];
  const deny = [
    ['uploader deletes their bug attachment', () => as('r-member').ref(bugFile('mine.png')).delete()],
    ['uploader deletes their idea attachment', () => as('r-member').ref(ideaFile('mine.png')).delete()],
    ['uploader deletes their app request attachment', () => as('r-member').ref(requestFile('mine.png')).delete()],
    ['editor deletes someone else\'s bug attachment', () => as('r-editor').ref(bugFile('mine.png')).delete()],
    ['signatures admin deletes a document', () => as('r-editor').ref(signedPdf('contract.pdf')).delete()],
    ['uploader overwrites their bug attachment', put('r-member', bugFile('mine.png'), meta('improve-apps', 'r-member'))],
    ['uploader replaces a document to sign', put('r-member', signedPdf('contract.pdf'), meta('signatures', 'r-member'))],
    ['uploader retags their attachment', () => as('r-member').ref(bugFile('mine.png')).updateMetadata({ customMetadata: { ...meta('improve-apps', 'r-member'), note: 'x' } })],
  ];
  const fails = [];
  const outcome = async (f) => {
    try { await f(); return true; } catch (err) {
      if (err.code === 'storage/unauthorized') return false;
      throw err;
    }
  };
  for (const [n, f] of ok) if (!(await outcome(f))) fails.push(`ALLOW expected: ${n}`);
  for (const [n, f] of deny) if (await outcome(f)) fails.push(`DENY expected: ${n}`);
  await releaseTestEnv(env);
  assert.equal(fails.length, 0, fails.join('\n'));

  // The expected-outcome model agrees.
  const table = gs.loadStorageTable();
  const req = (op, p, uid) => ({ uid, index: index[uid], op, path: p, meta: stored[p] || null, newMeta: meta(p.split('/')[3], uid) });
  assert.equal(targetDecision(req('delete', bugFile('mine.png'), 'r-member'), table), false);
  assert.equal(targetDecision(req('overwrite', signedPdf('contract.pdf'), 'r-member'), table), false);
  assert.equal(targetDecision(req('create', bugFile('fresh.png'), 'r-member'), table), true);
  assert.equal(targetDecision(req('delete', loose('mine.png'), 'r-member'), table), true);
});

// Portal clients (functions/_client_portal.js): with `{g}:storage:guest` /
// `{g}:chat:guest` a client uploads and reads only their own files in the
// Storage app's client_uploads and Messages' images folders
// (guestWritableFolders), within the apps' guestUploadLimits. Members read
// what clients upload as they read any of the app's files.
test('portal clients: uploads to the business and chat images', { timeout: 5 * 60 * 1000 }, async () => {
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const { doc, setDoc } = require('firebase/firestore');
  const env = await openTestEnv({
    projectId: 'demo-bluejay',
    firestore: { rules: fs.readFileSync(path.join(__dirname, '..', '..', '..', 'firestore.rules'), 'utf8') },
    storage: { rules: COMMITTED },
  });
  const G = 'g-portal-files';
  const [A, K, K2, V, X] = ['pa', 'pk', 'pk2', 'pv', 'px'];
  const ACTIVE = { status: 'ACTIVE', roles: [], denied_scopes: [], clearance_level: 0 };
  const index = {
    [A]: { ...ACTIVE, groups: [G], guest_groups: [], entitlements: [`${G}:chat`, `${G}:storage`] },
    [K]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [`${G}:chat:guest`, `${G}:storage:guest`] },
    [K2]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [`${G}:chat:guest`, `${G}:storage:guest`] },
    [V]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [] },
    [X]: { ...ACTIVE, groups: [], guest_groups: [], entitlements: [] },
  };
  const upload = (uid, name) => `groups/${G}/apps/storage/client_uploads/${uid}_${name}`;
  const meta = (uid, appId = 'storage') => ({ creatorId: uid, groupId: G, appId });
  const pdf = 'application/pdf';
  await env.withSecurityRulesDisabled(async (ctx) => {
    for (const [uid, ix] of Object.entries(index)) await setDoc(doc(ctx.firestore(), `users/${uid}/metadata/access_index`), ix);
    const storage = ctx.storage();
    await storage.ref(upload(K, 'x.pdf')).put(BYTES, { customMetadata: meta(K), contentType: pdf });
    await storage.ref(upload(K2, 'y.pdf')).put(BYTES, { customMetadata: meta(K2), contentType: pdf });
    await storage.ref(`groups/${G}/apps/storage/files/a.pdf`).put(BYTES, { customMetadata: meta(A), contentType: pdf });
    await storage.ref(`groups/${G}/apps/chat/images/a.jpg`).put(BYTES, { customMetadata: meta(A, 'chat'), contentType: 'image/jpeg' });
  });
  const as = (uid) => env.authenticatedContext(uid).storage();
  const put = (uid, p, m, contentType, bytes = BYTES) => () => as(uid).ref(p).put(bytes, { customMetadata: m, contentType });
  const outcome = async (f) => {
    try { await f(); return true; } catch (err) {
      if (err.code === 'storage/unauthorized') return false;
      throw err;
    }
  };
  const ok = [
    ['client uploads a PDF to client_uploads', put(K, upload(K, 'new.pdf'), meta(K), pdf)],
    ['client uploads a photo to client_uploads', put(K, upload(K, 'new.jpg'), meta(K), 'image/jpeg')],
    ['client reads their upload', () => as(K).ref(upload(K, 'x.pdf')).getMetadata()],
    ['member reads a client upload', () => as(A).ref(upload(K, 'x.pdf')).getMetadata()],
    ['client attaches an image in Messages', put(K, `groups/${G}/apps/chat/images/${K}.jpg`, meta(K, 'chat'), 'image/jpeg')],
  ];
  const deny = [
    ['client uploads in another uid\'s name', put(K, upload(K, 'forged.pdf'), meta(K2), pdf)],
    ['client reads another client\'s upload', () => as(K).ref(upload(K2, 'y.pdf')).getMetadata()],
    ['client overwrites another client\'s upload', put(K, upload(K2, 'y.pdf'), meta(K), pdf)],
    ['client uploads outside client_uploads', put(K, `groups/${G}/apps/storage/files/k.pdf`, meta(K), pdf)],
    ['client reads a member\'s file object', () => as(K).ref(`groups/${G}/apps/storage/files/a.pdf`).getMetadata()],
    ['client uploads a program', put(K, upload(K, 'run.exe'), meta(K), 'application/x-msdownload')],
    ['client uploads an oversized file', put(K, upload(K, 'big.pdf'), meta(K), pdf, new Uint8Array(26214401))],
    ['client attaches a PDF as a chat image', put(K, `groups/${G}/apps/chat/images/${K}.pdf`, meta(K, 'chat'), pdf)],
    ['visitor without Storage uploads to client_uploads', put(V, upload(V, 'v.pdf'), meta(V), pdf)],
    ['removed client uploads', put(X, upload(X, 'r.pdf'), meta(X), pdf)],
    ['client reads a member\'s chat image object', () => as(K).ref(`groups/${G}/apps/chat/images/a.jpg`).getMetadata()],
  ];
  const fails = [];
  for (const [n, f] of ok) if (!(await outcome(f))) fails.push(`ALLOW expected: ${n}`);
  for (const [n, f] of deny) if (await outcome(f)) fails.push(`DENY expected: ${n}`);
  await releaseTestEnv(env);
  assert.equal(fails.length, 0, fails.join('\n'));
});
