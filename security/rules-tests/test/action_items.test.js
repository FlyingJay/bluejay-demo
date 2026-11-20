// The To do feed (functions/_action_items.js; packages/notifications
// action_items.dart) against the committed rules: action_items is kind
// server with readerListField assigneeUids. An assignee reads their open
// items in every group with the Notifications app's query
// (`assigneeUids array-contains uid`, `status == 'open'`); anyone else,
// group admins included, can't; and no client writes one.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, limit,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1', G2 = 'g2';
// A is an assignee in both groups; B is a member and admin of G who isn't
// assigned; O is in neither group.
const A = 'ua', B = 'ub', O = 'uo';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0 };
const INDEX = {
  [A]: { ...ACTIVE, groups: [G, G2], entitlements: [`${G}:app-access`, `${G}:app-access:admin`, `${G2}:expenses`] },
  [B]: { ...ACTIVE, groups: [G], entitlements: [`${G}:app-access`, `${G}:app-access:admin`] },
  [O]: { ...ACTIVE, groups: ['g9'], entitlements: [] },
};
const item = (groupId, assigneeUids, extra = {}) => ({
  groupId, appId: 'app-access', appName: 'App Access', kind: 'portal_pending_client',
  title: 'A client is waiting', body: '', assigneeUids, audience: { type: 'group_admins' },
  context: { type: 'portal_pending_client', clientUid: 'c1', actionItemKey: 'k' },
  status: 'open', createdAt: 1, updatedAt: 1, resolvedAt: null, resolvedBy: null, outcome: null, ...extra,
});

test('action_items: assignees read their open items; nobody writes', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-action-items', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, `groups/${G}`), { groupId: G, name: 'G', memberIds: [A, B], adminIds: [A, B] });
    await setDoc(doc(db, 'action_items/k1'), item(G, [A]));
    await setDoc(doc(db, 'action_items/k2'), item(G2, [A], { appId: 'expenses', kind: 'expenses_review' }));
    await setDoc(doc(db, 'action_items/k3'), item(G, [A], { status: 'resolved', outcome: 'approved' }));
    await setDoc(doc(db, 'action_items/kB'), item(G, [O]));
  });
  const as = (uid) => env.authenticatedContext(uid, { email: `${uid}@x.ca` }).firestore();
  const [a, b, o] = [A, B, O].map(as);
  const anon = env.unauthenticatedContext().firestore();
  // ActionItemsFeed.openQuery, as the To do tab (limit 200) and the
  // launcher's badges (limit kBadgeCountCap) read it.
  const openFor = (d, uid, n = 200) => getDocs(query(collection(d, 'action_items'),
    where('assigneeUids', 'array-contains', uid), where('status', '==', 'open'), limit(n)));

  const ok = [
    ['assignee lists their open items across groups', async () => {
      const snap = await openFor(a, A);
      const ids = snap.docs.map((d) => d.id).sort();
      if (JSON.stringify(ids) !== JSON.stringify(['k1', 'k2'])) throw new Error(`got ${ids}`);
      return snap;
    }],
    ['assignee lists them with the badge limit', () => openFor(a, A, 99)],
    ['assignee gets one item', () => getDoc(doc(a, 'action_items/k1'))],
    ['assignee gets a resolved item of theirs', () => getDoc(doc(a, 'action_items/k3'))],
    ['someone outside the group gets an item naming them', () => getDoc(doc(o, 'action_items/kB'))],
  ];
  const deny = [
    // Reads: only the people named in assigneeUids.
    ['group admin gets an item that does not name them', () => getDoc(doc(b, 'action_items/k1'))],
    ['non-assignee runs the query for the assignee', () => openFor(b, A)],
    ['outsider runs the query for the assignee', () => openFor(o, A)],
    ['member lists the group\'s items', () => getDocs(query(collection(b, 'action_items'), where('groupId', '==', G)))],
    ['member lists open items without naming themselves', () => getDocs(query(collection(b, 'action_items'), where('status', '==', 'open')))],
    ['signed out gets an item', () => getDoc(doc(anon, 'action_items/k1'))],
    // Writes: the Admin SDK only, assignee or not.
    ['assignee resolves their item', () => updateDoc(doc(a, 'action_items/k1'), { status: 'resolved' })],
    ['assignee adds someone to an item', () => updateDoc(doc(a, 'action_items/k1'), { assigneeUids: [A, B] })],
    ['assignee deletes their item', () => deleteDoc(doc(a, 'action_items/k1'))],
    ['member creates an item for themselves', () => setDoc(doc(b, 'action_items/new'), item(G, [B]))],
    ['admin creates an item for someone else', () => setDoc(doc(b, 'action_items/new2'), item(G, [A]))],
    ['non-assignee deletes an item', () => deleteDoc(doc(b, 'action_items/k1'))],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`action_items: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
