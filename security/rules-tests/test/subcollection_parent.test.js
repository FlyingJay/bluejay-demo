// Subcollection writes check their parent document. A batch (or
// transaction) that creates the parent and its first subcollection docs
// together is judged against the parent as the batch leaves it, since the
// parent's own create is checked in the same request. A parent that already
// exists is judged as it was before the request, so a batch can't soft-delete
// or reshape a parent to change what its subcollection writes may do.
// Presentations' deck + versions/1 is the motivating shape.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const { doc, setDoc, deleteDoc, writeBatch, runTransaction, serverTimestamp } = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
const A = 'ua', B = 'ub', OUT = 'uout';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0, groups: [G] };
const INDEX = {
  [A]: { ...ACTIVE, entitlements: [`${G}:presentations`] },
  [B]: { ...ACTIVE, entitlements: [`${G}:presentations`] },
  [OUT]: { ...ACTIVE, entitlements: [] },
};
const ID = 'AbCdEfGhIjKlMnOpQrSt';
const ID_2 = 'TsRqPoNmLkJiHgFeDcBa';
const stamp = (uid) => ({ lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });
const tenant = (uid, groupId = G) => ({ groupId, appId: 'presentations', creatorId: uid, ownerIds: [uid] });
const deck = (uid, extra = {}) => ({ ...tenant(uid), title: 'Q4 review', slides: [], version: 1, ...stamp(uid), ...extra });
const version = (uid, n = 1, groupId = G) => ({ ...tenant(uid, groupId), number: n, title: 'Q4 review', slides: [], ...stamp(uid) });

function deckWithVersion(d, uid, id, { deckExtra = {}, versionGroup = G } = {}) {
  const b = writeBatch(d);
  b.set(doc(d, `presentation_decks/${id}`), deck(uid, deckExtra));
  b.set(doc(d, `presentation_decks/${id}/versions/1`), version(uid, 1, versionGroup));
  return b.commit();
}

test('subcollection writes in the same batch as their parent', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-sub-parent', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'presentation_decks/d1'), { ...deck(A), lastModifiedAt: 1 });
    await setDoc(doc(db, 'presentation_decks/d1/versions/1'), { ...version(A), lastModifiedAt: 1 });
  });
  const [a, b, out] = [A, B, OUT].map((u) => env.authenticatedContext(u).firestore());

  const ok = [
    ['creating a deck and its first version in one batch', () => deckWithVersion(a, A, ID)],
    ['saving a new version of an existing deck in a transaction', () => runTransaction(a, async (tx) => {
      await tx.get(doc(a, 'presentation_decks/d1'));
      tx.update(doc(a, 'presentation_decks/d1'), { version: 2, ...stamp(A) });
      tx.set(doc(a, 'presentation_decks/d1/versions/2'), version(A, 2));
    })],
  ];
  const deny = [
    ['someone without the app creating a deck with a version', () => deckWithVersion(out, OUT, ID_2)],
    ['a new version filed under another group than its new deck', () => deckWithVersion(a, A, ID_2, { versionGroup: 'g2' })],
    ['a version under a deck that does not exist and is not created', () => setDoc(doc(a, `presentation_decks/${ID_2}/versions/1`), version(A))],
    ['another member writing a version of someone\'s deck', () => setDoc(doc(b, 'presentation_decks/d1/versions/3'), version(B, 3))],
    ['deleting a version', () => deleteDoc(doc(a, 'presentation_decks/d1/versions/1'))],
  ];

  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`subcollection parent: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
