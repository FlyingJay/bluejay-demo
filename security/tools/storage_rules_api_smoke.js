#!/usr/bin/env node
/**
 * Smoke-tests storage.rules through the Firebase Rules API's `test` method
 * (the production rules engine), with mocked firestore.get() results (plan
 * T16). Nothing is deployed and no ruleset is created; production is only
 * read (the released Storage ruleset).
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=... node security/tools/storage_rules_api_smoke.js [storage.rules]
 *
 * 1. RELEASED: reports whether the released firebase.storage ruleset equals
 *    the committed rules.
 * 2. CASES: the committed rules on representative cases, including what the
 *    2025-12-16 permissive release allowed and these rules don't.
 * 3. EVERY FAMILY: for each path of every family in
 *    security/storage_paths.json, a signed-out read (DENY), and for the
 *    generic families a signed-in read (signedIn: ALLOW, none: DENY) and
 *    write (DENY).
 *
 * The emulator suite (security/rules-tests/test/storage.test.js) covers far
 * more cases in CI; this confirms compile and decisions on the production
 * engine, which also differs from the emulator in places (production can
 * stringify a path wildcard, the emulator can't). Needs `npm ci` in
 * functions/ (google-auth-library) and credentials allowed to call
 * firebaserules on bluejay-d926f.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const api = require('./rules_api');
const gs = require(path.join(ROOT, 'security', 'generate_storage.js'));

const BUCKET = 'bluejay-d926f.firebasestorage.app';
const UID = 'u1';

const ix = (over = {}) => ({ status: 'ACTIVE', roles: [], groups: ['g1'], denied_scopes: [], entitlements: ['g1:notes'], ...over });
const indexMock = (uid, index) => ({
  function: 'firestore.get',
  args: [{ exactValue: `/databases/(default)/documents/users/${uid}/metadata/access_index` }],
  result: index ? { value: { data: index } } : { undefined: {} },
});
const groupMock = (g, adminIds) => ({
  function: 'firestore.get',
  args: [{ exactValue: `/databases/(default)/documents/groups/${g}` }],
  result: { value: { data: { adminIds } } },
});
const tenant = (g, a, creatorId, extra = {}) => ({ creatorId, groupId: g, appId: a, ...extra });

// [label, object path, method, expectation, stored metadata (null: no object), sent metadata, mocks, signed out?]
const IX = ix();
const CASES = [
  // What the 2025-12-16 permissive release allowed and these rules don't.
  ['formerly open: overwrite another group\'s file', 'groups/g9/apps/notes/a.txt', 'update', 'DENY', tenant('g9', 'notes', 'u2'), tenant('g9', 'notes', UID), [indexMock(UID, IX)]],
  ['formerly open: delete a legacy file', 'gallery_photos/x.jpg', 'delete', 'DENY', {}, null, []],
  ['formerly open: a root-level object', 'foo.txt', 'get', 'DENY', {}, null, []],
  ['formerly open: groups/{g}', 'groups/g1', 'get', 'DENY', {}, null, []],
  ['formerly open: groups/{g}/misc/x', 'groups/g1/misc/x', 'delete', 'DENY', {}, null, []],
  ['tenant: member reads', 'groups/g1/apps/notes/a.txt', 'get', 'ALLOW', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, IX)]],
  ['tenant: other group reads', 'groups/g2/apps/notes/a.txt', 'get', 'DENY', tenant('g2', 'notes', 'u2'), null, [indexMock(UID, IX)]],
  ['tenant: public file of another group (D2)', 'groups/g2/apps/notes/a.txt', 'get', 'DENY', tenant('g2', 'notes', 'u2', { visibility: 'public' }), null, [indexMock(UID, IX)]],
  ['tenant: removed creator reads own (D1)', 'groups/g1/apps/notes/a.txt', 'get', 'DENY', tenant('g1', 'notes', UID), null, [indexMock(UID, ix({ groups: [], entitlements: [] }))]],
  ['tenant: base member deletes another\'s', 'groups/g1/apps/notes/a.txt', 'delete', 'DENY', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, IX)]],
  ['tenant: base member deletes own', 'groups/g1/apps/notes/a.txt', 'delete', 'ALLOW', tenant('g1', 'notes', UID), null, [indexMock(UID, IX)]],
  ['tenant: editor deletes another\'s', 'groups/g1/apps/notes/a.txt', 'delete', 'ALLOW', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, ix({ entitlements: ['g1:notes', 'g1:notes:edit'] }))]],
  ['tenant: frozen group', 'groups/g1/apps/notes/a.txt', 'get', 'DENY', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, ix({ denied_scopes: ['g1'] }))]],
  ['tenant: suspended member', 'groups/g1/apps/notes/a.txt', 'get', 'DENY', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, ix({ status: 'SUSPENDED' }))]],
  ['tenant: overwrite another\'s as base (create over existing)', 'groups/g1/apps/notes/a.txt', 'create', 'DENY', tenant('g1', 'notes', 'u2'), tenant('g1', 'notes', UID), [indexMock(UID, IX)]],
  ['tenant: editor overwrites, becomes creator', 'groups/g1/apps/notes/a.txt', 'create', 'ALLOW', tenant('g1', 'notes', 'u2'), tenant('g1', 'notes', UID), [indexMock(UID, ix({ entitlements: ['g1:notes:edit'] }))]],
  ['tenant: editor stamps someone else as creator', 'groups/g1/apps/notes/a.txt', 'update', 'DENY', tenant('g1', 'notes', 'u2'), tenant('g1', 'notes', 'u3'), [indexMock(UID, ix({ entitlements: ['g1:notes:edit'] }))]],
  ['tenant: steal creatorId as base', 'groups/g1/apps/notes/a.txt', 'update', 'DENY', tenant('g1', 'notes', 'u2'), tenant('g1', 'notes', UID), [indexMock(UID, IX)]],
  ['tenant: retag groupId', 'groups/g1/apps/notes/a.txt', 'update', 'DENY', tenant('g1', 'notes', UID), tenant('g2', 'notes', UID), [indexMock(UID, IX)]],
  ['tenant: update own metadata', 'groups/g1/apps/notes/a.txt', 'update', 'ALLOW', tenant('g1', 'notes', UID), tenant('g1', 'notes', UID, { note: 'x' }), [indexMock(UID, IX)]],
  ['tenant: platform admin reads another group', 'groups/g9/apps/notes/a.txt', 'get', 'ALLOW', tenant('g9', 'notes', 'u2'), null, [indexMock(UID, ix({ roles: ['admin'], groups: [] }))]],
  ['tenant: platform admin deletes in another group', 'groups/g9/apps/notes/a.txt', 'delete', 'DENY', tenant('g9', 'notes', 'u2'), null, [indexMock(UID, ix({ roles: ['admin'], groups: [] }))]],
  ['tenant: no access index', 'groups/g1/apps/notes/a.txt', 'get', 'DENY', tenant('g1', 'notes', 'u2'), null, [indexMock(UID, null)]],
  // retainedFolders: attachments are uploaded, never deleted or replaced from a client. (A new
  // upload needs `resource == null`, which a Rules API test case can't express; the emulator's
  // storage.test.js covers it.)
  ['retained: uploader deletes their bug file', 'groups/g1/apps/improve-apps/bug_reports_media/a.png', 'delete', 'DENY', tenant('g1', 'improve-apps', UID), null, [indexMock(UID, ix({ entitlements: ['g1:improve-apps'] }))]],
  ['retained: editor deletes another\'s app request file', 'groups/g1/apps/app-maker/app_request_media/a.png', 'delete', 'DENY', tenant('g1', 'app-maker', 'u2'), null, [indexMock(UID, ix({ entitlements: ['g1:app-maker', 'g1:app-maker:edit'] }))]],
  ['retained: signatures admin deletes a document', 'groups/g1/apps/signatures/signature_documents/c.pdf', 'delete', 'DENY', tenant('g1', 'signatures', 'u2'), null, [indexMock(UID, ix({ entitlements: ['g1:signatures', 'g1:signatures:admin'] }))]],
  ['retained: uploader overwrites a document to sign', 'groups/g1/apps/signatures/signature_documents/c.pdf', 'create', 'DENY', tenant('g1', 'signatures', UID), tenant('g1', 'signatures', UID), [indexMock(UID, ix({ entitlements: ['g1:signatures'] }))]],
  ['retained: uploader retags an idea file', 'groups/g1/apps/improve-apps/feature_request_media/a.png', 'update', 'DENY', tenant('g1', 'improve-apps', UID), tenant('g1', 'improve-apps', UID, { note: 'x' }), [indexMock(UID, ix({ entitlements: ['g1:improve-apps'] }))]],
  ['retained: other folders of the app keep own-file deletes', 'groups/g1/apps/improve-apps/scratch/a.png', 'delete', 'ALLOW', tenant('g1', 'improve-apps', UID), null, [indexMock(UID, ix({ entitlements: ['g1:improve-apps'] }))]],
  // Logos are written only by groupAdminSetLogo (server-side): no client, not even an admin.
  ['logo: group admin (adminIds) write blocked (server-only)', 'groups/g1/logo.jpg', 'update', 'DENY', {}, {}, [indexMock(UID, IX), groupMock('g1', [UID])]],
  ['logo: platform admin write blocked (server-only)', 'groups/g1/logo.jpg', 'update', 'DENY', {}, {}, [indexMock(UID, ix({ roles: ['admin'] }))]],
  ['logo: temp path write blocked', `groups/temp_${UID}/logo.jpg`, 'update', 'DENY', {}, {}, [indexMock(UID, IX)]],
  ['logo: any signed-in user reads', 'groups/g9/logo.jpg', 'get', 'ALLOW', {}, null, []],
  ['logo thumb: admin write blocked (server-only)', 'groups/g1/logo_thumb.png', 'update', 'DENY', {}, {}, [indexMock(UID, ix({ roles: ['admin'] }))]],
  ['app icon: developer writes', 'app_icons/i.png', 'update', 'ALLOW', {}, {}, [indexMock(UID, ix({ roles: ['developer'] }))]],
  ['app icon: member writes', 'app_icons/i.png', 'update', 'DENY', {}, {}, [indexMock(UID, IX)]],
  ['profile: owner writes', `profile_pictures/${UID}/p.jpg`, 'update', 'ALLOW', { creatorId: UID }, { creatorId: UID }, []],
  ['profile: someone else\'s picture', 'profile_pictures/u2/p.jpg', 'update', 'DENY', { creatorId: 'u2' }, { creatorId: UID }, []],
  ['profile: co-member reads', 'profile_pictures/u2/p.jpg', 'get', 'ALLOW', {}, null, [indexMock(UID, IX), indexMock('u2', ix())]],
  ['profile: stranger reads', 'profile_pictures/u2/p.jpg', 'get', 'DENY', {}, null, [indexMock(UID, IX), indexMock('u2', ix({ groups: ['g2'] }))]],
  ['profile: legacy flat write', 'profile_pictures/p.jpg', 'update', 'DENY', {}, { creatorId: UID }, []],
  ['published: signed-in read', 'published/g1/notes/x.jpg', 'get', 'ALLOW', {}, null, []],
  ['published: client write', 'published/g1/notes/x.jpg', 'update', 'DENY', {}, {}, []],
  ['chat_images: read', 'chat_images/x.jpg', 'get', 'ALLOW', {}, null, []],
  ['legacy gallery: read (after M8)', 'gallery_photos/x.jpg', 'get', 'DENY', {}, null, []],
  ['server-only: read', 'warehouse_private/g1/x.csv', 'get', 'DENY', {}, null, []],
  ['unmatched: write', 'zz/x', 'update', 'DENY', {}, {}, []],
  ['signed out: logo read', 'groups/g1/logo.jpg', 'get', 'DENY', {}, null, [], true],
];

/** An object path inside a family path pattern. */
function samplePath(pattern) {
  return pattern.replace('{groupId}', 'g1').replace('{appId}', 'notes').replace('/**', '/smoke/x.txt');
}

/** Generic per-family probes (see the header, 3.). */
function everyFamilyCases(table) {
  const out = [];
  for (const [name, f] of Object.entries(table.families)) {
    for (const pattern of f.paths) {
      const p = samplePath(pattern);
      out.push([`${name} (${p}): signed out reads`, p, 'get', 'DENY', {}, null, [], true]);
      if (f.read !== 'block') out.push([`${name} (${p}): signed-in read`, p, 'get', f.read === 'signedIn' ? 'ALLOW' : 'DENY', {}, null, [indexMock(UID, IX)]]);
      if (f.write === 'none') out.push([`${name} (${p}): signed-in write`, p, 'update', 'DENY', {}, {}, [indexMock(UID, IX)]]);
    }
  }
  return out;
}

function testCase([, objectPath, method, expectation, stored, sent, functionMocks, signedOut]) {
  const request = { path: `/b/${BUCKET}/o/${objectPath}`, method };
  // Signed out: an explicit null (the Rules API answers 500 when `auth` is absent).
  request.auth = signedOut ? null : { uid: UID };
  if (sent) request.resource = { name: objectPath, bucket: BUCKET, metadata: sent };
  return {
    expectation,
    request,
    ...(stored ? { resource: { name: objectPath, bucket: BUCKET, metadata: stored } } : {}),
    functionMocks,
  };
}

async function runSuite(request, title, source, cases) {
  const res = await request({
    url: `https://firebaserules.googleapis.com/v1/projects/${api.PROJECT}:test`,
    method: 'POST',
    data: { source: { files: [{ name: 'storage.rules', content: source }] }, testSuite: { testCases: cases.map(testCase) } },
  });
  if (res.status !== 200) throw new Error(`Rules API returned ${res.status}: ${JSON.stringify(res.data).slice(0, 300)}`);
  const errors = (res.data.issues || []).filter((i) => i.severity === 'ERROR');
  for (const e of errors) console.log(`compile error, line ${e.sourcePosition && e.sourcePosition.line}: ${e.description}`);
  let passed = 0;
  console.log(`--- ${title}`);
  (res.data.testResults || []).forEach((r, i) => {
    const ok = r.state === 'SUCCESS';
    if (ok) passed += 1;
    const why = ok ? '' : `  ${(r.debugMessages || []).join(' ').slice(0, 160)}`;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${cases[i][0]} (expect ${cases[i][3]})${why}`);
  });
  console.log(`${title}: ${passed}/${cases.length} as expected, ${errors.length} compile error(s).`);
  return !errors.length && passed === cases.length;
}

async function main() {
  const file = process.argv[2] || gs.RULES_PATH;
  const committed = fs.readFileSync(file, 'utf8');
  const request = await api.defaultRequest();

  const [release] = await api.releasesFor(request, 'storage');
  const ruleset = await api.getRuleset(request, release.rulesetName);
  const live = ruleset.source.files.map((f) => f.content).join('\n');
  console.log(`${live === committed ? 'ok  ' : 'note'} the released ruleset ${release.rulesetName} ` +
    `${live === committed ? 'equals' : 'DIFFERS FROM'} ${path.relative(ROOT, file)}`);

  const results = [];
  results.push(await runSuite(request, 'representative cases', committed, CASES));
  results.push(await runSuite(request, 'every family', committed, everyFamilyCases(gs.loadStorageTable())));
  if (results.some((ok) => !ok)) process.exitCode = 1;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = { CASES, testCase, everyFamilyCases };
