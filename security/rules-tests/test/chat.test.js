// Chat (packages/chats) against the committed rules: conversations are
// ownerScoped (ownerIds == members), no client creates one (the
// chatStartConversation callable does) or deletes one, membership fields are
// adminOnly (the chatAddMembers callable changes them), and messages are a
// governed subcollection: each is its sender's (authorField senderId,
// authorEmailField senderEmail, createdAtField timestamp), and other
// participants mark only their own uid in readBy (selfArrayFields) and their
// own entry in reactionsByUser (selfMapFields).
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, orderBy, arrayUnion, arrayRemove, deleteField,
  serverTimestamp,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
// A started c1 with B; C is in the group but not the conversation; R was in
// it and was removed; E is a chat editor outside it; ADM a chat admin of G;
// O belongs to another group.
const A = 'ua', B = 'ub', C = 'uc', R = 'ur', E = 'ue', ADM = 'uadm', O = 'uo';
const email = (u) => `${u}@x.ca`;
const RANDOM_ID = 'AbCdEfGhIjKlMnOpQrSt';
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0 };
const INDEX = {
  [A]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`] },
  [B]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`] },
  [C]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`] },
  [R]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`] },
  [E]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`, `${G}:chat:edit`] },
  [ADM]: { ...ACTIVE, groups: [G], entitlements: [`${G}:chat`, `${G}:chat:admin`] },
  [O]: { ...ACTIVE, groups: ['g2'], entitlements: ['g2:chat'] },
};
const tenant = (creatorId, ownerIds = [creatorId]) => ({ groupId: G, appId: 'chat', creatorId, ownerIds });
const conversation = (creatorId, members) => ({
  ...tenant(creatorId, members), members, memberEmails: members.map(email), isGroupChat: true, groupName: 'Crew',
  lastMessage: 'hi', lastMessageTimestamp: 1,
});
// A stored message, and one as chat_screen.dart writes it (ScopedCollection
// stamps the tenant; the timestamp is the server's).
const stored = (sender, extra = {}) => ({
  ...tenant(sender), text: 'hello', senderId: sender, senderEmail: email(sender), imageUrl: null, timestamp: 1,
  isDeleted: false, readBy: [sender], ...extra,
});
const message = (sender, extra = {}) => stored(sender, { timestamp: serverTimestamp(), ...extra });

test('chat: participants, authors and own-uid marks', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-chat', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'conversations/c1'), conversation(A, [A, B]));
    await setDoc(doc(db, 'conversations/c1/messages/mA'), stored(A, { reactionsByUser: { [A]: '👍' } }));
    await setDoc(doc(db, 'conversations/c1/messages/mA2'), stored(A));
    // Left alone by the allowed cases, so the denied edits change something.
    await setDoc(doc(db, 'conversations/c1/messages/mA3'), stored(A, { reactionsByUser: { [A]: '👍' } }));
    await setDoc(doc(db, 'conversations/c1/messages/mB'), stored(B, { readBy: [B, A], reactionsByUser: { [A]: '🎉' } }));
    // Read by B then A; C marks it below, so the padding cases have someone to pad with.
    await setDoc(doc(db, 'conversations/c1/messages/mR'), stored(A, { readBy: [A, B] }));
    await setDoc(doc(db, 'conversations/c1/messages/sys'), {
      groupId: G, appId: 'chat', text: 'Ann added Bo', senderId: 'system', senderEmail: 'system', isSystemMessage: true, timestamp: 1, readBy: [],
    });
    // R was removed: no longer in members or ownerIds.
    await setDoc(doc(db, 'conversations/c3'), conversation(A, [A, B]));
    await setDoc(doc(db, 'conversations/c3/messages/old'), stored(R));
  });
  const as = (uid) => env.authenticatedContext(uid, { email: email(uid) }).firestore();
  const [a, b, c, r, e, adm, o] = [A, B, C, R, E, ADM, O].map(as);
  const msg = (d, id, conv = 'c1') => doc(d, `conversations/${conv}/messages/${id}`);
  const convs = (d) => collection(d, 'conversations');

  const ok = [
    // Reads: participants (by an ownerIds query, as the list screen does) and chat admins.
    ['participant lists their conversations', () => getDocs(query(convs(a), where('groupId', '==', G), where('ownerIds', 'array-contains', A), orderBy('lastMessageTimestamp', 'desc')))],
    ['participant gets the conversation', () => getDoc(doc(b, 'conversations/c1'))],
    ['participant lists messages', () => getDocs(collection(b, 'conversations/c1/messages'))],
    ['chat admin reads a conversation they are not in', () => getDoc(doc(adm, 'conversations/c1'))],
    // Posting.
    ['participant posts as themselves', () => setDoc(msg(b, RANDOM_ID), message(B))],
    ['participant posts with an empty reactions map', () => setDoc(msg(b, 'AbCdEfGhIjKlMnOpQrSu'), message(B, { reactionsByUser: {} }))],
    ['participant shares where they are', () => setDoc(msg(b, 'PlAcEfGhIjKlMnOpQrSu'), message(B, { text: '', place: { groupId: G, appId: 'crm', args: { deal: 'd1' }, title: 'Big deal' } }))],
    ['participant bumps lastMessage', () => updateDoc(doc(b, 'conversations/c1'), { lastMessage: 'yo', lastMessageTimestamp: 2 })],
    // Read receipts and reactions on someone else's message: own uid only.
    ['participant marks a message read', () => updateDoc(msg(b, 'mA'), { readBy: arrayUnion(B) })],
    ['participant writes readBy with their uid appended', () => updateDoc(msg(b, 'mA2'), { readBy: [A, B] })],
    ['participant reacts with several emojis', () => updateDoc(msg(b, 'mA2'), { [`reactionsByUser.${B}`]: '👍 ❤️ 🎉 👨‍👩‍👧‍👦' })],
    ['participant fills their entry to the client limit', () => updateDoc(msg(b, 'mA2'), { [`reactionsByUser.${B}`]: Array(21).fill('👍').join(' ') })],
    ['participant sets their reaction to null', () => updateDoc(msg(b, 'mA2'), { [`reactionsByUser.${B}`]: null })],
    ['participant marks a system message read', () => updateDoc(msg(b, 'sys'), { readBy: arrayUnion(B) })],
    ['participant reacts', () => updateDoc(msg(b, 'mA'), { [`reactionsByUser.${B}`]: '❤️' })],
    ['participant changes their reaction', () => updateDoc(msg(b, 'mA'), { [`reactionsByUser.${B}`]: '❤️ 🎉' })],
    ['participant clears their reaction', () => updateDoc(msg(b, 'mA'), { [`reactionsByUser.${B}`]: deleteField() })],
    ['participant unmarks themselves', () => updateDoc(msg(a, 'mB'), { readBy: arrayRemove(A) })],
    ['author reacts to their own message', () => updateDoc(msg(b, 'mB'), { [`reactionsByUser.${B}`]: '👍' })],
    // The author's own message.
    ['author soft-deletes their message', () => updateDoc(msg(a, 'mA'), { isDeleted: true, text: '', imageUrl: null })],
    ['author soft-deletes a shared place', () => updateDoc(msg(a, 'mA'), { isDeleted: true, text: '', imageUrl: null, place: null })],
    ['author deletes their message', () => deleteDoc(msg(a, 'mA2'))],
  ];
  const deny = [
    // Non-participants: another member, a removed member, an editor, another group.
    ['member outside the conversation gets it', () => getDoc(doc(c, 'conversations/c1'))],
    ['member outside lists its messages', () => getDocs(collection(c, 'conversations/c1/messages'))],
    ['member lists the group\'s conversations without ownerIds', () => getDocs(query(convs(c), where('groupId', '==', G)))],
    ['member lists by members (old query)', () => getDocs(query(convs(c), where('groupId', '==', G), where('members', 'array-contains', C)))],
    ['member outside posts', () => setDoc(msg(c, RANDOM_ID), message(C))],
    ['member outside bumps lastMessage', () => updateDoc(doc(c, 'conversations/c1'), { lastMessage: 'x' })],
    ['member outside marks a message read', () => updateDoc(msg(c, 'mA'), { readBy: arrayUnion(C) })],
    ['removed member reads', () => getDoc(doc(r, 'conversations/c3'))],
    ['removed member lists messages', () => getDocs(collection(r, 'conversations/c3/messages'))],
    ['removed member posts', () => setDoc(msg(r, RANDOM_ID, 'c3'), message(R))],
    ['removed member edits their old message', () => updateDoc(msg(r, 'old', 'c3'), { text: 'x' })],
    ['chat editor outside the conversation reads it', () => getDoc(doc(e, 'conversations/c1'))],
    ['chat editor outside edits it', () => updateDoc(doc(e, 'conversations/c1'), { lastMessage: 'x' })],
    ['another group reads', () => getDoc(doc(o, 'conversations/c1'))],
    // Nobody creates a conversation from a client, whatever its shape: the
    // chatStartConversation callable does.
    ['member starts a group chat they are in', () => setDoc(doc(c, `conversations/${RANDOM_ID}`), conversation(C, [C, A, B]))],
    ['member starts a direct chat at a tagged key', () => setDoc(doc(c, `conversations/${G}__dmkey`), { ...conversation(C, [A, C]), isGroupChat: false, directChatKey: 'dmkey' })],
    ['member creates someone else\'s direct chat', () => setDoc(doc(c, `conversations/${G}__abkey`), { ...conversation(C, [A, B]), isGroupChat: false, directChatKey: 'abkey' })],
    ['member creates a conversation they are not in', () => setDoc(doc(c, `conversations/${RANDOM_ID}`), conversation(C, [A, B]))],
    ['creator not among the members', () => setDoc(doc(c, `conversations/${RANDOM_ID}`), { ...conversation(A, [A, B]), creatorId: C })],
    ['chat admin creates a conversation', () => setDoc(doc(adm, `conversations/${RANDOM_ID}`), conversation(ADM, [ADM, A]))],
    // Forged senders.
    ['participant posts as someone else', () => setDoc(msg(b, RANDOM_ID), message(B, { senderId: A }))],
    ['participant posts as the system', () => setDoc(msg(b, RANDOM_ID), { ...message(B), senderId: 'system', isSystemMessage: true })],
    ['participant posts with someone else\'s email', () => setDoc(msg(b, RANDOM_ID), message(B, { senderEmail: email(A) }))],
    ['new message marked read by others', () => setDoc(msg(b, RANDOM_ID), message(B, { readBy: [B, A] }))],
    ['new message carrying someone else\'s reaction', () => setDoc(msg(b, RANDOM_ID), message(B, { reactionsByUser: { [A]: '👍' } }))],
    ['new message in another tenant', () => setDoc(msg(b, RANDOM_ID), { ...message(B), groupId: 'g2' })],
    ['new message with a client timestamp', () => setDoc(msg(b, RANDOM_ID), message(B, { timestamp: 1 }))],
    ['new message without a timestamp', () => setDoc(msg(b, RANDOM_ID), message(B, { timestamp: null }))],
    ['new message read twice by its author', () => setDoc(msg(b, RANDOM_ID), message(B, { readBy: [B, B] }))],
    ['new message with an oversized reaction', () => setDoc(msg(b, RANDOM_ID), message(B, { reactionsByUser: { [B]: 'x'.repeat(65) } }))],
    // Someone else's message.
    ['participant edits another\'s message', () => updateDoc(msg(b, 'mA3'), { text: 'x' })],
    ['participant soft-deletes another\'s message', () => updateDoc(msg(b, 'mA3'), { isDeleted: true, text: '', imageUrl: null })],
    ['participant clears another\'s shared place', () => updateDoc(msg(b, 'mA3'), { place: null })],
    ['participant deletes another\'s message', () => deleteDoc(msg(b, 'mA3'))],
    ['participant edits a system message', () => updateDoc(msg(b, 'sys'), { text: 'x' })],
    ['participant deletes a system message', () => deleteDoc(msg(b, 'sys'))],
    ['participant marks someone else read', () => updateDoc(msg(b, 'mA3'), { readBy: arrayUnion(C) })],
    ['participant unmarks someone else', () => updateDoc(msg(b, 'mA3'), { readBy: arrayRemove(A) })],
    ['participant rewrites readBy', () => updateDoc(msg(b, 'mA3'), { readBy: [B] })],
    // readBy padding: the uid set grows by the caller only, but the list
    // repeats someone, reorders them, or puts the caller first.
    ['participant pads readBy with someone already there', () => updateDoc(msg(b, 'mR'), { readBy: [A, B, A] })],
    ['participant re-adds themselves as a duplicate', () => updateDoc(msg(b, 'mR'), { readBy: [A, B, B] })],
    ['participant reorders readBy', () => updateDoc(msg(b, 'mR'), { readBy: [B, A] })],
    ['participant prepends themselves', () => updateDoc(msg(b, 'mA3'), { readBy: [B, A] })],
    ['participant appends themselves and someone else', () => updateDoc(msg(b, 'mA3'), { readBy: [A, B, C] })],
    // Reaction entries: a string of at most 64 characters.
    ['participant reacts with a long string', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${B}`]: 'x'.repeat(65) })],
    ['participant reacts with a list', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${B}`]: ['👍'] })],
    ['participant reacts with a map', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${B}`]: { big: 'x' } })],
    // Messages aren't audited, so a reader's update carries no audit stamp.
    ['participant reacts and stamps lastModifiedBy', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${B}`]: '👍', lastModifiedBy: B, lastModifiedAt: serverTimestamp() })],
    ['author changes the timestamp', () => updateDoc(msg(a, 'mA3'), { timestamp: serverTimestamp() })],
    ['participant changes someone else\'s reaction', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${A}`]: '💩' })],
    ['participant removes someone else\'s reaction', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${A}`]: deleteField() })],
    ['participant replaces the reactions map', () => updateDoc(msg(b, 'mA3'), { reactionsByUser: { [B]: '👍' } })],
    ['participant reacts and edits the text', () => updateDoc(msg(b, 'mA3'), { [`reactionsByUser.${B}`]: '👍', text: 'x' })],
    ['author changes the sender', () => updateDoc(msg(a, 'mA3'), { senderId: B })],
    // The conversation itself: membership and deletion are not participants' to change.
    ['participant deletes the conversation', () => deleteDoc(doc(b, 'conversations/c1'))],
    ['creator deletes the conversation', () => deleteDoc(doc(a, 'conversations/c1'))],
    ['chat admin deletes the conversation', () => deleteDoc(doc(adm, 'conversations/c1'))],
    ['participant adds a member', () => updateDoc(doc(b, 'conversations/c1'), { members: [A, B, C], ownerIds: [A, B, C] })],
    ['participant removes a member', () => updateDoc(doc(b, 'conversations/c1'), { members: [B], ownerIds: [B] })],
    ['participant changes ownerIds alone', () => updateDoc(doc(b, 'conversations/c1'), { ownerIds: [B, C] })],
    ['participant renames the group', () => updateDoc(doc(b, 'conversations/c1'), { groupName: 'Mine' })],
    ['participant edits memberEmails', () => updateDoc(doc(b, 'conversations/c1'), { memberEmails: ['x@x.ca'] })],
    ['participant turns a chat into a direct chat', () => updateDoc(doc(b, 'conversations/c1'), { isGroupChat: false })],
    ['creator adds a member from the client', () => updateDoc(doc(a, 'conversations/c1'), { members: [A, B, C], ownerIds: [A, B, C] })],
    ['chat admin adds a member from the client', () => updateDoc(doc(adm, 'conversations/c1'), { members: [A, B, ADM], ownerIds: [A, B, ADM] })],
    ['participant sets a directChatKey', () => updateDoc(doc(b, 'conversations/c1'), { directChatKey: 'k2' })],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`chat: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
