'use strict';
/**
 * Portal clients in Messages and Files against the committed rules
 * (plans/business-suite/CLIENT_PORTAL_PLAN.md, Phase C).
 *
 * Messages: conversations are ownerScoped and guestWritable, so a client
 * holding `{g}:chat:guest` reads and posts only in the conversations the
 * server made them a participant of; nothing else of the group, no
 * membership change, no create or delete.
 *
 * Files: a client reads the `client_files` copies whose clientUids names them (never the `files` docs)
 * (clientReaderListField), and never creates or edits one (the server
 * registers uploads). The Storage side of client uploads is in
 * storage.test.js, whose project the Storage emulator reads indexes from.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, orderBy, arrayUnion, serverTimestamp,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g-portal';
// A and B are members; K is an active client holding Messages and Files; K2
// another client; V a visitor guest; X a removed client (no longer in G).
const A = 'pa', B = 'pb', K = 'pk', K2 = 'pk2', V = 'pv', X = 'px';
const email = (u) => `${u}@x.ca`;
const RANDOM_ID = 'AbCdEfGhIjKlMnOpQrSt';
const ACTIVE = { status: 'ACTIVE', roles: [], denied_scopes: [], clearance_level: 0 };
const INDEX = {
  [A]: { ...ACTIVE, groups: [G], guest_groups: [], entitlements: [`${G}:chat`, `${G}:storage`] },
  [B]: { ...ACTIVE, groups: [G], guest_groups: [], entitlements: [`${G}:chat`, `${G}:storage`] },
  [K]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [`${G}:chat:guest`, `${G}:storage:guest`] },
  [K2]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [`${G}:chat:guest`, `${G}:storage:guest`] },
  [V]: { ...ACTIVE, groups: [G], guest_groups: [G], entitlements: [] },
  [X]: { ...ACTIVE, groups: [], guest_groups: [], entitlements: [] },
};
const tenant = (appId, creatorId, ownerIds = [creatorId]) => ({ groupId: G, appId, creatorId, ownerIds });
const conversation = (creatorId, members, extra = {}) => ({
  ...tenant('chat', creatorId, members), members, memberEmails: members.map(email), isGroupChat: true,
  groupName: 'Client', lastMessage: 'hi', lastMessageTimestamp: 1, ...extra,
});
const stored = (sender, extra = {}) => ({
  ...tenant('chat', sender), text: 'hello', senderId: sender, senderEmail: email(sender), imageUrl: null, timestamp: 1,
  isDeleted: false, readBy: [sender], ...extra,
});
const message = (sender, extra = {}) => stored(sender, { timestamp: serverTimestamp(), ...extra });
const file = (creatorId, extra = {}) => ({
  ...tenant('storage', creatorId), userId: creatorId, fileName: 'a.pdf', storagePath: `groups/${G}/apps/storage/files/a.pdf`,
  isPublic: false, sharedWithIds: [], ...extra,
});

test('portal clients in Messages and Files', { timeout: 5 * 60 * 1000 }, async () => {
  const env = await openTestEnv({
    projectId: 'demo-bluejay-portal-apps',
    firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') },
  });
  const upload = (uid, name) => `groups/${G}/apps/storage/client_uploads/${uid}_${name}`;
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'conversations/ck'), conversation(K, [K, A], { clientUid: K }));
    await setDoc(doc(db, 'conversations/ck/messages/mA'), stored(A));
    await setDoc(doc(db, 'conversations/internal'), conversation(A, [A, B]));
    await setDoc(doc(db, 'conversations/internal/messages/m1'), stored(A));
    await setDoc(doc(db, 'conversations/cv'), conversation(A, [A, V]));
    await setDoc(doc(db, 'conversations/cx'), conversation(A, [A, X], { clientUid: X }));
    await setDoc(doc(db, 'files/shared'), file(A, { sharedWithIds: [K], clientUids: [K] }));
    await setDoc(doc(db, 'files/other'), file(A, { sharedWithIds: [K2], clientUids: [K2] }));
    await setDoc(doc(db, 'files/upload'), file(K, { fromClient: true, clientUploaderUid: K, clientUids: [K], storagePath: upload(K, 'x.pdf') }));
    // Clients read the files' client-safe copies (functions/_client_links.js).
    const projection = (clientUids) => ({ groupId: G, appId: 'storage', creatorId: A, clientUids, fileName: 'a.pdf' });
    await setDoc(doc(db, 'client_files/shared'), projection([K]));
    await setDoc(doc(db, 'client_files/other'), projection([K2]));
    await setDoc(doc(db, 'client_files/upload'), projection([K]));
  });
  const fsAs = (uid) => env.authenticatedContext(uid, { email: email(uid) }).firestore();
  const [a, k, v, x] = [A, K, V, X].map(fsAs);
  const msg = (d, conv, id) => doc(d, `conversations/${conv}/messages/${id}`);
  const convs = (d) => collection(d, 'conversations');
  const files = (d) => collection(d, 'files');
  const clientFiles = (d) => collection(d, 'client_files');

  const ok = [
    // Messages.
    ['client lists their conversations', () => getDocs(query(convs(k), where('groupId', '==', G), where('ownerIds', 'array-contains', K), orderBy('lastMessageTimestamp', 'desc')))],
    ['client gets their conversation', () => getDoc(doc(k, 'conversations/ck'))],
    ['client lists its messages', () => getDocs(collection(k, 'conversations/ck/messages'))],
    ['client posts as themselves', () => setDoc(msg(k, 'ck', RANDOM_ID), message(K))],
    ['client bumps lastMessage', () => updateDoc(doc(k, 'conversations/ck'), { lastMessage: 'thanks', lastMessageTimestamp: 2 })],
    ['client marks a message read', () => updateDoc(msg(k, 'ck', 'mA'), { readBy: arrayUnion(K) })],
    ['member reads the client conversation they are in', () => getDoc(doc(a, 'conversations/ck'))],
    // Files.
    ['client gets a file shared with them', () => getDoc(doc(k, 'client_files/shared'))],
    ['client gets their upload\'s copy', () => getDoc(doc(k, 'client_files/upload'))],
    ['client lists their files (queryAsClient)', () => getDocs(query(clientFiles(k), where('groupId', '==', G), where('clientUids', 'array-contains', K)))],
    ['member lists client uploads', () => getDocs(query(files(a), where('groupId', '==', G), where('fromClient', '==', true)))],
  ];
  const deny = [
    // Messages: other conversations, other people, membership, create, delete.
    ['client gets an internal conversation', () => getDoc(doc(k, 'conversations/internal'))],
    ['client lists an internal conversation\'s messages', () => getDocs(collection(k, 'conversations/internal/messages'))],
    ['client lists the group\'s conversations', () => getDocs(query(convs(k), where('groupId', '==', G)))],
    ['client posts in an internal conversation', () => setDoc(msg(k, 'internal', RANDOM_ID), message(K))],
    ['client posts as a member', () => setDoc(msg(k, 'ck', RANDOM_ID), message(K, { senderId: A, senderEmail: email(A) }))],
    ['client adds someone', () => updateDoc(doc(k, 'conversations/ck'), { members: [K, A, B], ownerIds: [K, A, B] })],
    ['client drops the client mark', () => updateDoc(doc(k, 'conversations/ck'), { clientUid: 'nobody' })],
    ['client creates a conversation', () => setDoc(doc(k, `conversations/${RANDOM_ID}`), conversation(K, [K, A]))],
    ['client deletes their conversation', () => deleteDoc(doc(k, 'conversations/ck'))],
    ['client edits a member\'s message', () => updateDoc(msg(k, 'ck', 'mA'), { text: 'x' })],
    ['visitor without Messages reads a conversation naming them', () => getDoc(doc(v, 'conversations/cv'))],
    ['removed client reads their old conversation', () => getDoc(doc(x, 'conversations/cx'))],
    // Files: other clients' files, the group's files, any write.
    ['client gets another client\'s file', () => getDoc(doc(k, 'client_files/other'))],
    ['client gets the file record itself', () => getDoc(doc(k, 'files/shared'))],
    ['client lists the file records', () => getDocs(query(files(k), where('groupId', '==', G), where('clientUids', 'array-contains', K)))],
    ['client writes a client copy', () => setDoc(doc(k, `client_files/${RANDOM_ID}`), { groupId: G, appId: 'storage', creatorId: K, clientUids: [K] })],
    ['client lists the group\'s files', () => getDocs(query(files(k), where('groupId', '==', G)))],
    ['client creates a files doc', () => setDoc(doc(k, `files/${RANDOM_ID}`), file(K))],
    ['client edits their upload\'s doc', () => updateDoc(doc(k, 'files/upload'), { displayName: 'x' })],
    ['client marks themselves on a file', () => updateDoc(doc(k, 'files/other'), { sharedWithIds: [K2, K] })],
    ['member sets clientUploaderUid', () => setDoc(doc(a, `files/${RANDOM_ID}`), file(A, { clientUploaderUid: K }))],
    ['member sets fromClient', () => setDoc(doc(a, `files/${RANDOM_ID}`), file(A, { fromClient: true }))],
    ['member sets clientUids', () => updateDoc(doc(a, 'files/shared'), { clientUids: [K, K2] })],
    ['removed client gets a file once shared', () => getDoc(doc(x, 'files/shared'))],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));

  await releaseTestEnv(env);
  assert.equal(fails.length, 0, fails.join('\n'));
});
