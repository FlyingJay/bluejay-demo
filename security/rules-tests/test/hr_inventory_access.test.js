// HR's staff directory and Inventory's stock movements (security/collections.json).
//
// hr_people: HR editors (:edit) write the directory, but a person's userId
// (the account that reads their hr_private) and managerUid (who sees and
// decides their time off) are serverFields, set only by hrSetPersonLinks for
// HR :admin. So an editor can't link someone's record to their own account or
// make themself the manager, on create or on update, and neither can an HR
// admin from the client.
//
// inventory_movements: any member with the app records a movement, which
// inventoryOnMovementCreated applies to stock. The collection is not
// guestWritable, so a guest of the group holding `:guest` for the app gets
// nothing from the tenant grant (detail()) and can't record one.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const { doc, getDoc, setDoc, updateDoc, serverTimestamp } = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
// EDITOR holds HR :edit, HRADMIN HR :admin, MEMBER Inventory's base tier,
// GUEST is a guest of the group with Inventory :guest.
const EDITOR = 'u-editor', HRADMIN = 'u-hradmin', MEMBER = 'u-member', GUEST = 'u-guest', VICTIM = 'u-victim';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0, groups: [G] };
const INDEX = {
  [EDITOR]: { ...ACTIVE, entitlements: [`${G}:hr`, `${G}:hr:edit`] },
  [HRADMIN]: { ...ACTIVE, entitlements: [`${G}:hr`, `${G}:hr:admin`] },
  [MEMBER]: { ...ACTIVE, entitlements: [`${G}:inventory`] },
  [GUEST]: { ...ACTIVE, guest_groups: [G], entitlements: [`${G}:inventory:guest`] },
};
const tenant = (appId, creatorId) => ({ groupId: G, appId, creatorId, ownerIds: [creatorId] });
const stamp = (uid) => ({ lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });

test('hr_people links and inventory_movements guests', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-hr-inventory', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'hr_people/victim'), {
      ...tenant('hr', HRADMIN), displayName: 'Vic', userId: VICTIM, managerUid: HRADMIN, jobTitle: 'Clerk',
      lastModifiedBy: HRADMIN, lastModifiedAt: 1,
    });
    await setDoc(doc(db, 'inventory_items/i1'), { ...tenant('inventory', MEMBER), name: 'Bolts' });
  });
  const [editor, hrAdmin, member, guest] = [EDITOR, HRADMIN, MEMBER, GUEST].map((u) => env.authenticatedContext(u).firestore());
  const person = (uid, extra = {}) => ({ ...tenant('hr', uid), displayName: 'New', jobTitle: '', ...stamp(uid), ...extra });
  const movement = (uid) => ({ ...tenant('inventory', uid), itemId: 'i1', type: 'receive', quantity: 5, ...stamp(uid) });

  const ok = [
    ['hr: editor edits a person\'s job title', () => updateDoc(doc(editor, 'hr_people/victim'), { jobTitle: 'Lead', ...stamp(EDITOR) })],
    ['hr: editor adds a person without links', () => setDoc(doc(editor, 'hr_people/AbCdEfGhIjKlMnOpQrSt'), person(EDITOR))],
    ['hr: editor reads the directory', () => getDoc(doc(editor, 'hr_people/victim'))],
    ['inventory: member records a movement', () => setDoc(doc(member, 'inventory_movements/AbCdEfGhIjKlMnOpQrSt'), movement(MEMBER))],
  ];
  const deny = [
    ['hr: editor links a person to their own account', () => updateDoc(doc(editor, 'hr_people/victim'), { userId: EDITOR, ...stamp(EDITOR) })],
    ['hr: editor makes themself the manager', () => updateDoc(doc(editor, 'hr_people/victim'), { managerUid: EDITOR, ...stamp(EDITOR) })],
    ['hr: editor clears the manager', () => updateDoc(doc(editor, 'hr_people/victim'), { managerUid: '', ...stamp(EDITOR) })],
    ['hr: editor adds a person linked to an account', () => setDoc(doc(editor, 'hr_people/AbCdEfGhIjKlMnOpQrSu'), person(EDITOR, { userId: VICTIM }))],
    ['hr: editor adds a person with themself as manager', () => setDoc(doc(editor, 'hr_people/AbCdEfGhIjKlMnOpQrSv'), person(EDITOR, { managerUid: EDITOR }))],
    ['hr: HR admin links an account from the client', () => updateDoc(doc(hrAdmin, 'hr_people/victim'), { userId: HRADMIN, ...stamp(HRADMIN) })],
    ['inventory: guest records a movement', () => setDoc(doc(guest, 'inventory_movements/AbCdEfGhIjKlMnOpQrSu'), movement(GUEST))],
    ['inventory: guest reads an item', () => getDoc(doc(guest, 'inventory_items/i1'))],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`hr/inventory: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
