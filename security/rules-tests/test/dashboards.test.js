// Dashboards (security/collections.json `dashboards`, plans/dashboards):
// a dashboard is its owner's alone (singleOwner, ownerScoped). The owner
// edits title, spec and pinned directly; the request pipeline's fields
// (status, draftSpec, draftVersionId, requestPrompt, queueItemId, requestId,
// sourceIds, publishedAt) are serverFields. versions/{id} are immutable
// snapshots: the owner adds one naming themselves with createdAt the request
// time, only its note changes afterwards, and none is deleted. The
// feature_requests `dashboardRequest` map is server-only, like requestKind.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, serverTimestamp,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
// A owns d1; B is another member with Dashboards; ADM holds its :admin tier.
const A = 'ua', B = 'ub', ADM = 'uadm';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0, groups: [G] };
const INDEX = {
  [A]: { ...ACTIVE, entitlements: [`${G}:dashboards`, `${G}:improve-apps`] },
  [B]: { ...ACTIVE, entitlements: [`${G}:dashboards`, `${G}:dashboards:edit`, `${G}:improve-apps`] },
  [ADM]: { ...ACTIVE, entitlements: [`${G}:dashboards`, `${G}:dashboards:admin`] },
};
const tenant = (creatorId = A) => ({ groupId: G, appId: 'dashboards', creatorId, ownerIds: [creatorId] });
const SPEC = { specVersion: 1, title: 'Mine' };

test('dashboards: owner-only, server pipeline fields, immutable versions', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-dashboards', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'dashboards/d1'), {
      ...tenant(), title: 'Mine', spec: SPEC, pinned: false, status: 'ready_to_try', draftSpec: SPEC, draftVersionId: 'v1',
      requestId: 'f1', queueItemId: 'feature__f1', sourceIds: [],
    });
    await setDoc(doc(db, 'dashboards/d2'), { ...tenant(), title: 'Old', spec: SPEC, pinned: false });
    await setDoc(doc(db, 'dashboards/d1/versions/v1'), { ...tenant(), spec: SPEC, note: 'Built from your request', createdAt: 1 });
  });
  const [a, b, adm] = [A, B, ADM].map((u) => env.authenticatedContext(u).firestore());
  const version = (uid, extra = {}) => ({ ...tenant(uid), spec: SPEC, note: 'Edited', createdAt: serverTimestamp(), ...extra });

  const ok = [
    ['owner lists own dashboards (queryOwned)', () => getDocs(query(collection(a, 'dashboards'), where('groupId', '==', G), where('ownerIds', 'array-contains', A)))],
    ['owner opens their dashboard', () => getDoc(doc(a, 'dashboards/d1'))],
    ['owner creates a dashboard', () => setDoc(doc(a, 'dashboards/AbCdEfGhIjKlMnOpQrSt'), { ...tenant(), title: 'New', spec: SPEC, pinned: false, createdAt: serverTimestamp(), updatedAt: serverTimestamp() })],
    ['owner renames, pins and edits the spec', () => updateDoc(doc(a, 'dashboards/d1'), { title: 'Renamed', pinned: true, spec: SPEC, updatedAt: serverTimestamp(), currentVersionId: 'v2' })],
    ['owner records a version', () => setDoc(doc(a, 'dashboards/d1/versions/v2'), version(A))],
    ['owner reads the versions', () => getDocs(collection(a, 'dashboards/d1/versions'))],
    ['owner relabels a version', () => updateDoc(doc(a, 'dashboards/d1/versions/v1'), { note: 'The first one' })],
    ['app admin opens a member\'s dashboard', () => getDoc(doc(adm, 'dashboards/d1'))],
    ['owner deletes their dashboard', () => deleteDoc(doc(a, 'dashboards/d2'))],
  ];
  const deny = [
    ['another member opens it', () => getDoc(doc(b, 'dashboards/d1'))],
    ['another member lists the group\'s dashboards', () => getDocs(query(collection(b, 'dashboards'), where('groupId', '==', G)))],
    ['another member (even :edit) edits it', () => updateDoc(doc(b, 'dashboards/d1'), { title: 'Mine now' })],
    ['another member reads its versions', () => getDocs(collection(b, 'dashboards/d1/versions'))],
    ['owner marks their own request live', () => updateDoc(doc(a, 'dashboards/d1'), { status: 'live' })],
    ['owner writes the draft', () => updateDoc(doc(a, 'dashboards/d1'), { draftSpec: { specVersion: 1, title: 'x' } })],
    ['owner points at another draft version', () => updateDoc(doc(a, 'dashboards/d1'), { draftVersionId: 'v9' })],
    ['owner rewrites the request history', () => updateDoc(doc(a, 'dashboards/d1'), { requestHistory: [] })],
    ['owner rewrites the request text', () => updateDoc(doc(a, 'dashboards/d1'), { requestPrompt: 'something else' })],
    ['owner sets publishedAt', () => updateDoc(doc(a, 'dashboards/d1'), { publishedAt: serverTimestamp() })],
    ['owner relinks the request', () => updateDoc(doc(a, 'dashboards/d1'), { requestId: 'other', queueItemId: 'feature__other' })],
    ['owner creates a dashboard that reads as requested', () => setDoc(doc(a, 'dashboards/AbCdEfGhIjKlMnOpQrSu'), { ...tenant(), title: 'x', status: 'requested' })],
    ['owner creates one with sourceIds', () => setDoc(doc(a, 'dashboards/AbCdEfGhIjKlMnOpQrSv'), { ...tenant(), title: 'x', sourceIds: ['chat.conversation'] })],
    ['owner creates a co-owned dashboard', () => setDoc(doc(a, 'dashboards/AbCdEfGhIjKlMnOpQrSw'), { ...tenant(), ownerIds: [A, B], title: 'x' })],
    ['owner rewrites a version\'s spec', () => updateDoc(doc(a, 'dashboards/d1/versions/v1'), { spec: { specVersion: 1, title: 'changed' } })],
    ['owner deletes a version', () => deleteDoc(doc(a, 'dashboards/d1/versions/v1'))],
    ['owner backdates a version', () => setDoc(doc(a, 'dashboards/d1/versions/v3'), version(A, { createdAt: 1 }))],
    ['owner records a version as someone else', () => setDoc(doc(a, 'dashboards/d1/versions/v4'), version(B))],
    ['another member adds a version', () => setDoc(doc(b, 'dashboards/d1/versions/v5'), version(B))],
    ['a client writes a share', () => setDoc(doc(a, 'dashboard_shares/abc'), { dashboardId: 'd1' })],
    ['a client reads a share', () => getDoc(doc(a, 'dashboard_shares/abc'))],
    ['a client reads a share\'s views', () => getDoc(doc(a, 'dashboard_shares/abc/stats/views'))],
    ['a client writes share rate limits', () => setDoc(doc(a, 'dashboard_share_rate_limits/ip_x'), { attempts: [] })],
    ['a requester files an idea marked as a dashboard request', () => setDoc(doc(a, 'feature_requests/AbCdEfGhIjKlMnOpQrSt'), {
      groupId: G, appId: 'improve-apps', creatorId: A, ownerIds: [A], title: 't', description: 'd', requesterId: A,
      dashboardRequest: { dashboardId: 'd1', prompt: 'p', availableSources: [] },
      lastModifiedAt: serverTimestamp(), lastModifiedBy: A,
    })],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`dashboards: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
