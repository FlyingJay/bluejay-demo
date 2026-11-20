// Spreadsheet import's batch records (import_batches, plans/spreadsheet-import
// §5): written by the person importing through the shared import screen,
// ownerScoped, so a member sees and undoes only their own imports and the
// importing app's :admin tier sees everyone's. The doc's appId is the
// importing app; specId, collection and parentId never change; nothing is
// deleted (an undone import is marked undone); the rows subcollection holds
// the chunk records, follows its parent and is never deleted either. Both
// are on the audit trail, so every write carries the audit stamp.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, serverTimestamp,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
// A and B are base-tier members of CRM and Inventory; ADM holds CRM's :admin
// tier; OUT has no CRM at all.
const A = 'ua', B = 'ub', ADM = 'uadm', OUT = 'uout';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0, groups: [G] };
const INDEX = {
  [A]: { ...ACTIVE, entitlements: [`${G}:crm`, `${G}:inventory`] },
  [B]: { ...ACTIVE, entitlements: [`${G}:crm`] },
  [ADM]: { ...ACTIVE, entitlements: [`${G}:crm`, `${G}:crm:admin`] },
  [OUT]: { ...ACTIVE, entitlements: [`${G}:inventory`] },
};
const RANDOM_ID = 'AbCdEfGhIjKlMnOpQrSt';
const RANDOM_ID_2 = 'TsRqPoNmLkJiHgFeDcBa';
const stamp = (uid) => ({ lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });
const tenant = (appId, uid) => ({ groupId: G, appId, creatorId: uid, ownerIds: [uid] });
const batch = (appId, uid, extra = {}) => ({
  ...tenant(appId, uid),
  specId: 'crm.deal',
  collection: 'crm_deals',
  parentId: null,
  fileName: 'deals.csv',
  rowCount: 2,
  options: { duplicates: 'skip', replaceExisting: false },
  status: 'writing',
  counts: { created: 0, updated: 0, skipped: 0, failed: 0 },
  chunkCount: 0,
  startedAt: serverTimestamp(),
  ...stamp(uid),
  ...extra,
});
const mine = (d, uid) => query(collection(d, 'import_batches'), where('groupId', '==', G), where('appId', '==', 'crm'),
  where('ownerIds', 'array-contains', uid), where('specId', '==', 'crm.deal'));
const all = (d) => query(collection(d, 'import_batches'), where('groupId', '==', G), where('appId', '==', 'crm'),
  where('specId', '==', 'crm.deal'));

test('import batches: the importer and the app admins', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-import-batches', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    const existing = { ...batch('crm', A), startedAt: 1, lastModifiedAt: 1, status: 'done' };
    await setDoc(doc(db, 'import_batches/b1'), existing);
    await setDoc(doc(db, 'import_batches/b1/rows/0000'), { ...tenant('crm', A), created: [{ id: 'd1', h: 'x', k: ['title'] }], updated: [] });
  });
  const [a, b, adm, out] = [A, B, ADM, OUT].map((u) => env.authenticatedContext(u).firestore());

  const ok = [
    ['member starts an import in their app', () => setDoc(doc(a, `import_batches/${RANDOM_ID}`), batch('crm', A))],
    ['member writes a chunk record of their own import', () =>
      setDoc(doc(a, `import_batches/b1/rows/0001`), { ...tenant('crm', A), created: [{ id: 'd2', h: 'y', k: ['title'] }], updated: [], ...stamp(A) })],
    ['member finishes their import', () => updateDoc(doc(a, 'import_batches/b1'), { status: 'done', counts: { created: 1 }, ...stamp(A) })],
    ['member lists their own imports (Recent imports)', () => getDocs(mine(a, A))],
    ['member reads their chunk records (undo)', () => getDocs(collection(a, 'import_batches/b1/rows'))],
    ['member marks their import undone', () => updateDoc(doc(a, 'import_batches/b1'), { status: 'undone', undoneAt: serverTimestamp(), undoneBy: A, ...stamp(A) })],
    ['app admin lists everyone\'s imports', () => getDocs(all(adm))],
    ['app admin reads a member\'s chunk records', () => getDocs(collection(adm, 'import_batches/b1/rows'))],
    ['app admin undoes a member\'s import', () => updateDoc(doc(adm, 'import_batches/b1'), { status: 'undone', ...stamp(ADM) })],
    ['member of another adopting app starts an import there', () =>
      setDoc(doc(a, `import_batches/${RANDOM_ID_2}`), batch('inventory', A, { specId: 'inventory.item', collection: 'inventory_items' }))],
  ];
  const deny = [
    ['another member reads someone\'s import', () => getDoc(doc(b, 'import_batches/b1'))],
    ['another member lists without an ownership filter', () => getDocs(all(b))],
    ['another member reads someone\'s chunk records', () => getDocs(collection(b, 'import_batches/b1/rows'))],
    ['another member marks someone\'s import undone', () => updateDoc(doc(b, 'import_batches/b1'), { status: 'undone', ...stamp(B) })],
    ['someone without the app starts an import in it', () => setDoc(doc(out, `import_batches/${RANDOM_ID}`), batch('crm', OUT))],
    ['an import for an app that hasn\'t adopted import', () =>
      setDoc(doc(a, `import_batches/${RANDOM_ID}`), batch('notes', A))],
    ['an import missing the audit stamp', () => {
      const { lastModifiedBy, lastModifiedAt, ...unstamped } = batch('crm', A);
      return setDoc(doc(a, `import_batches/${RANDOM_ID}`), unstamped);
    }],
    ['changing what an import was for', () => updateDoc(doc(a, 'import_batches/b1'), { specId: 'crm.other', ...stamp(A) })],
    ['changing the collection an import wrote to', () => updateDoc(doc(a, 'import_batches/b1'), { collection: 'contacts', ...stamp(A) })],
    ['deleting an import record', () => deleteDoc(doc(a, 'import_batches/b1'))],
    ['an app admin deleting an import record', () => deleteDoc(doc(adm, 'import_batches/b1'))],
    ['deleting a chunk record', () => deleteDoc(doc(a, 'import_batches/b1/rows/0000'))],
    ['a chunk record missing the audit stamp', () =>
      setDoc(doc(a, 'import_batches/b1/rows/0002'), { ...tenant('crm', A), created: [], updated: [] })],
    ['another member writing a chunk into someone\'s import', () =>
      setDoc(doc(b, 'import_batches/b1/rows/0003'), { ...tenant('crm', B), created: [], updated: [], ...stamp(B) })],
  ];

  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`import batches: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
