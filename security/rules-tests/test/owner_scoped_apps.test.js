// The personal and shared-by-list apps whose collections are ownerScoped
// (security/collections.json): Notes, Gifts (people app), Workout Tracker,
// Flashcards, Habit Tracker, Whiteboard and Polls. Below the app's :admin
// tier, a member reads and writes only docs they own (creatorId or
// ownerIds), whatever their tier, so a list must filter on ownership
// (ScopedCollection.queryOwned: ownerIds array-contains uid). Sharing puts
// the sharee in ownerIds (a note's sharedWithIds, a board's memberIds, a
// poll's participantIds). Polls also restrict edits to the creator, and a
// participant still votes through the self-keyed votes subcollection, whose
// ballots are selfRead: each participant reads only their own (platform
// admins read all; the app's :admin tier reads none, so an anonymous poll's
// ballots stay private); the results are serverFields on the poll.
const test = require('node:test');
const fs = require('fs');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, orderBy, arrayUnion, arrayRemove,
  serverTimestamp,
} = require('firebase/firestore');
const gen = require('../../generate');

const G = 'g1';
// A owns everything below and shares some of it with B; A and B hold only
// the base scope, as every non-editor member does in an app with
// sharedEditing: false (Whiteboard, Notes). C is a member of the group with
// every app (and :edit, as sharedEditing grants) but owns nothing; ADM holds
// every app's :admin tier.
const A = 'ua', B = 'ub', C = 'uc', ADM = 'uadm';
const APPS = ['notes', 'people', 'workout-tracker', 'flashcards', 'habit-tracker', 'whiteboard', 'polls'];
const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0, groups: [G] };
const INDEX = {
  [A]: { ...ACTIVE, entitlements: APPS.map((a) => `${G}:${a}`) },
  [B]: { ...ACTIVE, entitlements: APPS.map((a) => `${G}:${a}`) },
  [C]: { ...ACTIVE, entitlements: APPS.flatMap((a) => [`${G}:${a}`, `${G}:${a}:edit`]) },
  [ADM]: { ...ACTIVE, entitlements: APPS.flatMap((a) => [`${G}:${a}`, `${G}:${a}:admin`]) },
};
const RANDOM_ID = 'AbCdEfGhIjKlMnOpQrSt';
const tenant = (appId, creatorId = A, ownerIds = [creatorId]) => ({ groupId: G, appId, creatorId, ownerIds });
const owned = (d, c, uid, ...rest) => query(collection(d, c), where('groupId', '==', G), where('ownerIds', 'array-contains', uid), ...rest);
const groupOnly = (d, c, ...rest) => query(collection(d, c), where('groupId', '==', G), ...rest);

test('owner-scoped apps: owners and sharees only', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-owner-scoped', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(INDEX)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'notes/n1'), { ...tenant('notes', A, [A, B]), title: 'Shared', sharedWithIds: [B], lastEdited: 1 });
    await setDoc(doc(db, 'notes/n2'), { ...tenant('notes'), title: 'Private', sharedWithIds: [], lastEdited: 1 });
    await setDoc(doc(db, 'people/p1'), { ...tenant('people'), userId: A, name: 'Ann' });
    await setDoc(doc(db, 'gift_ideas/i1'), { ...tenant('people'), userId: A, personId: 'p1', createdAt: 1 });
    await setDoc(doc(db, 'gift_categories/k1'), { ...tenant('people'), name: 'Books' });
    await setDoc(doc(db, 'workout_exercise_logs/l1'), { ...tenant('workout-tracker'), userId: A, dateKey: '2026-11-12' });
    await setDoc(doc(db, 'flashcard_decks/d1'), { ...tenant('flashcards'), userId: A, title: 'French' });
    await setDoc(doc(db, 'flashcards/c1'), { ...tenant('flashcards'), userId: A, deckId: 'd1' });
    await setDoc(doc(db, `flashcard_study_records/${G}__c1_${A}`), { ...tenant('flashcards'), userId: A, deckId: 'd1', cardId: 'c1' });
    await setDoc(doc(db, 'habits/h1'), { ...tenant('habit-tracker'), name: 'Run', order: 0 });
    await setDoc(doc(db, 'habits/h2'), { ...tenant('habit-tracker'), name: 'Read', order: 1 });
    const board = (members) => ({ ...tenant('whiteboard', A, members), ownerId: A, memberIds: members, name: 'Plan', updatedAt: 1 });
    await setDoc(doc(db, 'whiteboards/w1'), board([A, B]));
    await setDoc(doc(db, 'whiteboards/w2'), board([A]));
    await setDoc(doc(db, 'whiteboards/w3'), board([A, B]));
    await setDoc(doc(db, 'whiteboards/w1/strokes/s1'), { ...tenant('whiteboard'), createdAt: 1 });
    await setDoc(doc(db, 'whiteboards/w1/strokes/s2'), { ...tenant('whiteboard'), createdAt: 1 });
    await setDoc(doc(db, 'whiteboards/w1/text_elements/t1'), { ...tenant('whiteboard'), text: 'Hi', createdAt: 1 });
    const poll = { ...tenant('polls', A, [A, B]), createdBy: A, participantIds: [A, B], title: 'Lunch?', closedAt: null, createdAt: 1 };
    await setDoc(doc(db, 'polls/q1'), poll);
    await setDoc(doc(db, 'polls/q2'), poll);
    await setDoc(doc(db, `polls/q1/votes/${A}`), { ...tenant('polls'), userId: A, choiceId: 'o1', votedAt: 1 });
    await setDoc(doc(db, `polls/q2/votes/${B}`), { ...tenant('polls', B), userId: B, choiceId: 'o2', votedAt: 1 });
  });
  const [a, b, c, adm] = [A, B, C, ADM].map((u) => env.authenticatedContext(u).firestore());
  const vote = (uid) => ({ ...tenant('polls', uid), userId: uid, choiceId: 'o2', votedAt: serverTimestamp() });

  const ok = [
    // Notes: the list is queryOwned; a sharee reads and edits the note.
    ['notes: owner lists own notes (queryOwned)', () => getDocs(owned(a, 'notes', A))],
    ['notes: owner lists by creatorId', () => getDocs(groupOnly(a, 'notes', where('creatorId', '==', A)))],
    ['notes: sharee lists notes shared with them', () => getDocs(owned(b, 'notes', B))],
    ['notes: sharee opens a shared note', () => getDoc(doc(b, 'notes/n1'))],
    ['notes: sharee edits a shared note', () => updateDoc(doc(b, 'notes/n1'), { title: 'Edited', lastEdited: 2 })],
    ['notes: app admin reads a member\'s private note', () => getDoc(doc(adm, 'notes/n2'))],
    ['notes: create shared from the start', () => setDoc(doc(a, `notes/${RANDOM_ID}`), { ...tenant('notes', A, [A, B]), sharedWithIds: [B] })],
    // Gifts: people and gift ideas are the creator's; categories stay shared.
    ['gifts: owner lists people (queryOwned)', () => getDocs(owned(a, 'people', A))],
    ['gifts: owner lists a person\'s gift ideas', () => getDocs(owned(a, 'gift_ideas', A, where('personId', '==', 'p1'), orderBy('createdAt', 'desc')))],
    ['gifts: any member lists the group\'s categories', () => getDocs(groupOnly(c, 'gift_categories', orderBy('name')))],
    // Workout Tracker and Flashcards.
    ['workout: owner lists a day\'s logs', () => getDocs(owned(a, 'workout_exercise_logs', A, where('dateKey', '==', '2026-11-12')))],
    ['flashcards: owner lists decks', () => getDocs(owned(a, 'flashcard_decks', A))],
    ['flashcards: owner lists a deck\'s cards', () => getDocs(owned(a, 'flashcards', A, where('deckId', '==', 'd1')))],
    ['flashcards: owner reads own study record by key', () => getDoc(doc(a, `flashcard_study_records/${G}__c1_${A}`))],
    ['flashcards: missing tagged study record probe', () => getDoc(doc(a, `flashcard_study_records/${G}__c9_${A}`))],
    // Habit Tracker.
    ['habits: owner lists habits', () => getDocs(owned(a, 'habits', A, orderBy('order')))],
    ['habits: owner deletes own habit', () => deleteDoc(doc(a, 'habits/h2'))],
    // Whiteboard: members are owners; they draw; the owner shares, a member leaves.
    ['whiteboard: member lists own and shared boards', () => getDocs(owned(b, 'whiteboards', B))],
    ['whiteboard: member opens a shared board', () => getDoc(doc(b, 'whiteboards/w1'))],
    ['whiteboard: member lists a shared board\'s strokes', () => getDocs(query(collection(b, 'whiteboards/w1/strokes'), orderBy('createdAt')))],
    ['whiteboard: member draws on a shared board', () => setDoc(doc(b, `whiteboards/w1/strokes/${RANDOM_ID}`), { ...tenant('whiteboard', B), createdAt: 2 })],
    // Every member edits the whole board, whoever drew each element.
    ['whiteboard: member moves a stroke someone else drew', () => updateDoc(doc(b, 'whiteboards/w1/strokes/s2'), { createdAt: 3 })],
    ['whiteboard: member erases a stroke someone else drew', () => deleteDoc(doc(b, 'whiteboards/w1/strokes/s2'))],
    ['whiteboard: member edits text someone else wrote', () => updateDoc(doc(b, 'whiteboards/w1/text_elements/t1'), { text: 'Hello' })],
    ['whiteboard: owner shares a board', () => updateDoc(doc(a, 'whiteboards/w2'), { memberIds: arrayUnion(C), ownerIds: arrayUnion(C), updatedAt: 2 })],
    ['whiteboard: member leaves a board', () => updateDoc(doc(b, 'whiteboards/w3'), { memberIds: arrayRemove(B), ownerIds: arrayRemove(B), updatedAt: 2 })],
    // Polls: participants read and vote; only the creator edits.
    ['polls: participant lists polls (queryOwned)', () => getDocs(owned(b, 'polls', B, orderBy('createdAt', 'desc')))],
    ['polls: participant opens a poll', () => getDoc(doc(b, 'polls/q1'))],
    ['polls: participant reads their own missing ballot', () => getDoc(doc(b, `polls/q1/votes/${B}`))],
    ['polls: participant votes', () => setDoc(doc(b, `polls/q1/votes/${B}`), vote(B))],
    ['polls: participant reads their own ballot', () => getDoc(doc(b, `polls/q1/votes/${B}`))],
    ['polls: participant changes their vote', () => updateDoc(doc(b, `polls/q1/votes/${B}`), { choiceId: 'o1', votedAt: serverTimestamp() })],
    ['polls: creator closes the poll', () => updateDoc(doc(a, 'polls/q2'), { closedAt: serverTimestamp() })],
    ['polls: create with the participants as owners', () => setDoc(doc(a, `polls/${RANDOM_ID}`), { ...tenant('polls', A, [A, B]), createdBy: A, participantIds: [A, B], title: 'x', createdAt: 1 })],
  ];
  const deny = [
    ['notes: list without an ownership filter', () => getDocs(groupOnly(c, 'notes'))],
    ['notes: member lists by sharedWithIds', () => getDocs(groupOnly(b, 'notes', where('sharedWithIds', 'array-contains', B)))],
    ['notes: member opens someone else\'s private note', () => getDoc(doc(c, 'notes/n2'))],
    ['notes: sharee opens a note not shared with them', () => getDoc(doc(b, 'notes/n2'))],
    ['notes: :edit member edits someone else\'s note', () => updateDoc(doc(c, 'notes/n1'), { title: 'x' })],
    ['notes: :edit member deletes someone else\'s note', () => deleteDoc(doc(c, 'notes/n2'))],
    ['gifts: people list without an ownership filter', () => getDocs(groupOnly(c, 'people'))],
    ['gifts: people list by the client-written userId', () => getDocs(groupOnly(c, 'people', where('userId', '==', A)))],
    ['gifts: member opens someone else\'s person', () => getDoc(doc(c, 'people/p1'))],
    ['gifts: :edit member edits someone else\'s person', () => updateDoc(doc(c, 'people/p1'), { name: 'x' })],
    ['gifts: gift ideas by personId alone', () => getDocs(groupOnly(c, 'gift_ideas', where('personId', '==', 'p1')))],
    ['workout: logs by the client-written userId', () => getDocs(groupOnly(c, 'workout_exercise_logs', where('userId', '==', A)))],
    ['workout: member opens someone else\'s log', () => getDoc(doc(c, 'workout_exercise_logs/l1'))],
    ['flashcards: cards by deckId alone', () => getDocs(groupOnly(c, 'flashcards', where('deckId', '==', 'd1')))],
    ['flashcards: member reads someone else\'s study record', () => getDoc(doc(c, `flashcard_study_records/${G}__c1_${A}`))],
    ['flashcards: :edit member deletes someone else\'s deck', () => deleteDoc(doc(c, 'flashcard_decks/d1'))],
    ['habits: :edit member updates someone else\'s habit', () => updateDoc(doc(c, 'habits/h1'), { name: 'x' })],
    ['habits: :edit member deletes someone else\'s habit', () => deleteDoc(doc(c, 'habits/h1'))],
    ['habits: member opens someone else\'s habit', () => getDoc(doc(c, 'habits/h1'))],
    ['whiteboard: list by ownerId (not an ownership field)', () => getDocs(groupOnly(a, 'whiteboards', where('ownerId', '==', A)))],
    ['whiteboard: :edit non-member opens a board', () => getDoc(doc(c, 'whiteboards/w1'))],
    ['whiteboard: :edit non-member lists its strokes', () => getDocs(collection(c, 'whiteboards/w1/strokes'))],
    ['whiteboard: :edit non-member draws on it', () => setDoc(doc(c, `whiteboards/w1/strokes/${RANDOM_ID}`), { ...tenant('whiteboard', C), createdAt: 2 })],
    ['whiteboard: :edit non-member deletes it', () => deleteDoc(doc(c, 'whiteboards/w1'))],
    ['whiteboard: :edit non-member erases a stroke', () => deleteDoc(doc(c, 'whiteboards/w1/strokes/s1'))],
    ['polls: list by participantIds', () => getDocs(groupOnly(b, 'polls', where('participantIds', 'array-contains', B)))],
    ['polls: non-participant opens a poll', () => getDoc(doc(c, 'polls/q1'))],
    ['polls: non-participant reads the votes', () => getDocs(collection(c, 'polls/q1/votes'))],
    ['polls: participant lists the ballots', () => getDocs(collection(b, 'polls/q1/votes'))],
    ['polls: participant reads another participant\'s ballot', () => getDoc(doc(b, `polls/q1/votes/${A}`))],
    ['polls: creator reads a participant\'s ballot', () => getDoc(doc(a, `polls/q2/votes/${B}`))],
    ['polls: creator lists the ballots', () => getDocs(collection(a, 'polls/q2/votes'))],
    ['polls: app admin lists a poll\'s ballots', () => getDocs(collection(adm, 'polls/q1/votes'))],
    ['polls: app admin reads a ballot', () => getDoc(doc(adm, `polls/q2/votes/${B}`))],
    ['polls: creator makes a poll anonymous after creating it', () => updateDoc(doc(a, 'polls/q2'), { isAnonymous: true })],
    ['polls: creator writes the results', () => updateDoc(doc(a, 'polls/q2'), { voteCounts: { o1: 9 }, voterCount: 9 })],
    ['polls: creator creates a poll with results', () => setDoc(doc(a, 'polls/AbCdEfGhIjKlMnOpQrSu'), { ...tenant('polls', A, [A, B]), createdBy: A, participantIds: [A, B], title: 'x', voterIds: [B] })],
    ['polls: non-participant votes', () => setDoc(doc(c, `polls/q1/votes/${C}`), vote(C))],
    ['polls: participant closes someone else\'s poll', () => updateDoc(doc(b, 'polls/q1'), { closedAt: serverTimestamp() })],
    ['polls: participant edits the question', () => updateDoc(doc(b, 'polls/q1'), { title: 'Dinner?' })],
    ['polls: participant deletes the poll', () => deleteDoc(doc(b, 'polls/q1'))],
    ['polls: participant overwrites another participant\'s vote', () => setDoc(doc(b, `polls/q1/votes/${A}`), vote(A))],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((err) => fails.push(`ALLOW expected: ${n}: ${String(err.message || err).replace(/\s+/g, ' ').slice(0, 300)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`owner-scoped apps: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
  if (fails.length) throw new Error(fails.join('\n'));
});
