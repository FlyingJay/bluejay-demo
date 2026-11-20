// The app's real query shapes (launcher groups, memberships, directory,
// inbox, settings, Budgie Ting's invoices subcollection, own profile) against
// the committed rules, run one at a time. Written for the stage 1+2 rollout;
// since stage 7 every block here runs the committed rules (there is no other
// variant).
const test = require('node:test');
const fs = require('fs');
const path = require('path');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
const { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs, collectionGroup, orderBy, limit, serverTimestamp, Timestamp } = require('firebase/firestore');

const G = 'g1', U = 'u1';
const IDX = { status: 'ACTIVE', roles: [], groups: [G], guest_groups: [], denied_scopes: [], clearance_level: 0,
  entitlements: [`${G}:notes`, `${G}:budgieting`, `${G}:storage`, `${G}:email-sender`] };

test('stage 1: app query shapes', async () => {
  const env = await openTestEnv({ projectId: 'demo-bluejay-stage1', firestore: { rules: fs.readFileSync(path.join(__dirname, '../../../firestore.rules'), 'utf8') } });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/${U}`), { email: 'u1@bluejay.gg', isBanned: true, roles: [] });
    await setDoc(doc(db, 'users/u2'), { email: 'u2@bluejay.gg' });
    await setDoc(doc(db, 'users/u2/prefs/workout_tracker'), { weightUnit: 'kg' });
    await setDoc(doc(db, `users/${U}/metadata/access_index`), IDX);
    await setDoc(doc(db, `groups/${G}`), { groupId: G, name: 'G', memberIds: [U], adminIds: [] });
    await setDoc(doc(db, `memberships/${G}_${U}`), { groupId: G, userId: U, role: 'member' });
    await setDoc(doc(db, `group_members/${G}__${U}`), { groupId: G, uid: U });
    await setDoc(doc(db, 'notifications/n1'), { groupId: G, appId: 'notes', recipientId: U, isRead: false, title: 't' });
    await setDoc(doc(db, `app_group_settings/${G}__notes`), { groupId: G, appId: 'notes' });
    await setDoc(doc(db, `budgie_ting/${G}__${U}`), { groupId: G, appId: 'budgieting', creatorId: U, ownerIds: [U] });
    await setDoc(doc(db, `budgie_ting/${G}__${U}/invoices/i1`), { groupId: G, appId: 'budgieting', creatorId: U, ownerIds: [U], amount: 1 });
    await setDoc(doc(db, 'storage_usage/s1'), { groupId: G, appId: 'storage', userId: U });
    await setDoc(doc(db, 'email_sender_settings/' + G), { groupId: G, appId: 'email-sender' });
    // Corporate access config: members of its group read it (NAIC Sight's
    // allowed-domain gate); guests, other groups and client writes don't.
    await setDoc(doc(db, `corporate_access_configs/${G}__naic-sight`), { groupId: G, appId: 'app-access', targetAppId: 'naic-sight', allowedDomains: ['bluejay.gg'] });
    await setDoc(doc(db, 'corporate_access_configs/other__naic-sight'), { groupId: 'other', appId: 'app-access', targetAppId: 'naic-sight', allowedDomains: ['x.com'] });
    await setDoc(doc(db, 'users/cag/metadata/access_index'), { ...IDX, entitlements: [`${G}:naic-sight:guest`], guest_groups: [G] });
    // The development queue (server-written): an item of U's, one of u2's, U's queue state.
    await setDoc(doc(db, 'dev_queue_items/bug__b1'), { ownerId: U, groupId: G, active: true, rank: 1, state: 'queued', stateChangedAt: 1 });
    await setDoc(doc(db, 'dev_queue_items/bug__b2'), { ownerId: 'u2', groupId: G, active: true, rank: 2, state: 'queued', stateChangedAt: 1 });
    await setDoc(doc(db, `dev_queue_owners/${U}`), { lastEmptyNudgeAt: 1 });
  });
  const db = env.authenticatedContext(U).firestore();
  const guestDb = env.authenticatedContext('cag').firestore();
  const ok = [
    ['corporate access config of own group (member read)', () => getDoc(doc(db, `corporate_access_configs/${G}__naic-sight`))],
    ['launcher groups list', () => getDocs(query(collection(db, 'groups'), where('memberIds', 'array-contains', U)))],
    ['own group get', () => getDoc(doc(db, `groups/${G}`))],
    ['own access index', () => getDoc(doc(db, `users/${U}/metadata/access_index`))],
    ['own user doc', () => getDoc(doc(db, `users/${U}`))],
    ['memberships by userId', () => getDocs(query(collection(db, 'memberships'), where('userId', '==', U)))],
    ['memberships by group', () => getDocs(query(collection(db, 'memberships'), where('groupId', '==', G)))],
    ['group_members by group', () => getDocs(query(collection(db, 'group_members'), where('groupId', '==', G)))],
    ['inbox', () => getDocs(query(collection(db, 'notifications'), where('recipientId', '==', U)))],
    ['inbox unread', () => getDocs(query(collection(db, 'notifications'), where('recipientId', '==', U), where('isRead', '==', false)))],
    ['mark read', () => updateDoc(doc(db, 'notifications/n1'), { isRead: true })],
    ['app group settings get', () => getDoc(doc(db, `app_group_settings/${G}__notes`))],
    ['budgie invoices subcollection list', () => getDocs(collection(db, `budgie_ting/${G}__${U}/invoices`))],
    ['budgie invoice create', () => setDoc(doc(db, `budgie_ting/${G}__${U}/invoices/i2`), { groupId: G, appId: 'budgieting', creatorId: U, ownerIds: [U], amount: 2 })],
    ['storage usage list', () => getDocs(query(collection(db, 'storage_usage'), where('groupId', '==', G), where('userId', '==', U)))],
    ['email sender settings get', () => getDoc(doc(db, 'email_sender_settings/' + G))],
    ['update own lastActive', () => setDoc(doc(db, `users/${U}`), { lastActive: 1 }, { merge: true })],
    ['notification settings on own doc', () => setDoc(doc(db, `users/${U}`), { notificationSettings: { push: true } }, { merge: true })],
    ['admin-free: own calendar settings', () => setDoc(doc(db, `calendar_user_settings/${U}`), { weekStart: 1 })],
    // users/{uid}/prefs (kind personal's subcollections): Workout Tracker's weight unit.
    ['own prefs write (merge set)', () => setDoc(doc(db, `users/${U}/prefs/workout_tracker`), { weightUnit: 'lbs' }, { merge: true })],
    ['own prefs read', () => getDoc(doc(db, `users/${U}/prefs/workout_tracker`))],
    // Development queue screen (PHASE_2_DESIGN.md 5.1): the chip / Now / Up next, Shipped, one item.
    ['dev queue: own active items by rank', () => getDocs(query(collection(db, 'dev_queue_items'), where('ownerId', '==', U), where('active', '==', true), orderBy('rank')))],
    ['dev queue: own shipped items', () => getDocs(query(collection(db, 'dev_queue_items'), where('ownerId', '==', U), where('active', '==', false), orderBy('stateChangedAt', 'desc'), limit(30)))],
    ['dev queue: own item get', () => getDoc(doc(db, 'dev_queue_items/bug__b1'))],
  ];
  const deny = [
    ['corporate access config of another group', () => getDoc(doc(db, 'corporate_access_configs/other__naic-sight'))],
    ['corporate access config read by a guest', () => getDoc(doc(guestDb, `corporate_access_configs/${G}__naic-sight`))],
    ['corporate access config written by a member', () => updateDoc(doc(db, `corporate_access_configs/${G}__naic-sight`), { allowedDomains: ['evil.com'] })],
    ['read another user doc', () => getDoc(doc(db, 'users/u2'))],
    ['read another user\'s prefs', () => getDoc(doc(db, 'users/u2/prefs/workout_tracker'))],
    ['write another user\'s prefs', () => setDoc(doc(db, 'users/u2/prefs/workout_tracker'), { weightUnit: 'lbs' })],
    ['set roles on own doc', () => setDoc(doc(db, `users/${U}`), { roles: ['admin'] }, { merge: true })],
    ['clear isBanned on own doc', () => updateDoc(doc(db, `users/${U}`), { isBanned: false })],
    ['write another user calendar settings', () => setDoc(doc(db, 'calendar_user_settings/u2'), { weekStart: 1 })],
    ['self-promote membership', () => updateDoc(doc(db, `memberships/${G}_${U}`), { role: 'owner' })],
    ['add self to group', () => updateDoc(doc(db, `groups/${G}`), { adminIds: [U] })],
    ['forge notification', () => setDoc(doc(db, 'notifications/n9'), { groupId: G, appId: 'notes', recipientId: 'u2', title: 'x' })],
    ['write own access index', () => setDoc(doc(db, `users/${U}/metadata/access_index`), { roles: ['admin'] })],
    ['dev queue: another user\'s item', () => getDoc(doc(db, 'dev_queue_items/bug__b2'))],
    ['dev queue: a group\'s items (managed list is server-side)', () => getDocs(query(collection(db, 'dev_queue_items'), where('groupId', '==', G), where('active', '==', true)))],
    ['dev queue: reorder by writing rank', () => updateDoc(doc(db, 'dev_queue_items/bug__b1'), { rank: 0 })],
    ['dev queue: own queue state read', () => getDoc(doc(db, `dev_queue_owners/${U}`))],
    ['dev queue: own queue state write', () => setDoc(doc(db, `dev_queue_owners/${U}`), { lastEmptyNudgeAt: 0 })],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  // Signed out: every read is refused
  // (production treats the rule's evaluation error as a denial; the app
  // looks invitations up through lookupInvitation since T7).
  await env.withSecurityRulesDisabled(async (ctx) => setDoc(doc(ctx.firestore(), 'invitations/i1'), { groupId: G, email: 'x@bluejay.gg', status: 'pending' }));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'invitations/i1'))).catch(() => fails.push('DENY expected: signed-out invitation read'));
  await releaseTestEnv(env);
  console.log(`${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`); fails.forEach((f) => console.log("FAILCASE " + f));
  if (fails.length) throw new Error(fails.join('\n'));
});

// Stage 3 lives in its own block (its own personas).
{
  // Stage 3 (tenant data): the app's real query and write shapes, run one at a
  // time against the committed rules. One case per client pattern the stage-3 readiness change
  // fixed, with the pre-fix shape as a deny where it matters, so a client
  // regression (a raw query losing its groupId filter, Sell tagging Shop data
  // with its own app id) shows up here before a rollout does.
  const test = require('node:test');
  const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const {
    doc, getDoc, setDoc, updateDoc, deleteDoc, addDoc, collection, collectionGroup, query, where, orderBy, getDocs, writeBatch,
    increment, serverTimestamp,
  } = require('firebase/firestore');
  const gen = require('../../generate');

  const G = 'g1', U = 'u1', OTHER = 'u2';
  const RANDOM_ID = 'AbCdEfGhIjKlMnOpQrSt'; // a 20-char auto id, as tenantIdOk accepts
  const IDX = {
    status: 'ACTIVE', roles: [], groups: [G], guest_groups: [], denied_scopes: [], clearance_level: 0,
    // A Sell seller in a group with Shop and Sell installed (shop has
    // sharedEditing unset, so every member gets :edit), and a Language Learner.
    entitlements: [`${G}:sell`, `${G}:sell:edit`, `${G}:shop`, `${G}:shop:edit`, `${G}:language-learner`,
      `${G}:ai-chat`, `${G}:people`, `${G}:people:edit`, `${G}:rented-dwelling`, `${G}:chat`, `${G}:chat:edit`],
  };
  // Other personas: a Policy Editor staff member, a Bordereau Report reader
  // (with the read-only per-product fan-out computeEntitlements grants), and
  // an ACTIVE platform admin.
  const STAFF = 'staff', BDX = 'bdx', ADMIN = 'admin', CPM = 'cpm';
  // Usage Meter: a guest of G, and a Usage Meter admin of G (U holds no
  // usage-meter entitlement, like every ordinary member).
  const GUEST = 'guest', METER = 'meter';
  const DAY = '2026-11-05';
  // UsageMeter.buildDocData (packages/shared_services/lib/usage_meter.dart).
  const usageDoc = (uid, groupId = G) => ({
    date: DAY, groupId, uid, appId: 'usage-meter', creatorId: uid, ownerIds: [uid],
    apps: { notes: { opens: increment(1), activeSec: increment(12.5) } }, updatedAt: serverTimestamp(),
  });
  const index = (entitlements, roles = []) => ({ ...IDX, roles, entitlements });
  // A base-tier Chat member and a base-tier Cookbook member.
  const COOK = 'cook', COOK_EMAIL = 'cook@x.ca';
  const PRODUCTS = ['commercial-property', 'course-of-construction', 'rented-dwelling'];
  const tenant = (appId, creatorId = U) => ({ groupId: G, appId, creatorId, ownerIds: [creatorId] });

  test('stage 3: app query shapes (tenant collections)', async () => {
    const env = await openTestEnv({
      projectId: 'demo-bluejay-stage3',
      firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') },
    });
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `users/${U}/metadata/access_index`), IDX);
      await setDoc(doc(db, `users/${STAFF}/metadata/access_index`), index([`${G}:policy-editor`, `${G}:policy-editor:edit`]));
      await setDoc(doc(db, `users/${BDX}/metadata/access_index`),
        index([`${G}:bordereau-report`, ...PRODUCTS.map((a) => `${G}:${a}:collection:insurance_applications`)]));
      await setDoc(doc(db, `users/${ADMIN}/metadata/access_index`), index([], ['admin']));
      await setDoc(doc(db, `users/${GUEST}/metadata/access_index`), { ...index([`${G}:notes:guest`]), guest_groups: [G] });
      await setDoc(doc(db, `users/${METER}/metadata/access_index`), index([`${G}:usage-meter`, `${G}:usage-meter:admin`]));
      const stored = (uid) => ({ date: DAY, groupId: G, uid, appId: 'usage-meter', creatorId: uid, ownerIds: [uid], apps: { notes: { opens: 1 } } });
      await setDoc(doc(db, `usage_daily/${DAY}_${G}_${U}`), stored(U));
      await setDoc(doc(db, `usage_daily/${DAY}_${G}_${OTHER}`), stored(OTHER));
      await setDoc(doc(db, 'insurance_applications/p1'), { ...tenant('rented-dwelling', OTHER), status: 'draft' });
      await setDoc(doc(db, 'insurance_applications/p2'), { ...tenant('course-of-construction', OTHER), status: 'draft' });
      // A Commercial Property member, and an archived email about p1 (server-written).
      await setDoc(doc(db, `users/${CPM}/metadata/access_index`), index([`${G}:commercial-property`]));
      await setDoc(doc(db, 'sent_emails/e1'), { groupId: G, appId: 'commercial-property', recordId: 'p1', to: ['p@x.ca'], subject: 'Quote' });
      await setDoc(doc(db, 'ai_chat_conversations/c1'), { ...tenant('ai-chat'), title: 'mine', updatedAt: 1 });
      await setDoc(doc(db, 'ai_chat_conversations/c1/messages/m1'), { ...tenant('ai-chat'), text: 'hi', createdAt: 1 });
      await setDoc(doc(db, 'ai_chat_conversations/c2'), { ...tenant('ai-chat', OTHER), title: 'theirs', updatedAt: 1 });
      await setDoc(doc(db, 'people/p1'), { ...tenant('people'), name: 'Ann' });
      await setDoc(doc(db, 'user_payment_methods/pm_1'), { userId: U, isDefault: false, last4: '4242' });
      await setDoc(doc(db, 'domain_verifications/dv1'), { groupId: 'g9', appId: 'domain-verification', domain: 'x.com' });
      await setDoc(doc(db, 'billing_disputes/e1'), { groupId: G, userId: U, status: 'open' });
      // Shop data a buyer created; categories created by Sell before the fix
      // still carry appId 'sell' (shop_categories is single-app 'shop' now, so
      // the scope comes from the table, not the legacy appId).
      await setDoc(doc(db, 'shop_categories/c1'), { ...tenant('sell'), name: 'Chairs' });
      await setDoc(doc(db, 'shop_shipping_sizes/s1'), { ...tenant('shop'), name: 'Small', price: 5 });
      await setDoc(doc(db, 'shop_product_requests/r1'), { ...tenant('shop', OTHER), userId: OTHER, status: 'pending' });
      await setDoc(doc(db, 'shop_product_requests/r1/messages/m1'), { ...tenant('shop', OTHER), text: 'hi' });
      // A guest's paid storefront request (server-written), sold by U.
      await setDoc(doc(db, 'shop_product_requests/gr1'), { groupId: G, appId: 'shop', creatorId: 'anon1', ownerIds: ['anon1', U],
        ownerId: U, userId: 'anon1', status: 'pending', guest: true, contact: { name: 'Sam', email: 's@x.ca' },
        paymentStatus: 'paid', totalCents: 30150, amountPaidCents: 30150 });
      await setDoc(doc(db, `shop_sellers/${G}__${U}`), { ...tenant('shop'), ownerId: U, shopName: 'Mine' });
      // Sell's direct sales pages: U's page; submissions and stats are
      // server-written with ownerIds = the page's owner (ownerScoped).
      await setDoc(doc(db, 'shop_sales_pages/sp1'), { ...tenant('shop'), ownerId: U, title: 'Class', status: 'published' });
      const submission = (owner) => ({ groupId: G, appId: 'shop', ownerIds: [owner], pageId: 'sp1', payerUid: 'anon1',
        contact: { name: 'Sam', email: 's@x.ca' }, status: 'confirmed', paymentStatus: 'paid', totalCents: 500 });
      await setDoc(doc(db, 'shop_sales_submissions/ss1'), submission(U));
      await setDoc(doc(db, 'shop_sales_submissions/ss2'), submission(OTHER));
      await setDoc(doc(db, 'shop_sales_page_stats/sp1'), { groupId: G, appId: 'shop', ownerIds: [U], pageId: 'sp1', views: 3 });
      await setDoc(doc(db, 'language_learner_messages/m1'), { ...tenant('language-learner'), conversationId: 'c1', createdAt: 1 });
      // Cookbook runs with sharedEditing false: COOK holds only the base
      // scope. (Chat's cases are in chat.test.js.)
      await setDoc(doc(db, `users/${COOK}/metadata/access_index`), index([`${G}:cookbook`]));
      await setDoc(doc(db, 'recipes/r1'), { ...tenant('cookbook', OTHER), title: 'Lemon bars' });
      await setDoc(doc(db, 'recipes/r1/photos/p1'), { ...tenant('cookbook', OTHER), imageUrl: 'x' });
      const photoComment = (by, email) => ({ ...tenant('cookbook', by), photoId: 'p1', text: 'Yum', commenterId: by, commenterEmail: email, createdAt: 1 });
      await setDoc(doc(db, 'recipes/r1/photo_comments/pc1'), photoComment(OTHER, 'u2@x.ca'));
      await setDoc(doc(db, 'recipes/r1/photo_comments/pc2'), photoComment(COOK, COOK_EMAIL));
    });
    const db = env.authenticatedContext(U).firestore();
    const ok = [
      // Sell: shop_* through ScopedCollection(appId: 'shop').
      ['sell categories list (shopCategories.query)', () => getDocs(query(collection(db, 'shop_categories'), where('groupId', '==', G), orderBy('name')))],
      ['sell category create tagged shop', () => setDoc(doc(db, `shop_categories/${RANDOM_ID}`), { ...tenant('shop'), name: 'Tables' })],
      ['sell legacy sell-tagged category rename', () => updateDoc(doc(db, 'shop_categories/c1'), { name: 'Seating' })],
      ['sell shipping sizes list (shopShippingSizes.query)', () => getDocs(query(collection(db, 'shop_shipping_sizes'), where('groupId', '==', G), orderBy('name')))],
      ['sell shipping size create (shopShippingSizes.add)', () => setDoc(doc(db, `shop_shipping_sizes/${RANDOM_ID}`), { ...tenant('shop'), name: 'Large', price: 9 })],
      ['sell shipping size update', () => updateDoc(doc(db, 'shop_shipping_sizes/s1'), { price: 6 })],
      ['sell request get', () => getDoc(doc(db, 'shop_product_requests/r1'))],
      ['sell request status update (buyer-created)', () => updateDoc(doc(db, 'shop_product_requests/r1'), { status: 'approved' })],
      ['sell batch links requests to an order', () => { const b = writeBatch(db); b.update(doc(db, 'shop_product_requests/r1'), { orderId: 'o1' }); return b.commit(); }],
      ['sell requests by status (shopProductRequests.query)', () => getDocs(query(collection(db, 'shop_product_requests'), where('groupId', '==', G), where('status', '==', 'pending')))],
      ['shop chat messages list (sub)', () => getDocs(collection(db, 'shop_product_requests/r1/messages'))],
      ['shop chat message create (sub, parent tenant)', () => setDoc(doc(db, `shop_product_requests/r1/messages/${RANDOM_ID}`), { ...tenant('shop'), text: 'hello' })],
      ['sell shipping size delete', () => deleteDoc(doc(db, 'shop_shipping_sizes/s1'))],
      // Shop's guest storefront: the seller's own switch, and working a guest's paid request.
      ['seller turns on Sell to guests', () => updateDoc(doc(db, `shop_sellers/${G}__${U}`), { guestCheckout: true })],
      ["seller moves a guest's request along", () => updateDoc(doc(db, 'shop_product_requests/gr1'), { status: 'in_progress' })],
      ["seller links a guest's request to an order", () => updateDoc(doc(db, 'shop_product_requests/gr1'), { orderId: 'o9' })],
      ['member request without payment fields', () => setDoc(doc(db, 'shop_product_requests/AbCdEfGhIjKlMnOpQrSa'), { ...tenant('shop'), userId: U, status: 'pending', priceTotal: 10 })],
      // Sell's direct sales (SalesService).
      ['sales pages list (ownerId ==)', () => getDocs(query(collection(db, 'shop_sales_pages'), where('groupId', '==', G), where('ownerId', '==', U)))],
      ['sales page create', () => setDoc(doc(db, `shop_sales_pages/${RANDOM_ID}`), { ...tenant('shop'), ownerId: U, title: 'New', status: 'draft' })],
      ['sales page update', () => updateDoc(doc(db, 'shop_sales_pages/sp1'), { status: 'closed' })],
      ['sales submissions list (queryOwned + pageId)', () => getDocs(query(collection(db, 'shop_sales_submissions'), where('groupId', '==', G), where('ownerIds', 'array-contains', U), where('pageId', '==', 'sp1')))],
      ['sales submission status and notes', () => updateDoc(doc(db, 'shop_sales_submissions/ss1'), { status: 'completed', sellerNotes: 'Done' })],
      ['sales stats list (queryOwned + pageId)', () => getDocs(query(collection(db, 'shop_sales_page_stats'), where('groupId', '==', G), where('ownerIds', 'array-contains', U), where('pageId', '==', 'sp1')))],
      // Language Learner: ownerScoped, so the messages query names the creator.
      // AI Chat: flattened, ownerScoped conversations; messages via sub().
      ['ai chat own conversations', () => getDocs(query(collection(db, 'ai_chat_conversations'), where('groupId', '==', G), where('creatorId', '==', U), orderBy('updatedAt', 'desc')))],
      ['ai chat conversation create', () => setDoc(doc(db, 'ai_chat_conversations/0b8f2a3c-1d4e-4f5a-8b6c-7d8e9f0a1b2c'), { ...tenant('ai-chat'), title: 'New' })],
      ['ai chat messages (sub)', () => getDocs(query(collection(db, 'ai_chat_conversations/c1/messages'), orderBy('createdAt')))],
      // Gifts (people app): ownerScoped, so the list is queryOwned.
      ['gifts people list (queryOwned)', () => getDocs(query(collection(db, 'people'), where('groupId', '==', G), where('ownerIds', 'array-contains', U)))],
      // Natural keys through docForKey: tagged ids.
      ['property cache tagged create', () => setDoc(doc(db, `property_data_cache/${G}__rented-dwelling_1_main_st`), { ...tenant('rented-dwelling'), data: {}, lastModifiedBy: U, lastModifiedAt: serverTimestamp() })],
      ['property cache missing tagged probe', () => getDoc(doc(db, `property_data_cache/${G}__rented-dwelling_2_main_st`))],
      // Billing: the disputing user reads their thread; saved cards are server-written.
      ['own dispute thread', () => getDoc(doc(db, 'billing_disputes/e1'))],
      ['own payment methods', () => getDocs(query(collection(db, 'user_payment_methods'), where('userId', '==', U)))],
      ['flip own default card', () => updateDoc(doc(db, 'user_payment_methods/pm_1'), { isDefault: true })],
      ['language learner messages by conversation (creatorId ==)', () => getDocs(query(collection(db, 'language_learner_messages'), where('groupId', '==', G), where('creatorId', '==', U), where('conversationId', '==', 'c1'), orderBy('createdAt')))],
    ];
    const deny = [
      ['raw sell categories list (no groupId)', () => getDocs(query(collection(db, 'shop_categories'), orderBy('name')))],
      ['sell category create tagged sell', () => setDoc(doc(db, 'shop_categories/ZyXwVuTsRqPoNmLkJiHg'), { ...tenant('sell'), name: 'Beds' })],
      ['raw shipping size add (no tenant fields)', () => addDoc(collection(db, 'shop_shipping_sizes'), { name: 'Huge', price: 20 })],
      ['raw shipping sizes list (no groupId)', () => getDocs(query(collection(db, 'shop_shipping_sizes'), orderBy('name')))],
      ['raw requests by status (no groupId)', () => getDocs(query(collection(db, 'shop_product_requests'), where('status', '==', 'pending')))],
      ['member request claiming it was paid', () => setDoc(doc(db, 'shop_product_requests/AbCdEfGhIjKlMnOpQrSb'), { ...tenant('shop'), userId: U, status: 'pending', paymentStatus: 'paid' })],
      ['member request posing as a guest', () => setDoc(doc(db, 'shop_product_requests/AbCdEfGhIjKlMnOpQrSc'), { ...tenant('shop'), userId: U, status: 'pending', guest: true })],
      ["seller marks a guest's request refunded", () => updateDoc(doc(db, 'shop_product_requests/gr1'), { paymentStatus: 'refunded' })],
      ["seller edits a guest's contact", () => updateDoc(doc(db, 'shop_product_requests/gr1'), { contact: { name: 'X' } })],
      ['seller changes what a guest paid', () => updateDoc(doc(db, 'shop_product_requests/gr1'), { totalCents: 1 })],
      ["another seller's switch", () => setDoc(doc(db, `shop_sellers/${G}__${OTHER}`), { ...tenant('shop', OTHER), ownerId: OTHER, guestCheckout: true })],
      ['client creates a sales submission', () => setDoc(doc(db, `shop_sales_submissions/${RANDOM_ID}`), { ...tenant('shop'), pageId: 'sp1', status: 'confirmed' })],
      ['seller marks a submission paid', () => updateDoc(doc(db, 'shop_sales_submissions/ss1'), { paymentStatus: 'refunded' })],
      ["seller rewrites the buyer's contact", () => updateDoc(doc(db, 'shop_sales_submissions/ss1'), { contact: { name: 'X' } })],
      ['seller deletes a submission', () => deleteDoc(doc(db, 'shop_sales_submissions/ss1'))],
      ["another seller's submission", () => getDoc(doc(db, 'shop_sales_submissions/ss2'))],
      ['sales submissions without an ownership filter', () => getDocs(query(collection(db, 'shop_sales_submissions'), where('groupId', '==', G)))],
      ['client writes sales stats', () => updateDoc(doc(db, 'shop_sales_page_stats/sp1'), { views: 9999 })],
      ['ai chat conversations without creatorId', () => getDocs(query(collection(db, 'ai_chat_conversations'), where('groupId', '==', G)))],
      ['ai chat legacy nested path', () => getDocs(collection(db, `ai_chat_conversations/${U}/conversations`))],
      ['raw people list (no groupId)', () => getDocs(collection(db, 'people'))],
      ['people list without an ownership filter', () => getDocs(query(collection(db, 'people'), where('groupId', '==', G)))],
      ['property cache untagged create', () => setDoc(doc(db, 'property_data_cache/1_main_st'), { ...tenant('rented-dwelling'), data: {}, lastModifiedBy: U, lastModifiedAt: serverTimestamp() })],
      // Chat conversations are created by the chatStartConversation callable only.
      ['direct chat tagged create', () => setDoc(doc(db, `conversations/${G}__${U}_${OTHER}`), { ...tenant('chat'), participants: [U, OTHER] })],
      ['direct chat untagged create', () => setDoc(doc(db, `conversations/${U}_${OTHER}`), { ...tenant('chat'), participants: [U, OTHER] })],
      ['client creates a payment method', () => setDoc(doc(db, 'user_payment_methods/pm_9'), { userId: U, isDefault: true, creatorId: U })],
      ['language learner messages without creatorId', () => getDocs(query(collection(db, 'language_learner_messages'), where('groupId', '==', G), where('conversationId', '==', 'c1')))],
    ];
    // Cookbook: photo comments one level under the recipe (photo_comments,
    // authorField commenterId); nothing two levels down is reachable.
    const cook = env.authenticatedContext(COOK, { email: COOK_EMAIL }).firestore();
    const myPhotoComment = { ...tenant('cookbook', COOK), photoId: 'p1', text: 'Nice', commenterId: COOK, commenterEmail: COOK_EMAIL, createdAt: 1 };
    ok.push(
      ['cookbook: member lists a photo\'s comments', () => getDocs(query(collection(cook, 'recipes/r1/photo_comments'), where('photoId', '==', 'p1')))],
      ['cookbook: member comments on another member\'s photo', () => setDoc(doc(cook, `recipes/r1/photo_comments/${RANDOM_ID}`), myPhotoComment)],
      ['cookbook: author edits own photo comment', () => updateDoc(doc(cook, 'recipes/r1/photo_comments/pc2'), { text: 'Edited' })],
      ['cookbook: author deletes own photo comment', () => deleteDoc(doc(cook, 'recipes/r1/photo_comments/pc2'))],
      ['cookbook: member comments on another member\'s recipe (authorId)', () => setDoc(doc(cook, `recipes/r1/comments/${RANDOM_ID}`), { ...tenant('cookbook', COOK), authorId: COOK, text: 'Tasty', commenterId: COOK, createdAt: 1 })],
    );
    deny.push(
      ['cookbook: photo comment naming someone else', () => setDoc(doc(cook, 'recipes/r1/photo_comments/AbCdEfGhIjKlMnOpQrSx'), { ...myPhotoComment, commenterId: OTHER })],
      ['cookbook: photo comment with someone else\'s email', () => setDoc(doc(cook, 'recipes/r1/photo_comments/AbCdEfGhIjKlMnOpQrSy'), { ...myPhotoComment, commenterEmail: 'u2@x.ca' })],
      ['cookbook: member deletes another\'s photo comment', () => deleteDoc(doc(cook, 'recipes/r1/photo_comments/pc1'))],
      ['cookbook: member edits another\'s photo comment', () => updateDoc(doc(cook, 'recipes/r1/photo_comments/pc1'), { text: 'x' })],
      ['cookbook: comment two subcollection levels down', () => setDoc(doc(cook, 'recipes/r1/photos/p1/comments/c1'), myPhotoComment)],
      ['cookbook: read two subcollection levels down', () => getDocs(collection(cook, 'recipes/r1/photos/p1/comments'))],
      ['cookbook: recipe comment without authorId on another\'s recipe', () => setDoc(doc(cook, 'recipes/r1/comments/AbCdEfGhIjKlMnOpQrSz'), { ...tenant('cookbook', COOK), text: 'Tasty', commenterId: COOK, createdAt: 1 })],
    );
    // Usage Meter counters (memberWrite): every member's client merges its own
    // {date}_{groupId}_{uid} doc, without the usage-meter app.
    const usage = (d, id) => doc(d, `usage_daily/${id}`);
    const guest = env.authenticatedContext(GUEST).firestore();
    const meter = env.authenticatedContext(METER).firestore();
    const merge = { merge: true };
    ok.push(
      ['usage: member creates own counter (no usage-meter)', () => setDoc(usage(db, `2026-11-06_${G}_${U}`), { ...usageDoc(U), date: '2026-11-06' }, merge)],
      ['usage: member increments own counter', () => setDoc(usage(db, `${DAY}_${G}_${U}`), usageDoc(U), merge)],
      ['usage: member reads own counter (readerField)', () => getDoc(usage(db, `${DAY}_${G}_${U}`))],
      ['usage: usage-meter admin reads a member\'s counter', () => getDoc(usage(meter, `${DAY}_${G}_${OTHER}`))],
      ['usage: usage-meter admin lists the group\'s counters', () => getDocs(query(collection(meter, 'usage_daily'), where('groupId', '==', G), where('date', '==', DAY)))],
    );
    deny.push(
      ['usage: member writes someone else\'s counter', () => setDoc(usage(db, `${DAY}_${G}_${OTHER}`), usageDoc(OTHER), merge)],
      ['usage: member creates a counter in another\'s name', () => setDoc(usage(db, `2026-11-06_${G}_${OTHER}`), { ...usageDoc(U), uid: OTHER }, merge)],
      ['usage: member attributes own id to another uid', () => setDoc(usage(db, `2026-11-07_${G}_${U}`), { ...usageDoc(U), uid: OTHER }, merge)],
      ['usage: member writes in another group', () => setDoc(usage(db, `${DAY}_g2_${U}`), usageDoc(U, 'g2'), merge)],
      ['usage: id names another group than the doc', () => setDoc(usage(db, `2026-11-08_g2_${U}`), usageDoc(U), merge)],
      ['usage: member forges a server shard', () => setDoc(usage(db, `${DAY}_${G}_${U}_srv0`), usageDoc(U), merge)],
      ['usage: guest creates own counter (D1)', () => setDoc(usage(guest, `${DAY}_${G}_${GUEST}`), usageDoc(GUEST), merge)],
      ['usage: member reads someone else\'s counter', () => getDoc(usage(db, `${DAY}_${G}_${OTHER}`))],
      ['usage: member lists the group\'s counters', () => getDocs(query(collection(db, 'usage_daily'), where('groupId', '==', G)))],
      ['usage: member deletes own counter', () => deleteDoc(usage(db, `${DAY}_${G}_${U}`))],
      ['usage: member moves own counter to another day', () => updateDoc(usage(db, `${DAY}_${G}_${U}`), { date: '2026-01-01' })],
    );
    // Staff tools on insurance_applications (multi-app, staffApps policy-editor).
    const staff = env.authenticatedContext(STAFF).firestore();
    const bdx = env.authenticatedContext(BDX).firestore();
    const admin = env.authenticatedContext(ADMIN).firestore();
    const cpm = env.authenticatedContext(CPM).firestore();
    const applications = (d) => collection(d, 'insurance_applications');
    ok.push(
      ['policy editor staff list (groupId only)', () => getDocs(query(applications(staff), where('groupId', '==', G)))],
      ...PRODUCTS.map((a) => [`bordereau list per product (${a})`, () => getDocs(query(applications(bdx), where('groupId', '==', G), where('appId', '==', a)))]),
      ['bordereau transactions collection group', () => getDocs(query(collectionGroup(bdx, 'transactions'), where('groupId', '==', G)))],
      ['platform admin reads a domain verification in another group', () => getDoc(doc(admin, 'domain_verifications/dv1'))],
      // Sent-email history: the app's members (ScopedCollection query) and its staff app.
      ['app member lists a record\'s sent emails', () => getDocs(query(collection(cpm, 'sent_emails'), where('groupId', '==', G), where('appId', '==', 'commercial-property'), where('recordId', '==', 'p1')))],
      ['policy editor staff lists a record\'s sent emails (groupId only)', () => getDocs(query(collection(staff, 'sent_emails'), where('groupId', '==', G), where('recordId', '==', 'p1')))],
      ['policy editor staff reads a sent email', () => getDoc(doc(staff, 'sent_emails/e1'))],
    );
    deny.push(
      ['app member forges a sent email', () => setDoc(doc(cpm, 'sent_emails/e2'), { groupId: G, appId: 'commercial-property', recordId: 'p1', creatorId: CPM, ownerIds: [CPM] })],
      ['app member edits a sent email', () => updateDoc(doc(cpm, 'sent_emails/e1'), { to: ['someone@else.ca'] })],
      ['staff deletes a sent email', () => deleteDoc(doc(staff, 'sent_emails/e1'))],
      ['member without the app lists its sent emails', () => getDocs(query(collection(db, 'sent_emails'), where('groupId', '==', G), where('appId', '==', 'commercial-property'), where('recordId', '==', 'p1')))],
    );
    deny.push(
      ['bordereau list without product (old shape)', () => getDocs(query(applications(bdx), where('groupId', '==', G)))],
      ['member creates a domain verification', () => setDoc(doc(db, 'domain_verifications/AbCdEfGhIjKlMnOpQrSv'), { ...tenant('domain-verification') })],
    );
    const fails = [];
    for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
    for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
    await releaseTestEnv(env);
    console.log(`${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
    if (fails.length) throw new Error(fails.join('\n'));
  });
}

// Stage 4 (rules plan T14): the admin and developer tools, and the Improve
// Apps / App Maker flows, against the committed rules. Platform
// admins read everything but write only adminWritable collections (plus
// comments where adminComments); developers write developerWritable ones;
// stewards read and comment on change requests about the apps they steward.
// Improve Apps is Regulated: members hold the base scope (sharedEditing
// false), vote through their own votes/{uid} doc, stamp every write for the
// audit trail and never delete a ticket.
test('stage 4: admin tools and change-request flows', async () => {
  const gen = require('../../generate');
  const env = await openTestEnv({ projectId: 'demo-bluejay-stage4', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  const ACTIVE = { status: 'ACTIVE', guest_groups: [], denied_scopes: [], clearance_level: 0 };
  const index = {
    adm: { ...ACTIVE, roles: ['admin'], groups: ['ga'], entitlements: ['ga:improve-apps', 'ga:improve-apps:edit'] },
    dev: { ...ACTIVE, roles: ['developer'], groups: ['gd'], entitlements: [] },
    u1: { ...ACTIVE, roles: [], groups: ['g1'], entitlements: ['g1:improve-apps', 'g1:app-maker', 'g1:app-maker:edit', 'g1:notes'] },
    st: { ...ACTIVE, roles: [], groups: ['gs'], entitlements: ['gs:improve-apps', 'app:notes:steward'] },
    out: { ...ACTIVE, roles: [], groups: ['g9'], entitlements: ['g9:improve-apps'] },
    offAdm: { ...ACTIVE, status: 'SUSPENDED', roles: ['admin'], groups: [], entitlements: [] },
  };
  const ticket = { groupId: 'g1', appId: 'improve-apps', creatorId: 'u3', ownerIds: ['u3'], relatedAppId: 'notes', upvotedBy: [], downvotedBy: [], voteCount: 0, isClosed: false };
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(index)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, 'apps/notes'), { name: 'Notes', allowedGroups: [], securityTier: 'casual' });
    await setDoc(doc(db, 'app_categories/Admin'), {});
    await setDoc(doc(db, 'platform_config/default_group_apps'), { appIds: ['notes'] });
    await setDoc(doc(db, 'categories/c1'), { name: 'C' });
    await setDoc(doc(db, 'script_runs/s1'), { scriptKey: 'x', status: 'running' });
    await setDoc(doc(db, 'collection_catalog/notes'), { name: 'notes' });
    await setDoc(doc(db, 'collection_policies/notes_x'), { appId: 'notes' });
    await setDoc(doc(db, 'domain_verifications/d1'), { groupId: 'g1', domain: 'g1.example', status: 'active', steps: [] });
    await setDoc(doc(db, 'bug_reports/b1'), ticket);
    await setDoc(doc(db, 'feature_requests/f1'), ticket);
    // u1's own idea, and a ticket whose u1 vote the migration seeded.
    await setDoc(doc(db, 'feature_requests/f2'), { ...ticket, creatorId: 'u1', ownerIds: ['u1'], requesterId: 'u1', title: 'Mine' });
    await setDoc(doc(db, 'feature_requests/f3'), { ...ticket, upvotedBy: ['u1'], voteCount: 1 });
    await setDoc(doc(db, 'feature_requests/f3/votes/u1'), { userId: 'u1', value: 1, votedAt: 1, groupId: 'g1', appId: 'improve-apps', creatorId: 'u1', ownerIds: ['u1'] });
    await setDoc(doc(db, 'app_requests/r1'), { groupId: 'g1', appId: 'app-maker', creatorId: 'u3', ownerIds: ['u3'], status: 'new' });
    await setDoc(doc(db, 'app_requests/r2'), { groupId: 'g1', appId: 'app-maker', creatorId: 'u1', ownerIds: ['u1'], title: 'Mine', status: 'building' });
    await setDoc(doc(db, 'app_requests/r3'), { groupId: 'g1', appId: 'app-maker', creatorId: 'u1', ownerIds: ['u1'], title: 'Deleted', status: 'new', deletedAt: 1, deletedBy: 'u1' });
    await setDoc(doc(db, 'notes/n1'), { groupId: 'g1', appId: 'notes', creatorId: 'u3', ownerIds: ['u3'] });
    // u1's own bug, with a question from someone else (u3) and one of u1's comments.
    await setDoc(doc(db, 'bug_reports/b2'), { ...ticket, creatorId: 'u1', ownerIds: ['u1'] });
    await setDoc(doc(db, 'bug_reports/b2/comments/q3'), { text: 'staff question', authorId: 'u3', groupId: 'g1', appId: 'improve-apps', creatorId: 'u3', ownerIds: ['u3'], likedBy: ['u3'] });
    await setDoc(doc(db, 'bug_reports/b2/comments/m1'), { text: 'mine', authorId: 'u1', groupId: 'g1', appId: 'improve-apps', creatorId: 'u1', ownerIds: ['u1'] });
    await setDoc(doc(db, 'bug_reports/b2/comments/gone'), { text: '', authorId: 'u1', deletedAt: 1, deletedBy: 'u1', groupId: 'g1', appId: 'improve-apps', creatorId: 'u1', ownerIds: ['u1'] });
    // A soft-deleted bug of u1's: its thread takes no more writes.
    await setDoc(doc(db, 'bug_reports/b3'), { ...ticket, creatorId: 'u1', ownerIds: ['u1'], deletedAt: 1, deletedBy: 'u1' });
    await setDoc(doc(db, 'bug_reports/b2/comment_likes/u3'), { userId: 'u3', commentIds: ['q3'], groupId: 'g1', appId: 'improve-apps', creatorId: 'u3', ownerIds: ['u3'] });
  });
  const as = (uid) => env.authenticatedContext(uid).firestore();
  // What the shared comment widget writes (commentThread): ScopedCollection.sub
  // stamps the parent's tenant and, the thread being audited, the audit stamp.
  const comment = (uid, extra = {}) => ({ text: 'hi', authorId: uid, timestamp: 1, parentCommentId: null, groupId: 'g1', appId: 'improve-apps', creatorId: uid, ownerIds: [uid], lastModifiedBy: uid, lastModifiedAt: serverTimestamp(), ...extra });
  const stamp = (uid, data = {}) => ({ ...data, lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });
  const likesDoc = (uid, commentIds, extra = {}) => stamp(uid, { userId: uid, commentIds, updatedAt: 1, groupId: 'g1', appId: 'improve-apps', creatorId: uid, ownerIds: [uid], ...extra });
  // What the client files: no tallies or resolution flags (serverFields), stamped for the audit trail.
  const { upvotedBy: _u, downvotedBy: _d, voteCount: _c, isClosed: _x, ...ticketFields } = ticket;
  const newTicket = (uid, id) => ({ ...ticketFields, creatorId: uid, ownerIds: [uid], reporterId: uid, description: id, ...stamp(uid) });
  // app_requests is on the audit trail too. AppRequest.toMap()'s shape: the
  // requester's own fields, no review state and no submitter fields (the
  // server stamps those from Auth).
  const newAppRequest = (uid, extra = {}) => ({ groupId: 'g1', appId: 'app-maker', creatorId: uid, ownerIds: [uid], title: 'T', summary: '', attachments: [], createdAt: 1, updatedAt: 1, ...stamp(uid), ...extra });
  // A vote is the voter's own votes/{uid} doc (VoteToggle.cast); the tallies are the server's.
  // Votes are on the audit trail: VoteToggle.cast goes through ScopedCollection.sub, which stamps them.
  const voteDoc = (uid, value = 1) => stamp(uid, { userId: uid, value, votedAt: serverTimestamp(), groupId: 'g1', appId: 'improve-apps', creatorId: uid, ownerIds: [uid] });
  const vote = (db, p, uid) => setDoc(doc(db, `${p}/votes/${uid}`), voteDoc(uid));
  const writeTally = (db, p) => updateDoc(doc(db, p), { upvotedBy: ['x'], voteCount: 1 });
  const listTickets = (db, c, ...w) => getDocs(query(collection(db, c), where('appId', '==', 'improve-apps'), ...w));
  const [adm, dev, u1, st, out, offAdm] = ['adm', 'dev', 'u1', 'st', 'out', 'offAdm'].map(as);
  // u1 signed in with an email on their token (authorEmail is checked against it).
  const u1e = env.authenticatedContext('u1', { email: 'u1@x.example' }).firestore();

  const ok = [
    // Admin: the adminWritable catalog and checklists.
    ['admin edits an app\'s descriptive fields', () => updateDoc(doc(adm, 'apps/notes'), { name: 'Notes 2' })],
    ['admin adds an app category', () => setDoc(doc(adm, 'app_categories/New'), {})],
    ['admin sets platform_config', () => setDoc(doc(adm, 'platform_config/default_group_apps'), { appIds: [] })],
    ['admin begins a script run', () => setDoc(doc(adm, 'script_runs/s2'), { scriptKey: 'y', status: 'running' })],
    ['admin completes a script run', () => updateDoc(doc(adm, 'script_runs/s1'), { status: 'success' })],
    ['admin reads the collection catalog', () => getDocs(collection(adm, 'collection_catalog'))],
    ['admin reads collection policies', () => getDocs(collection(adm, 'collection_policies'))],
    ['admin reads script runs', () => getDocs(collection(adm, 'script_runs'))],
    ['admin lists domain verifications', () => getDocs(collection(adm, 'domain_verifications'))],
    ['admin creates a domain verification for any group', () => setDoc(doc(adm, 'domain_verifications/d2'), { groupId: 'g1', domain: 'x.example', status: 'active', steps: [] })],
    ['admin ticks a domain verification step', () => updateDoc(doc(adm, 'domain_verifications/d1'), { steps: [{ id: 'a', completed: true }] })],
    ['admin deletes a domain verification', () => deleteDoc(doc(adm, 'domain_verifications/d1'))],
    // Admin: cross-group triage reads, and comments where adminComments.
    ['admin lists every group\'s bugs (All groups)', () => listTickets(adm, 'bug_reports')],
    ['admin lists every group\'s ideas (All groups)', () => listTickets(adm, 'feature_requests')],
    ['admin lists every app request (platform admin cross-group read)', () => getDocs(collection(adm, 'app_requests'))],
    ['admin reads another group\'s bug comments', () => getDocs(collection(adm, 'bug_reports/b1/comments'))],
    ['admin comments on another group\'s bug', () => setDoc(doc(adm, 'bug_reports/b1/comments/ca1'), comment('adm'))],
    ['admin comments on another group\'s idea', () => setDoc(doc(adm, 'feature_requests/f1/comments/ca2'), comment('adm'))],
    ['admin comments on another group\'s app request', () => setDoc(doc(adm, 'app_requests/r1/comments/ca3'), comment('adm', { appId: 'app-maker' }))],
    // Developer: the same cross-group ticket reads and comments (adminComments).
    ['developer lists every group\'s bugs', () => listTickets(dev, 'bug_reports')],
    ['developer lists every app request', () => getDocs(collection(dev, 'app_requests'))],
    ['developer reads another group\'s bug comments', () => getDocs(collection(dev, 'bug_reports/b1/comments'))],
    ['developer comments on another group\'s bug', () => setDoc(doc(dev, 'bug_reports/b1/comments/cd1'), comment('dev'))],
    ['developer comments on another group\'s app request', () => setDoc(doc(dev, 'app_requests/r1/comments/cd2'), comment('dev', { appId: 'app-maker' }))],
    // Developer: the developerWritable catalog.
    ['developer edits an app\'s descriptive fields', () => updateDoc(doc(dev, 'apps/notes'), { name: 'Notes 3' })],
    ['developer adds an app category', () => setDoc(doc(dev, 'app_categories/Dev'), {})],
    ['developer sets platform_config', () => setDoc(doc(dev, 'platform_config/default_group_apps'), { appIds: ['notes'] })],
    ['developer reads the collection catalog', () => getDocs(collection(dev, 'collection_catalog'))],
    ['developer reads collection policies', () => getDocs(collection(dev, 'collection_policies'))],
    ['developer lists domain verifications', () => getDocs(collection(dev, 'domain_verifications'))],
    ['developer creates a domain verification', () => setDoc(doc(dev, 'domain_verifications/d3'), { groupId: 'g1', domain: 'y.example', status: 'active', steps: [] })],
    // Everyone signed in reads the platform catalog.
    ['member reads apps', () => getDocs(collection(u1, 'apps'))],
    ['member reads app categories', () => getDocs(collection(u1, 'app_categories'))],
    ['member reads platform_config', () => getDoc(doc(u1, 'platform_config/default_group_apps'))],
    ['member reads categories', () => getDocs(collection(u1, 'categories'))],
    // Improve Apps, the ticket's own group: submit, list, vote, comment.
    ['member submits a bug', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAAA1'), newTicket('u1', 'b'))],
    ['member submits an idea', () => setDoc(doc(u1, 'feature_requests/AAAAAAAAAAAAAAAAAAA2'), newTicket('u1', 'f'))],
    ['member lists their group\'s bugs', () => listTickets(u1, 'bug_reports', where('groupId', '==', 'g1'))],
    ['member lists their group\'s ideas', () => listTickets(u1, 'feature_requests', where('groupId', '==', 'g1'))],
    ['member votes on a groupmate\'s bug', () => vote(u1, 'bug_reports/b1', 'u1')],
    ['member votes on a groupmate\'s idea', () => vote(u1, 'feature_requests/f1', 'u1')],
    ['member withdraws their vote', () => updateDoc(doc(u1, 'feature_requests/f1/votes/u1'), stamp('u1', { value: 0, votedAt: serverTimestamp() }))],
    ['member changes their vote (full set, as VoteToggle.cast)', () => setDoc(doc(u1, 'feature_requests/f1/votes/u1'), voteDoc('u1', -1))],
    ['member comments on a bug', () => setDoc(doc(u1, 'bug_reports/b1/comments/cu1'), comment('u1'))],
    ['member comments with their own token email', () => setDoc(doc(u1e, 'bug_reports/b1/comments/ce1'), comment('u1', { authorEmail: 'u1@x.example' }))],
    ['member likes a comment (own likes doc)', () => setDoc(doc(u1, 'bug_reports/b1/comment_likes/u1'), likesDoc('u1', ['cu1']))],
    ['member unlikes it', () => updateDoc(doc(u1, 'bug_reports/b1/comment_likes/u1'), stamp('u1', { commentIds: [], updatedAt: 2 }))],
    ['member reads the thread\'s likes', () => getDocs(collection(u1, 'bug_reports/b2/comment_likes'))],
    ['member soft-deletes their own comment', () => updateDoc(doc(u1, 'bug_reports/b2/comments/m1'), stamp('u1', { text: '', deletedAt: serverTimestamp(), deletedBy: 'u1' }))],
    ['member edits their own comment', () => updateDoc(doc(u1, 'bug_reports/b1/comments/cu1'), stamp('u1', { text: 'edited' }))],
    ['steward likes a comment on a stewarded bug', () => setDoc(doc(st, 'bug_reports/b1/comment_likes/st'), likesDoc('st', ['cu1']))],
    ['developer likes a comment on another group\'s bug', () => setDoc(doc(dev, 'bug_reports/b1/comment_likes/dev'), likesDoc('dev', ['cu1']))],
    ['member edits their own bug', () => updateDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAAA1'), { description: 'more', ...stamp('u1') })],
    ['member edits their own idea', () => updateDoc(doc(u1, 'feature_requests/f2'), { title: 'Mine, edited', ...stamp('u1') })],
    // VoteToggle.cast on an existing doc: ScopedCollection.set keeps the identity, a full set.
    ['member changes a vote the migration seeded', () => setDoc(doc(u1, 'feature_requests/f3/votes/u1'), voteDoc('u1', -1))],
    ['member submits an app request', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA3'), newAppRequest('u1'))],
    ['member edits their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { title: 'Mine, edited', summary: 's', updatedAt: 2, ...stamp('u1') })],
    // Stewards: Apps I manage.
    ['steward lists bugs about the app they steward', () => listTickets(st, 'bug_reports', where('relatedAppId', '==', 'notes'))],
    ['steward lists ideas about the app they steward', () => listTickets(st, 'feature_requests', where('relatedAppId', '==', 'notes'))],
    ['steward opens a stewarded bug', () => getDoc(doc(st, 'bug_reports/b1'))],
    ['steward reads its comments', () => getDocs(collection(st, 'bug_reports/b1/comments'))],
    ['steward comments on a stewarded bug', () => setDoc(doc(st, 'bug_reports/b1/comments/cs1'), comment('st'))],
    ['steward comments on a stewarded idea', () => setDoc(doc(st, 'feature_requests/f1/comments/cs2'), comment('st'))],
  ];
  const deny = [
    // Admin: no raw writes outside adminWritable (T14 moved them to callables).
    ['admin writes an app permission field', () => updateDoc(doc(adm, 'apps/notes'), { allowedGroups: ['g9'] })],
    ['admin votes on another group\'s bug', () => vote(adm, 'bug_reports/b1', 'adm')],
    // Improve Apps members: tallies and deletes are the server's; edits need
    // the audit stamp, and stop at the member's own tickets.
    ['member writes a ticket\'s vote tally', () => writeTally(u1, 'bug_reports/b1')],
    ['member writes their own ticket\'s vote tally', () => updateDoc(doc(u1, 'bug_reports/b2'), { voteCount: 9, ...stamp('u1') })],
    ['member submits a bug with a vote tally', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAA10'), { ...newTicket('u1', 't'), voteCount: 5 })],
    ['member votes as someone else', () => setDoc(doc(u1, 'bug_reports/b1/votes/u3'), voteDoc('u3'))],
    ['member writes a vote for someone else on their own bug', () => setDoc(doc(u1, 'bug_reports/b2/votes/u3'), voteDoc('u3'))],
    ['member writes a vote under a made-up id on their own bug', () => setDoc(doc(u1, 'bug_reports/b2/votes/fake123'), voteDoc('fake123'))],
    ['member deletes their vote', () => deleteDoc(doc(u1, 'feature_requests/f1/votes/u1'))],
    ['member votes without the audit stamp', () => setDoc(doc(u1, 'bug_reports/b2/votes/u1'),
      { userId: 'u1', value: 1, votedAt: serverTimestamp(), groupId: 'g1', appId: 'improve-apps', creatorId: 'u1', ownerIds: ['u1'] })],
    ['member changes their vote without the audit stamp', () => updateDoc(doc(u1, 'bug_reports/b1/votes/u1'), { value: -1 })],
    ['member stamps their vote in someone else\'s name', () => setDoc(doc(u1, 'bug_reports/b2/votes/u1'), stamp('u3', { userId: 'u1', value: 1, votedAt: serverTimestamp(), groupId: 'g1', appId: 'improve-apps', creatorId: 'u1', ownerIds: ['u1'] }))],
    ['member files a vote under another group\'s tenant', () => setDoc(doc(u1, 'bug_reports/b2/votes/u1'), { ...voteDoc('u1'), groupId: 'g9' })],
    ['member edits a groupmate\'s bug', () => updateDoc(doc(u1, 'bug_reports/b1'), { description: 'x', ...stamp('u1') })],
    ['member edits their own bug without the audit stamp', () => updateDoc(doc(u1, 'bug_reports/b2'), { description: 'more' })],
    ['member submits a bug without the audit stamp', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAA11'), { ...ticketFields, creatorId: 'u1', ownerIds: ['u1'], reporterId: 'u1' })],
    ['member hard-deletes their own bug', () => deleteDoc(doc(u1, 'bug_reports/b2'))],
    ['member closes their own idea directly (stamped; callable only)', () => updateDoc(doc(u1, 'feature_requests/f2'), { isClosed: true, ...stamp('u1') })],
    ['member completes their own idea directly (stamped; callable only)', () => updateDoc(doc(u1, 'feature_requests/f2'), { isCompleted: true, ...stamp('u1') })],
    ['member stamps closedBy on their own idea', () => updateDoc(doc(u1, 'feature_requests/f2'), { closedBy: 'u3', ...stamp('u1') })],
    ['member writes their own idea\'s tally (stamped)', () => updateDoc(doc(u1, 'feature_requests/f2'), { voteCount: 9, upvotedBy: ['u1'], ...stamp('u1') })],
    ['member files an idea already closed', () => setDoc(doc(u1, 'feature_requests/AAAAAAAAAAAAAAAAAA12'), { ...newTicket('u1', 'c'), isClosed: true })],
    ['member files an idea already completed', () => setDoc(doc(u1, 'feature_requests/AAAAAAAAAAAAAAAAAA13'), { ...newTicket('u1', 'c'), isCompleted: true })],
    ['member files a bug already fixed', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAA14'), { ...newTicket('u1', 'c'), isFixed: true })],
    // A deleted ticket takes no client edit, comment or vote; restore is the server's.
    ['member edits their own deleted bug', () => updateDoc(doc(u1, 'bug_reports/b3'), { description: 'again', ...stamp('u1') })],
    ['member restores their own deleted bug', () => updateDoc(doc(u1, 'bug_reports/b3'), { deletedAt: null, deletedBy: null, ...stamp('u1') })],
    ['member comments on their own deleted bug', () => setDoc(doc(u1, 'bug_reports/b3/comments/cx1'), comment('u1'))],
    ['admin comments on a deleted bug', () => setDoc(doc(adm, 'bug_reports/b3/comments/cx2'), comment('adm'))],
    ['member votes on their own deleted bug', () => vote(u1, 'bug_reports/b3', 'u1')],
    ['member marks their own bug fixed directly (callable only)', () => updateDoc(doc(u1, 'bug_reports/b2'), { isFixed: true, ...stamp('u1') })],
    ['member stamps fixedBy on their own bug', () => updateDoc(doc(u1, 'bug_reports/b2'), { fixedBy: 'u3', fixMessage: 'done', ...stamp('u1') })],
    ['member marks their own bug deleted (callable only)', () => updateDoc(doc(u1, 'bug_reports/b2'), { deletedAt: 1, deletedBy: 'u1', ...stamp('u1') })],
    ['admin edits another group\'s idea', () => updateDoc(doc(adm, 'feature_requests/f1'), { description: 'x' })],
    ['admin deletes another group\'s bug', () => deleteDoc(doc(adm, 'bug_reports/b1'))],
    ['admin sets an app request status directly', () => updateDoc(doc(adm, 'app_requests/r1'), { status: 'planned' })],
    ['admin deletes an app request directly', () => deleteDoc(doc(adm, 'app_requests/r1'))],
    ['admin writes another group\'s note', () => updateDoc(doc(adm, 'notes/n1'), { title: 'x' })],
    ['admin comments where adminComments is not declared', () => setDoc(doc(adm, 'notes/n1/comments/c1'), comment('adm', { appId: 'notes' }))],
    ['admin comments as someone else', () => setDoc(doc(adm, 'bug_reports/b1/comments/ca9'), comment('u3'))],
    ['admin likes another group\'s comment by editing it', () => updateDoc(doc(adm, 'bug_reports/b1/comments/cu1'), stamp('adm', { likedBy: ['adm'] }))],
    // The comment thread (commentThread): author-owned, audited, never hard-deleted.
    ['member comments without the audit stamp', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx1'), { ...comment('u1'), lastModifiedAt: 1 })],
    // Review fixes: tenant pinned to the parent, email from the token, text cleared, likes bounded, frozen threads.
    ['member files a comment under another group\'s tenant', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx4'), comment('u1', { groupId: 'g9' }))],
    ['member files a comment under another app', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx5'), comment('u1', { appId: 'notes' }))],
    ['member comments in someone else\'s email', () => setDoc(doc(u1e, 'bug_reports/b1/comments/cx6'), comment('u1', { authorEmail: 'boss@x.example' }))],
    ['member comments with an email but none on their token', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx7'), comment('u1', { authorEmail: 'u1@x.example' }))],
    ['author changes their comment\'s email', () => updateDoc(doc(u1e, 'bug_reports/b1/comments/ce1'), stamp('u1', { authorEmail: 'other@x.example' }))],
    ['author soft-deletes without clearing the text', () => updateDoc(doc(u1, 'bug_reports/b1/comments/cu1'), stamp('u1', { deletedAt: serverTimestamp(), deletedBy: 'u1' }))],
    ['author edits the text of an already-deleted comment', () => updateDoc(doc(u1, 'bug_reports/b2/comments/gone'), stamp('u1', { text: 'back again' }))],
    ['member creates a likes doc under another uid', () => setDoc(doc(u1, 'bug_reports/b1/comment_likes/u3'), likesDoc('u1', ['cu1']))],
    ['member creates a likes doc in another\'s name', () => setDoc(doc(u1, 'bug_reports/b1/comment_likes/u3'), likesDoc('u3', ['cu1']))],
    ['member likes more than 500 comments in one doc', () => setDoc(doc(u1, 'bug_reports/b2/comment_likes/u1'), likesDoc('u1', Array.from({ length: 501 }, (_, i) => `c${i}`)))],
    ['member sets commentIds to a non-list', () => setDoc(doc(u1, 'bug_reports/b2/comment_likes/u1'), likesDoc('u1', 'cu1'))],
    ['member files a likes doc under another group\'s tenant', () => setDoc(doc(u1, 'bug_reports/b2/comment_likes/u1'), likesDoc('u1', ['q3'], { groupId: 'g9' }))],
    ['member comments on a soft-deleted bug', () => setDoc(doc(u1, 'bug_reports/b3/comments/cx8'), comment('u1'))],
    ['member likes on a soft-deleted bug', () => setDoc(doc(u1, 'bug_reports/b3/comment_likes/u1'), likesDoc('u1', ['x']))],
    ['member comments pre-marked as moderated', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx3'), comment('u1', { moderationReason: 'x' }))],
    ['member comments with deletedAt set', () => setDoc(doc(u1, 'bug_reports/b1/comments/cx2'), comment('u1', { deletedAt: serverTimestamp(), deletedBy: 'u1' }))],
    ['requester (parent editor) comments as someone else', () => setDoc(doc(u1, 'bug_reports/b2/comments/cf1'), comment('u1', { authorId: 'adm' }))],
    ['requester (parent editor) comments as someone else on an app request', () => setDoc(doc(u1, 'app_requests/r2/comments/cf2'), comment('u1', { authorId: 'u3', appId: 'app-maker' }))],
    ['requester hard-deletes a question on their bug', () => deleteDoc(doc(u1, 'bug_reports/b2/comments/q3'))],
    ['requester soft-deletes a question on their bug', () => updateDoc(doc(u1, 'bug_reports/b2/comments/q3'), stamp('u1', { text: '', deletedAt: serverTimestamp(), deletedBy: 'u1' }))],
    ['requester edits a question on their bug', () => updateDoc(doc(u1, 'bug_reports/b2/comments/q3'), stamp('u1', { text: 'changed' }))],
    ['member likes by editing someone else\'s comment', () => updateDoc(doc(u1, 'bug_reports/b2/comments/q3'), stamp('u1', { likedBy: ['u3', 'u1'] }))],
    ['member hard-deletes their own comment', () => deleteDoc(doc(u1, 'bug_reports/b2/comments/m1'))],
    ['member restores their deleted comment', () => updateDoc(doc(u1, 'bug_reports/b2/comments/gone'), stamp('u1', { deletedAt: null, deletedBy: null, text: 'back' }))],
    ['member soft-deletes in someone else\'s name', () => updateDoc(doc(u1, 'bug_reports/b1/comments/cu1'), stamp('u1', { deletedAt: serverTimestamp(), deletedBy: 'u3' }))],
    ['member changes a comment\'s author', () => updateDoc(doc(u1, 'bug_reports/b1/comments/cu1'), stamp('u1', { authorId: 'u3' }))],
    ['member edits someone else\'s likes', () => updateDoc(doc(u1, 'bug_reports/b2/comment_likes/u3'), stamp('u1', { commentIds: [] }))],
    ['member deletes their likes doc', () => deleteDoc(doc(u1, 'bug_reports/b1/comment_likes/u1'))],
    ['member likes without the audit stamp', () => setDoc(doc(u1, 'bug_reports/b2/comment_likes/u1'), { ...likesDoc('u1', ['q3']), lastModifiedAt: 1 })],
    ['other group member likes', () => setDoc(doc(out, 'bug_reports/b1/comment_likes/out'), likesDoc('out', ['cu1']))],
    ['admin writes the collection catalog', () => setDoc(doc(adm, 'collection_catalog/x'), { name: 'x' })],
    ['admin writes collection policies', () => setDoc(doc(adm, 'collection_policies/x'), { appId: 'x' })],
    ['admin writes categories', () => setDoc(doc(adm, 'categories/c2'), { name: 'D' })],
    ['admin deletes a script run', () => deleteDoc(doc(adm, 'script_runs/s1'))],
    ['suspended admin comments on a bug', () => setDoc(doc(offAdm, 'bug_reports/b1/comments/co1'), comment('offAdm'))],
    ['suspended admin lists every group\'s bugs', () => listTickets(offAdm, 'bug_reports')],
    // Developer: reads only, outside developerWritable.
    ['developer writes a script run', () => setDoc(doc(dev, 'script_runs/s3'), { scriptKey: 'z' })],
    ['developer reads script runs', () => getDocs(collection(dev, 'script_runs'))],
    ['developer writes the collection catalog', () => setDoc(doc(dev, 'collection_catalog/y'), { name: 'y' })],
    ['developer writes an app permission field', () => updateDoc(doc(dev, 'apps/notes'), { stewardGroupIds: ['gd'] })],
    ['developer edits another group\'s idea', () => updateDoc(doc(dev, 'feature_requests/f1'), { description: 'x' })],
    ['developer deletes another group\'s bug', () => deleteDoc(doc(dev, 'bug_reports/b1'))],
    ['developer comments as someone else', () => setDoc(doc(dev, 'bug_reports/b1/comments/cd9'), comment('u3'))],
    ['developer comments where adminComments is not declared', () => setDoc(doc(dev, 'notes/n1/comments/cd8'), comment('dev', { appId: 'notes' }))],
    ['developer reads another group\'s note', () => getDocs(collection(dev, 'notes'))],
    // Members: the platform catalog and admin collections are locked.
    ['member edits an app', () => updateDoc(doc(u1, 'apps/notes'), { name: 'mine' })],
    ['member adds an app category', () => setDoc(doc(u1, 'app_categories/Mine'), {})],
    ['member writes platform_config', () => setDoc(doc(u1, 'platform_config/default_group_apps'), { appIds: [] })],
    ['member reads the collection catalog', () => getDocs(collection(u1, 'collection_catalog'))],
    ['member reads script runs', () => getDocs(collection(u1, 'script_runs'))],
    ['member reads domain verifications', () => getDocs(collection(u1, 'domain_verifications'))],
    ['member creates a domain verification', () => setDoc(doc(u1, 'domain_verifications/d4'), { groupId: 'g1', domain: 'z.example' })],
    ['member submits a bug into another group', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAAA4'), { ...newTicket('u1', 'x'), groupId: 'g9' })],
    ['member lists every group\'s bugs', () => listTickets(u1, 'bug_reports')],
    // App Maker review state is server-owned (app_requests.serverFields):
    // builtAppId is installed into the request's group when it ships.
    ['member submits an app request with a builtAppId', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA5'), newAppRequest('u1', { builtAppId: 'notes' }))],
    ['member submits an app request with a null builtAppId', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA6'), newAppRequest('u1', { builtAppId: null }))],
    ['member submits an app request with a status', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA7'), newAppRequest('u1', { status: 'new' }))],
    ['member sets builtAppId on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { builtAppId: 'notes', ...stamp('u1') })],
    ['member ships their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { status: 'shipped', ...stamp('u1') })],
    ['member sets decline fields on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { declineReasonCode: 'x', declineReasonLabel: 'x', declineNote: 'x', ...stamp('u1') })],
    ['member sets shippedAt on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { shippedAt: 1, ...stamp('u1') })],
    ['member sets builtAppId on a groupmate\'s app request', () => updateDoc(doc(u1, 'app_requests/r1'), { builtAppId: 'notes', ...stamp('u1') })],
    // A regression report's link to what broke decides the expedite pool, so
    // only devQueueReportRegression writes it; the edit and decline stamps are
    // the queue's too (PHASE_2_5_DESIGN.md 5).
    ['member submits a bug with regressionOf', () => setDoc(doc(u1, 'bug_reports/AAAAAAAAAAAAAAAAAAA8'), { ...newTicket('u1', 'r'), regressionOf: { itemKey: 'feature__f1' } })],
    ['member submits an idea with regressionOf', () => setDoc(doc(u1, 'feature_requests/AAAAAAAAAAAAAAAAAAA9'), { ...newTicket('u1', 'r'), regressionOf: { itemKey: 'feature__f1' } })],
    // platformSource marks work the platform files for itself, which queues
    // under the platform owner and notifies no requester.
    ['member submits an idea with a platformSource', () => setDoc(doc(u1, 'feature_requests/AAAAAAAAAAAAAAAAAAP1'), { ...newTicket('u1', 'r'), platformSource: 'advisor-round' })],
    ['member stamps editedAt on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { editedAt: 1, editedBy: 'u1', ...stamp('u1') })],
    ['member stamps declinedAt on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { declinedAt: 1, declinedBy: 'u1', ...stamp('u1') })],
    // App Maker is regulated (Tier 4): audited, no client delete or restore,
    // only the requester edits, and the submitter fields are server-stamped.
    ['member edits their own app request without the audit stamp', () => updateDoc(doc(u1, 'app_requests/r2'), { title: 'Unstamped' })],
    ['member submits an app request stamped as someone else', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA8'), newAppRequest('u1', { lastModifiedBy: 'someone-else' }))],
    ['member submits an app request claiming a submitter', () => setDoc(doc(u1, 'app_requests/AAAAAAAAAAAAAAAAAAA9'), newAppRequest('u1', { submitterEmail: 'boss@x.example' }))],
    ['member changes the submitter on their own app request', () => updateDoc(doc(u1, 'app_requests/r2'), { submitterName: 'Boss', ...stamp('u1') })],
    ['member hard-deletes their own app request', () => deleteDoc(doc(u1, 'app_requests/r2'))],
    ['member soft-deletes their own app request directly', () => updateDoc(doc(u1, 'app_requests/r2'), { deletedAt: 1, deletedBy: 'u1', ...stamp('u1') })],
    ['member edits a groupmate\'s app request', () => updateDoc(doc(u1, 'app_requests/r1'), { title: 'Not mine', ...stamp('u1') })],
    // The generic soft-delete lock: a deleted request takes no edit, restore or comment.
    ['member edits their own deleted app request', () => updateDoc(doc(u1, 'app_requests/r3'), { title: 'Edited', ...stamp('u1') })],
    ['member restores their own deleted app request', () => updateDoc(doc(u1, 'app_requests/r3'), { deletedAt: null, deletedBy: null, ...stamp('u1') })],
    ['member comments on their own deleted app request', () => setDoc(doc(u1, 'app_requests/r3/comments/cdel'), comment('u1', { appId: 'app-maker' }))],
    // Stewards: read and comment, never change the ticket.
    ['steward votes on a stewarded bug', () => vote(st, 'bug_reports/b1', 'st')],
    ['steward edits a stewarded idea', () => updateDoc(doc(st, 'feature_requests/f1'), { description: 'x' })],
    ['steward lists bugs without the relatedAppId filter', () => listTickets(st, 'bug_reports')],
    ['steward comments on an app request', () => setDoc(doc(st, 'app_requests/r1/comments/cs3'), comment('st', { appId: 'app-maker' }))],
    // Outsiders.
    ['outsider opens another group\'s bug', () => getDoc(doc(out, 'bug_reports/b1'))],
    ['outsider lists another group\'s bugs', () => listTickets(out, 'bug_reports', where('groupId', '==', 'g1'))],
    ['outsider comments on another group\'s bug', () => setDoc(doc(out, 'bug_reports/b1/comments/co2'), comment('out'))],
    ['outsider votes on another group\'s idea', () => vote(out, 'feature_requests/f1', 'out')],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`stage 4: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`); fails.forEach((f) => console.log('FAILCASE ' + f));
  if (fails.length) throw new Error(fails.join('\n'));
});

// Stage 4 (Vendor Marketplace listings): vendor_market_listings and
// vendor_market_listing_private under the committed rules. Operator
// staff (Marketplace Admin, in the operator group) keep their direct reads
// and writes; a claimed vendor, whose home group is not the operator's, has
// none: Vendor Hub reads and edits their listing through the vendorHub*
// callables (functions/vendor_hub.js). Outsiders get nothing.
test('stage 4: vendor marketplace listings', async () => {
  const gen = require('../../generate');
  const env = await openTestEnv({ projectId: 'demo-bluejay-stage4-vendor', firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') } });
  const ACTIVE = { status: 'ACTIVE', roles: [], guest_groups: [], denied_scopes: [], clearance_level: 0 };
  const OP = 'gop';
  const index = {
    op: { ...ACTIVE, groups: [OP], entitlements: [`${OP}:marketplace-admin`, `${OP}:marketplace-admin:edit`] },
    opReader: { ...ACTIVE, groups: [OP], entitlements: [`${OP}:marketplace-admin`] },
    vendor: { ...ACTIVE, groups: ['gv'], entitlements: ['gv:vendor-hub', 'gv:vendor-hub:edit'] },
    out: { ...ACTIVE, groups: ['g9'], entitlements: ['g9:marketplace-admin', 'g9:marketplace-admin:edit', 'g9:vendor-hub'] },
  };
  const identity = { groupId: OP, appId: 'marketplace-admin', creatorId: 'op', ownerIds: ['vendor'] };
  const claimed = { ...identity, claimStatus: 'claimed', claimedByUid: 'vendor', vendorHomeGroupId: 'gv', name: 'DJ', status: 'draft' };
  const L = 'AbCdEfGhIjKlMnOpQrS1', L2 = 'AbCdEfGhIjKlMnOpQrS2';
  const fresh = (creatorId, extra = {}) => ({ groupId: OP, appId: 'marketplace-admin', creatorId, ownerIds: [creatorId], ...extra });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, ix] of Object.entries(index)) await setDoc(doc(db, `users/${uid}/metadata/access_index`), ix);
    await setDoc(doc(db, `vendor_market_listings/${L}`), claimed);
    await setDoc(doc(db, `vendor_market_listing_private/${L}`), { ...identity, contactEmail: 'dj@example.com', forwardInquiriesByEmail: false });
  });
  const [op, opReader, vendor, out] = ['op', 'opReader', 'vendor', 'out'].map((uid) => env.authenticatedContext(uid).firestore());
  const listings = (d) => collection(d, 'vendor_market_listings');
  const ok = [
    // Marketplace Admin, operator group: the listings tab, detail, editor, publish toggle.
    ['operator lists every listing', () => getDocs(query(listings(op), where('groupId', '==', OP)))],
    ['operator opens a listing', () => getDoc(doc(op, `vendor_market_listings/${L}`))],
    ['operator reads its contact details', () => getDoc(doc(op, `vendor_market_listing_private/${L}`))],
    ['operator edits a claimed listing', () => updateDoc(doc(op, `vendor_market_listings/${L}`), { tagline: 'Tunes', updatedAt: 1 })],
    ['operator publishes a listing', () => updateDoc(doc(op, `vendor_market_listings/${L}`), { status: 'published' })],
    ['operator edits contact details', () => updateDoc(doc(op, `vendor_market_listing_private/${L}`), { contactPhone: '555' })],
    ['operator creates a listing', () => setDoc(doc(op, `vendor_market_listings/${L2}`), fresh('op', { name: 'New', claimStatus: 'unclaimed', status: 'draft' }))],
    ['operator creates its contact details', () => setDoc(doc(op, `vendor_market_listing_private/${L2}`), fresh('op', { contactName: 'x' }))],
    ['operator reader opens a listing', () => getDoc(doc(opReader, `vendor_market_listings/${L}`))],
  ];
  const deny = [
    // The claimed vendor: every listing read and write is the callables' now.
    ['claimed vendor opens their listing directly', () => getDoc(doc(vendor, `vendor_market_listings/${L}`))],
    ['claimed vendor lists their listings directly (old watchClaimedListings)', () => getDocs(query(listings(vendor), where('groupId', '==', OP), where('ownerIds', 'array-contains', 'vendor')))],
    ['claimed vendor reads their contact details directly', () => getDoc(doc(vendor, `vendor_market_listing_private/${L}`))],
    ['claimed vendor edits their listing directly', () => updateDoc(doc(vendor, `vendor_market_listings/${L}`), { tagline: 'Mine' })],
    ['claimed vendor toggles publish directly', () => updateDoc(doc(vendor, `vendor_market_listings/${L}`), { status: 'published' })],
    ['claimed vendor edits contact details directly', () => updateDoc(doc(vendor, `vendor_market_listing_private/${L}`), { contactPhone: '1' })],
    // Operator staff: claim fields and deletes stay server-side; the read tier can't write.
    ['operator reassigns ownership', () => updateDoc(doc(op, `vendor_market_listings/${L}`), { ownerIds: ['op'] })],
    ['operator unclaims a listing', () => updateDoc(doc(op, `vendor_market_listings/${L}`), { claimStatus: 'unclaimed' })],
    ['operator deletes a listing', () => deleteDoc(doc(op, `vendor_market_listings/${L}`))],
    ['operator reader edits a listing', () => updateDoc(doc(opReader, `vendor_market_listings/${L}`), { tagline: 'x' })],
    ['operator reader edits contact details', () => updateDoc(doc(opReader, `vendor_market_listing_private/${L}`), { contactPhone: '2' })],
    ['operator reader creates a listing', () => setDoc(doc(opReader, 'vendor_market_listings/AbCdEfGhIjKlMnOpQrS4'), fresh('opReader', { name: 'x' }))],
    // Outsiders, including another group's Marketplace Admin staff.
    ['outsider opens the listing', () => getDoc(doc(out, `vendor_market_listings/${L}`))],
    ['outsider lists the operator\'s listings', () => getDocs(query(listings(out), where('groupId', '==', OP)))],
    ['outsider reads contact details', () => getDoc(doc(out, `vendor_market_listing_private/${L}`))],
    ['outsider edits the listing', () => updateDoc(doc(out, `vendor_market_listings/${L}`), { tagline: 'x' })],
    ['outsider creates a listing in the operator group', () => setDoc(doc(out, 'vendor_market_listings/AbCdEfGhIjKlMnOpQrS3'), fresh('out', { name: 'x' }))],
  ];
  const fails = [];
  for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
  for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
  await releaseTestEnv(env);
  console.log(`stage 4 vendor listings: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`); fails.forEach((f) => console.log('FAILCASE ' + f));
  if (fails.length) throw new Error(fails.join('\n'));
});

// Stage 5 (rules plan §8.3, D1): the guest flows of the four embeddable apps
// (Rented Dwelling, Course of Construction, NAIC Sight, Warehouse Uploader),
// with real guest personas: role-'guest' memberships, production's app
// config and a corporate attestation, turned into access indexes by the real
// buildUserAccessIndex (lib/guests.js). Run against the committed rules.
// A guest creates and works on their own application,
// job or upload, reads their own and the app config shared with guests, and
// never reads anyone else's records or the group directory. The Storage
// side of the same flows is in storage.test.js (Storage rules are global to
// the emulator, so they run in that file's sequence).
{
  const assert = require('node:assert/strict');
  const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const {
    doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, orderBy, limit, getDocs, serverTimestamp,
  } = require('firebase/firestore');
  const gen = require('../../generate');
  const guests = require('../lib/guests');
  const { G, GUEST, OTHER_GUEST, UNATTESTED, MEMBER } = guests;

  const RD = 'rented-dwelling', COC = 'course-of-construction', NAIC = 'naic-sight', IMPORTS = 'warehouse-imports';
  const PRODUCT = { [RD]: 'Rented Dwelling', [COC]: 'Course of Construction' };
  // 20-char auto ids, per product: [mine, theirs, a new one].
  const IDS = {
    [RD]: ['GuestRdGuestRdMine01', 'GuestRdGuestRdTheirs', 'GuestRdGuestRdNew001'],
    [COC]: ['GuestCcGuestCcMine01', 'GuestCcGuestCcTheirs', 'GuestCcGuestCcNew001'],
  };
  const JOB = '0b8f2a3c-1d4e-4f5a-8b6c-7d8e9f0a1b21';
  const OTHER_JOB = '0b8f2a3c-1d4e-4f5a-8b6c-7d8e9f0a1b22';
  const NEW_JOB = '0b8f2a3c-1d4e-4f5a-8b6c-7d8e9f0a1b23';
  const UNADMITTED_JOB = '0b8f2a3c-1d4e-4f5a-8b6c-7d8e9f0a1b24';
  const stamp = (appId, uid) => ({ groupId: G, appId, creatorId: uid, ownerIds: [uid] });
  // What ScopedCollection adds to every write to an auditTrail collection.
  const audit = (uid) => ({ lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });
  // What the application forms write (insurance_application_form_screen.dart).
  const application = (appId, uid, extra = {}) => ({
    ...stamp(appId, uid), userId: uid, policyProductType: PRODUCT[appId], status: 'draft', ...extra,
  });
  // naic_sight_screen.dart's job, and the pipeline's upload (functions/warehouse_uploads.js).
  const job = (uid) => ({ ...stamp(NAIC, uid), userId: uid, fileName: 'f.csv', status: 'pending', createdAt: serverTimestamp() });
  const upload = (uid) => ({ ...stamp(IMPORTS, uid), uploader: { kind: 'guest', uid }, status: 'preview_ready', createdAt: 1 });

  {
    const variant = 'committed';
    test('stage 5: embeddable-app guest flows', async () => {
      const env = await openTestEnv({
        projectId: 'demo-bluejay-stage5',
        firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') },
      });
      let indexes;
      await env.withSecurityRulesDisabled(async (ctx) => {
        const db = ctx.firestore();
        indexes = await guests.seedGuests(db);
        for (const appId of [RD, COC]) {
          await setDoc(doc(db, `insurance_applications/${IDS[appId][0]}`), application(appId, GUEST));
          await setDoc(doc(db, `insurance_applications/${IDS[appId][1]}`), application(appId, OTHER_GUEST, { status: 'active', policyNumber: 'P-1' }));
        }
        // Course of Construction is configured in G; Rented Dwelling isn't
        // (as in production, where no group has a rented_dwelling_config doc).
        await setDoc(doc(db, `insurance_coc_config/${G}`), { ...stamp(COC, 'staff'), flowMode: 'quote_only', allowedProvinces: ['MB'] });
        await setDoc(doc(db, `property_data_cache/${G}__${RD}_1_main_st`), { ...stamp(RD, OTHER_GUEST), winnipegData: {} });
        await setDoc(doc(db, `naic_sight_jobs/${JOB}`), job(GUEST));
        await setDoc(doc(db, `naic_sight_jobs/${OTHER_JOB}`), job(OTHER_GUEST));
        await setDoc(doc(db, 'warehouse_uploads/up-guest'), upload(GUEST));
        await setDoc(doc(db, 'warehouse_uploads/up-other'), upload(OTHER_GUEST));
        await setDoc(doc(db, `group_members/${G}__${MEMBER}`), { groupId: G, uid: MEMBER, email: 'm@acme.example' });
        await setDoc(doc(db, 'invitations/inv1'), { groupId: G, appId: 'users', email: 'x@acme.example', status: 'pending' });
        await setDoc(doc(db, 'notifications/n-guest'), { groupId: G, appId: RD, recipientId: GUEST, isRead: false });
      });

      // The personas are what production builds: a guest holds only `:guest`
      // and the `:collection:` scopes of the apps that admit them (never a
      // base, :edit or :admin entitlement), and the group is a guest group.
      const ix = indexes[GUEST];
      assert.deepEqual(ix.guest_groups, [G]);
      assert.deepEqual([...ix.entitlements].sort(), [
        `${G}:${COC}:collection:insurance_applications`, `${G}:${COC}:collection:insurance_coc_config`, `${G}:${COC}:guest`,
        `${G}:${NAIC}:guest`,
        `${G}:${RD}:collection:insurance_applications`, `${G}:${RD}:collection:rented_dwelling_config`, `${G}:${RD}:guest`,
        `${G}:warehouse-uploader:guest`,
      ]);
      assert.ok(!indexes[UNATTESTED].entitlements.includes(`${G}:${NAIC}:guest`), 'the corporate app admits only attested guests');

      const db = env.authenticatedContext(GUEST).firestore();
      const noId = env.authenticatedContext(UNATTESTED).firestore();
      const apps = collection(db, 'insurance_applications');
      // insurance_applications_list_screen.dart (both products):
      // ScopedCollection.query (groupId, appId) + creatorId + policyProductType.
      const listApplications = (appId, field = 'creatorId', uid = GUEST) => getDocs(query(apps,
        where('groupId', '==', G), where('appId', '==', appId), where(field, '==', uid), where('policyProductType', '==', PRODUCT[appId])));
      const ok = [];
      const deny = [];
      for (const appId of [RD, COC]) {
        const [mine, theirs, fresh] = IDS[appId];
        ok.push(
          [`${appId}: guest creates their application (ScopedCollection.add)`, () => setDoc(doc(apps, fresh), { ...application(appId, GUEST), ...audit(GUEST) })],
          [`${appId}: guest lists their applications (creatorId ==)`, () => listApplications(appId)],
          [`${appId}: guest opens their application`, () => getDoc(doc(apps, mine))],
          [`${appId}: guest saves coverage choices`, () => updateDoc(doc(apps, mine), { ...{ coverageConfirmedAt: 1, policyEmail: 'g@x.example' }, ...audit(GUEST) })],
          [`${appId}: guest requests a quote`, () => updateDoc(doc(apps, mine), { ...{ status: 'quoted', quoteEmailedAt: 1 }, ...audit(GUEST) })],
          [`${appId}: guest links a saved revision`, () => updateDoc(doc(apps, mine), { ...{ latestDraftRevisionId: fresh }, ...audit(GUEST) })],
          [`${appId}: guest records their application's edit history`, () => setDoc(doc(db, `insurance_applications/${mine}/edit_history/h1`),
            { ...stamp(appId, GUEST), fieldKey: 'status', newValue: 'cancelled' })],
          [`${appId}: guest reads their edit history`, () => getDocs(collection(db, `insurance_applications/${mine}/edit_history`))],
          [`${appId}: guest cancels their application`, () => updateDoc(doc(apps, mine), { ...{ status: 'cancelled', closedBy: GUEST }, ...audit(GUEST) })],
          // auditTrail: ScopedCollection stamps the writer and the server's time.
          [`${appId}: guest saves with an honest audit stamp`, () => updateDoc(doc(apps, mine),
            { coverageConfirmedAt: 2, lastModifiedBy: GUEST, lastModifiedAt: serverTimestamp() })],
        );
        deny.push(
          [`${appId}: guest lists by userId (the old shape: needs every applicant's docs)`, () => listApplications(appId, 'userId')],
          [`${appId}: guest lists every application (production's externalCollections scope)`, () => getDocs(query(apps,
            where('groupId', '==', G), where('appId', '==', appId)))],
          [`${appId}: guest lists another applicant's applications`, () => listApplications(appId, 'creatorId', OTHER_GUEST)],
          [`${appId}: guest opens another applicant's application`, () => getDoc(doc(apps, theirs))],
          [`${appId}: guest edits another applicant's application`, () => updateDoc(doc(apps, theirs), { status: 'cancelled', ...audit(GUEST) })],
          [`${appId}: guest writes another applicant's edit history`, () => setDoc(doc(db, `insurance_applications/${theirs}/edit_history/h2`),
            { ...stamp(appId, GUEST), fieldKey: 'status' })],
          [`${appId}: guest creates an application in someone else's name`, () => setDoc(doc(apps, `${fresh.slice(0, 19)}X`),
            { ...application(appId, OTHER_GUEST), ...audit(GUEST) })],
          [`${appId}: guest puts their own policy in force (staff only)`, () => updateDoc(doc(apps, mine), { ...{ status: 'active' }, ...audit(GUEST) })],
          [`${appId}: guest sets a staff-only field`, () => updateDoc(doc(apps, mine), { ...{ policyNumber: 'P-9' }, ...audit(GUEST) })],
          [`${appId}: guest saves without the audit stamp`, () => updateDoc(doc(apps, mine), { coverageConfirmedAt: 5 })],
          [`${appId}: guest stamps someone else as the writer`, () => updateDoc(doc(apps, mine),
            { coverageConfirmedAt: 3, lastModifiedBy: OTHER_GUEST, lastModifiedAt: serverTimestamp() })],
          [`${appId}: guest backdates the audit stamp`, () => updateDoc(doc(apps, mine),
            { coverageConfirmedAt: 4, lastModifiedBy: GUEST, lastModifiedAt: Timestamp.fromMillis(1) })],
          [`${appId}: guest creates an application stamped as someone else`, () => setDoc(doc(apps, `${fresh.slice(0, 19)}Y`),
            { ...application(appId, GUEST), lastModifiedBy: OTHER_GUEST, lastModifiedAt: serverTimestamp() })],
          // The bordereau ledger is server-written (insuranceRecordTransaction).
          [`${appId}: guest writes a ledger row on their own application`, () => setDoc(doc(db, `insurance_applications/${mine}/transactions/t1`),
            { ...stamp(appId, GUEST), transactionType: 'cancellation', premiumCents: 0, brokerageCommissionCents: 99999 })],
        );
      }
      ok.push(
        // The forms' config, shared with guests (guestShareable + externalCollections).
        ['coc: guest reads the group\'s form config', () => getDoc(doc(db, `insurance_coc_config/${G}`))],
        ['rd: guest probes the group\'s missing form config (singleton id)', () => getDoc(doc(db, `rented_dwelling_config/${G}`))],
        // AddressCacheService: tagged keys; the guest's own entry and a cache miss.
        ['rd: guest caches a property lookup (tagged id)', () => setDoc(doc(db, `property_data_cache/${G}__${RD}_2_main_st`),
          { ...stamp(RD, GUEST), winnipegData: {}, ...audit(GUEST) })],
        ['rd: guest probes a missing cache entry', () => getDoc(doc(db, `property_data_cache/${G}__${RD}_3_main_st`))],
        // policy_document_generator.dart and the dashboards: the group, by id.
        ['guest reads their group by id (memberIds)', () => getDoc(doc(db, `groups/${G}`))],
        ['launcher: guest lists their groups (memberIds array-contains)', () => getDocs(query(collection(db, 'groups'),
          where('memberIds', 'array-contains', GUEST)))],
        ['launcher: guest updates their profile', () => setDoc(doc(db, `users/${GUEST}`), { lastActive: 1 }, { merge: true })],
        ['launcher: guest reads their access index', () => getDoc(doc(db, `users/${GUEST}/metadata/access_index`))],
        ['launcher: guest lists their notifications', () => getDocs(query(collection(db, 'notifications'),
          where('recipientId', '==', GUEST), where('isRead', '==', false)))],
        ['naic: guest clears their confirmed identity (users doc)', () => updateDoc(doc(db, `users/${GUEST}`), { guestEmail: null })],
        // NAIC Sight (corporate; the guest is attested).
        ['naic: guest queues a job (ScopedCollection.set, UUID)', () => setDoc(doc(db, `naic_sight_jobs/${NEW_JOB}`), job(GUEST))],
        ['naic: guest lists their jobs (creatorId ==, newest first)', () => getDocs(query(collection(db, 'naic_sight_jobs'),
          where('groupId', '==', G), where('creatorId', '==', GUEST), orderBy('createdAt', 'desc')))],
        ['naic: guest deletes their finished job', () => deleteDoc(doc(db, `naic_sight_jobs/${JOB}`))],
        // Warehouse Uploader: the pipeline writes the upload; the uploader reads their own.
        ['uploader: guest watches their uploads (creatorId ==)', () => getDocs(query(collection(db, 'warehouse_uploads'),
          where('groupId', '==', G), where('creatorId', '==', GUEST), orderBy('createdAt', 'desc'), limit(50)))],
        ['uploader: guest watches one of their uploads', () => getDoc(doc(db, 'warehouse_uploads/up-guest'))],
        // A guest the corporate app hasn't admitted still uses the public apps.
        ['rd: unattested guest creates an application (public app)', () => setDoc(doc(noId, 'insurance_applications/GuestRdGuestRdNoId01'),
          { ...application(RD, UNATTESTED), ...audit(UNATTESTED) })],
      );
      deny.push(
        ['rd: guest reads someone else\'s cached lookup', () => getDoc(doc(db, `property_data_cache/${G}__${RD}_1_main_st`))],
        ['rd: guest overwrites someone else\'s cached lookup', () => setDoc(doc(db, `property_data_cache/${G}__${RD}_1_main_st`),
          { ...stamp(RD, GUEST), winnipegData: { x: 1 }, ...audit(GUEST) })],
        ['coc: guest writes the form config', () => setDoc(doc(db, `insurance_coc_config/${G}`), { ...stamp(COC, GUEST), flowMode: 'quote_or_payment' })],
        ['naic: guest lists by userId (the old shape)', () => getDocs(query(collection(db, 'naic_sight_jobs'),
          where('groupId', '==', G), where('userId', '==', GUEST), orderBy('createdAt', 'desc')))],
        ['naic: guest opens another guest\'s job', () => getDoc(doc(db, `naic_sight_jobs/${OTHER_JOB}`))],
        ['naic: guest deletes another guest\'s job', () => deleteDoc(doc(db, `naic_sight_jobs/${OTHER_JOB}`))],
        // blockUpdate: a job can't be repointed or re-fired after it's created.
        ['naic: guest repoints their job at another user', () => updateDoc(doc(db, `naic_sight_jobs/${JOB}`), { userId: OTHER_GUEST })],
        ['naic: guest re-fires completion', () => updateDoc(doc(db, `naic_sight_jobs/${JOB}`), { status: 'assembling' })],
        ['naic: guest queues a job with a forged result address', () => setDoc(doc(db, `naic_sight_jobs/1c9e3b4d-2e5f-4a6b-9c7d-8e9f0a1b2c34`),
          { ...job(GUEST), resultEmailedTo: 'ceo@victim.example' })],
        ['naic: unattested guest queues a job (corporate app, not admitted)', () => setDoc(doc(noId, `naic_sight_jobs/${UNADMITTED_JOB}`),
          job(UNATTESTED))],
        ['uploader: guest opens another uploader\'s upload', () => getDoc(doc(db, 'warehouse_uploads/up-other'))],
        ['uploader: guest lists every upload in the group', () => getDocs(query(collection(db, 'warehouse_uploads'), where('groupId', '==', G)))],
        ['uploader: guest changes their upload (pipeline only)', () => updateDoc(doc(db, 'warehouse_uploads/up-guest'), { status: 'committed' })],
        // The group directory (memberRead excludes guests).
        ['directory: guest lists the group\'s members', () => getDocs(query(collection(db, 'group_members'), where('groupId', '==', G)))],
        ['directory: guest opens a member\'s directory entry', () => getDoc(doc(db, `group_members/${G}__${MEMBER}`))],
        ['directory: guest lists the group\'s memberships', () => getDocs(query(collection(db, 'memberships'), where('groupId', '==', G)))],
        ['directory: guest lists the group\'s invitations', () => getDocs(query(collection(db, 'invitations'), where('groupId', '==', G)))],
        ['directory: guest looks the group up by groupId (the old dashboard shape)', () => getDocs(query(collection(db, 'groups'),
          where('groupId', '==', G), limit(1)))],
        ['directory: guest reads another user\'s profile', () => getDoc(doc(db, `users/${MEMBER}`))],
        ['guest reads the corporate access config', () => getDoc(doc(db, `corporate_access_configs/${G}__naic-sight`))],
        ['guest lists the group\'s guest attestations', () => getDocs(query(collection(db, 'guest_identities'), where('groupSlug', '==', G)))],
        // The audit trail: server-written, read by the audited app's :admin tier.
        ['guest reads the group\'s audit trail', () => getDocs(query(collection(db, 'audit_events'), where('groupId', '==', G),
          where('appId', '==', RD)))],
        ['guest writes an audit event', () => setDoc(doc(db, 'audit_events/e1'), { ...stamp(RD, GUEST), operation: 'update' })],
        // Usage Meter counters are a member grant (memberWrite), never a guest's (D1).
        ['usage: guest creates their own counter', () => setDoc(doc(db, `usage_daily/2026-11-06_${G}_${GUEST}`),
          { date: '2026-11-06', ...stamp('usage-meter', GUEST), uid: GUEST, apps: {} })],
      );
      const fails = [];
      for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
      for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
      await releaseTestEnv(env);
      console.log(`stage 5 (${variant}): ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
      fails.forEach((f) => console.log('FAILCASE ' + f));
      if (fails.length) throw new Error(fails.join('\n'));
    });
  }
}

// Self-keyed ballots (Polls' votes/{uid}): an ordinary member of a group whose
// app has sharedEditing false holds only the base scope, so they cannot edit
// someone else's poll, but they cast and change their own vote under it.
// A ballot is only ever its voter's: the poll's creator and the app's editors
// (who may edit the poll itself) can't write or delete anyone else's, and
// nobody votes on a soft-deleted poll.
{
  const test = require('node:test');
  const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs, query, where, orderBy, serverTimestamp } = require('firebase/firestore');
  const gen = require('../../generate');

  const G = 'g1', VOTER = 'voter', AUTHOR = 'author', GUEST = 'guest', OUTSIDER = 'outsider', EDITOR = 'editor';
  const base = { status: 'ACTIVE', roles: [], groups: [G], guest_groups: [], denied_scopes: [], clearance_level: 0 };
  const tenant = (creatorId) => ({ groupId: G, appId: 'polls', creatorId, ownerIds: [creatorId] });
  // What PollDetailScreen._castVote sends through ScopedCollection.set on a create.
  const ballot = (uid, extra) => ({ ...tenant(uid), userId: uid, votedAt: serverTimestamp(), ...extra });

  // Polls are ownerScoped with ownerIds = the participants, and
  // restrictEditToCreator: participants read and vote, only the creator
  // edits, and a member who isn't a participant reaches nothing.
  test('polls: participants vote on polls they did not create', async () => {
    const env = await openTestEnv({
      projectId: 'demo-bluejay-polls',
      firestore: { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') },
    });
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `users/${VOTER}/metadata/access_index`), { ...base, entitlements: [`${G}:polls`] });
      await setDoc(doc(db, `users/${AUTHOR}/metadata/access_index`), { ...base, entitlements: [`${G}:polls`] });
      await setDoc(doc(db, `users/${GUEST}/metadata/access_index`), { ...base, guest_groups: [G], entitlements: [`${G}:notes:guest`] });
      await setDoc(doc(db, `users/${OUTSIDER}/metadata/access_index`), { ...base, groups: ['g2'], entitlements: ['g2:polls'] });
      await setDoc(doc(db, `users/${EDITOR}/metadata/access_index`), { ...base, entitlements: [`${G}:polls`, `${G}:polls:edit`] });
      const participants = { ...tenant(AUTHOR), ownerIds: [AUTHOR, VOTER], participantIds: [AUTHOR, VOTER] };
      await setDoc(doc(db, 'polls/gone'), { ...participants, title: 'Old', type: 'yes_no', deletedAt: 1 });
      for (const id of ['p1', 'p2', 'p3', 'p4']) {
        await setDoc(doc(db, `polls/${id}`), { ...participants, title: 'Lunch?', type: 'yes_no' });
      }
      await setDoc(doc(db, `polls/p1/votes/${AUTHOR}`), { ...tenant(AUTHOR), userId: AUTHOR, choiceId: 'yes', votedAt: 1 });
      await setDoc(doc(db, `polls/p2/votes/${VOTER}`), { ...tenant(VOTER), userId: VOTER, choiceId: 'yes', votedAt: 1 });
    });
    const db = env.authenticatedContext(VOTER).firestore();
    const authorDb = env.authenticatedContext(AUTHOR).firestore();
    const editorDb = env.authenticatedContext(EDITOR).firestore();
    const ok = [
      ['participant reads the poll', () => getDoc(doc(db, 'polls/p1'))],
      ['participant lists the polls (queryOwned)', () => getDocs(query(collection(db, 'polls'), where('groupId', '==', G),
        where('ownerIds', 'array-contains', VOTER), orderBy('createdAt', 'desc')))],
      ['creator closes their poll', () => updateDoc(doc(authorDb, 'polls/p4'), { closedAt: serverTimestamp() })],
      ['participant reads their own ballot by id (PollDetailScreen)', () => getDoc(doc(db, `polls/p2/votes/${VOTER}`))],
      ['member casts their own vote', () => setDoc(doc(db, `polls/p1/votes/${VOTER}`), ballot(VOTER, { choiceId: 'no' }))],
      ['member changes their own vote (full set keeps the identity)', () => setDoc(doc(db, `polls/p2/votes/${VOTER}`),
        { ...tenant(VOTER), userId: VOTER, choiceId: 'no', votedAt: serverTimestamp() })],
      ['member casts a ranked ballot', () => setDoc(doc(db, `polls/p3/votes/${VOTER}`), ballot(VOTER, { ranking: ['a', 'b'] }))],
      ['creator votes on their own poll', () => setDoc(doc(authorDb, `polls/p3/votes/${AUTHOR}`), ballot(AUTHOR, { choiceId: 'yes' }))],
    ];
    const deny = [
      ['participant lists the ballots (selfRead)', () => getDocs(collection(db, 'polls/p1/votes'))],
      ['participant reads another participant\'s ballot', () => getDoc(doc(db, `polls/p1/votes/${AUTHOR}`))],
      ['member edits someone else\'s poll', () => updateDoc(doc(db, 'polls/p1'), { title: 'Dinner?' })],
      ['member closes someone else\'s poll', () => updateDoc(doc(db, 'polls/p1'), { closedAt: serverTimestamp() })],
      ['member deletes someone else\'s poll', () => deleteDoc(doc(db, 'polls/p1'))],
      ['member overwrites another voter\'s ballot', () => updateDoc(doc(db, `polls/p1/votes/${AUTHOR}`), { choiceId: 'no' })],
      ['member casts a ballot under another uid', () => setDoc(doc(db, `polls/p3/votes/${AUTHOR}`), ballot(AUTHOR, { choiceId: 'no' }))],
      ['member\'s own ballot naming another userId', () => setDoc(doc(db, `polls/p4/votes/${VOTER}`), ballot(VOTER, { userId: AUTHOR, choiceId: 'no' }))],
      ['member\'s ballot with an undeclared field', () => setDoc(doc(db, `polls/p4/votes/${VOTER}`), ballot(VOTER, { choiceId: 'a', weight: 10 }))],
      ['member deletes their own ballot', () => deleteDoc(doc(db, `polls/p2/votes/${VOTER}`))],
      ['editor who isn\'t a participant reads the poll', () => getDoc(doc(editorDb, 'polls/p1'))],
      ['editor who isn\'t a participant reads the votes', () => getDocs(collection(editorDb, 'polls/p1/votes'))],
      ['editor who isn\'t a participant votes', () => setDoc(doc(editorDb, `polls/p1/votes/${EDITOR}`), ballot(EDITOR, { choiceId: 'yes' }))],
      ['editor who isn\'t a participant closes the poll', () => updateDoc(doc(editorDb, 'polls/p1'), { closedAt: serverTimestamp() })],
      ['polls list by participantIds', () => getDocs(query(collection(db, 'polls'), where('groupId', '==', G), where('participantIds', 'array-contains', VOTER)))],
      ['guest casts a ballot', () => setDoc(doc(env.authenticatedContext(GUEST).firestore(), `polls/p1/votes/${GUEST}`), ballot(GUEST, { choiceId: 'yes' }))],
      ['another group\'s member casts a ballot', () => setDoc(doc(env.authenticatedContext(OUTSIDER).firestore(), `polls/p1/votes/${OUTSIDER}`),
        ballot(OUTSIDER, { choiceId: 'yes' }))],
      // The poll's creator and an editor can edit the poll, never the ballots.
      ['creator writes a ballot for a member', () => setDoc(doc(authorDb, `polls/p4/votes/${VOTER}`), ballot(VOTER, { choiceId: 'yes' }))],
      ['creator writes a ballot under a made-up id', () => setDoc(doc(authorDb, 'polls/p4/votes/fake123'), ballot('fake123', { choiceId: 'yes' }))],
      ['creator changes a member\'s ballot', () => updateDoc(doc(authorDb, `polls/p2/votes/${VOTER}`), { choiceId: 'no' })],
      ['creator deletes a member\'s ballot', () => deleteDoc(doc(authorDb, `polls/p2/votes/${VOTER}`))],
      ['creator deletes their own ballot', () => deleteDoc(doc(authorDb, `polls/p1/votes/${AUTHOR}`))],
      ['editor writes a ballot for a member', () => setDoc(doc(editorDb, `polls/p4/votes/${VOTER}`), ballot(VOTER, { choiceId: 'yes' }))],
      ['editor changes a member\'s ballot', () => updateDoc(doc(editorDb, `polls/p2/votes/${VOTER}`), { choiceId: 'no' })],
      ['editor deletes a member\'s ballot', () => deleteDoc(doc(editorDb, `polls/p2/votes/${VOTER}`))],
      ['member\'s own ballot naming another creatorId', () => setDoc(doc(db, `polls/p4/votes/${VOTER}`), { ...ballot(VOTER, { choiceId: 'a' }), creatorId: AUTHOR })],
      ['member\'s own ballot sharing ownerIds', () => setDoc(doc(db, `polls/p4/votes/${VOTER}`), { ...ballot(VOTER, { choiceId: 'a' }), ownerIds: [VOTER, AUTHOR] })],
      ['member re-assigns their own ballot to another uid', () => updateDoc(doc(db, `polls/p2/votes/${VOTER}`), { userId: AUTHOR })],
      ['member votes on a soft-deleted poll', () => setDoc(doc(db, `polls/gone/votes/${VOTER}`), ballot(VOTER, { choiceId: 'yes' }))],
    ];
    const fails = [];
    for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
    for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
    await releaseTestEnv(env);
    console.log(`polls: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
    fails.forEach((f) => console.log('FAILCASE ' + f));
    if (fails.length) throw new Error(fails.join('\n'));
  });
}

// Record search (plans/record-search/OVERVIEW.md §5): the launcher's search
// queries, one per record type, run as the signed-in member. searchPrefixes
// is a server field: only the audit trail's trigger writes it.
{
  const test = require('node:test');
  const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
  const { openTestEnv, releaseTestEnv } = require('../lib/test_env');
  const { doc, setDoc, updateDoc, collection, query, where, limit, getDocs, serverTimestamp } = require('firebase/firestore');

  const G = 'g1', U = 'u1', OTHER = 'u2', OUTSIDER = 'u3';
  const APPS = ['contacts', 'crm', 'invoices', 'inventory', 'help-desk'];
  const index = (uid, groups, apps) => ({
    status: 'ACTIVE', roles: [], groups, guest_groups: [], denied_scopes: [], clearance_level: 0,
    entitlements: groups.flatMap((g) => apps.flatMap((a) => [`${g}:${a}`, `${g}:${a}:edit`])),
  });
  const P = ['ad', 'ada'];
  const record = (appId, extra = {}) => ({ groupId: G, appId, creatorId: OTHER, ownerIds: [OTHER], searchPrefixes: P, ...extra });

  test('record search: query shapes and the server-only field', async () => {
    const env = await openTestEnv({ projectId: 'demo-bluejay-record-search', firestore: { rules: require('fs').readFileSync(require('path').join(__dirname, '../../../firestore.rules'), 'utf8') } });
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await setDoc(doc(db, `users/${U}/metadata/access_index`), index(U, [G], APPS));
      await setDoc(doc(db, `users/${OUTSIDER}/metadata/access_index`), index(OUTSIDER, ['g2'], APPS));
      await setDoc(doc(db, 'contacts/c1'), record('contacts', { name: 'Ada' }));
      await setDoc(doc(db, 'personal_contacts/p1'), record('contacts', { name: 'Ada', creatorId: U, ownerIds: [U] }));
      await setDoc(doc(db, 'personal_contacts/p2'), record('contacts', { name: 'Ada' }));
      await setDoc(doc(db, 'crm_deals/d1'), record('crm', { title: 'Ada' }));
      await setDoc(doc(db, 'invoicing_documents/i1'), record('invoices', { kind: 'invoice', status: 'issued' }));
      await setDoc(doc(db, 'inventory_items/s1'), record('inventory', { name: 'Ada' }));
      await setDoc(doc(db, 'help_tickets/t1'), { groupId: G, requesterUid: U, searchPrefixes: P });
    });
    const db = env.authenticatedContext(U).firestore();
    const outsider = env.authenticatedContext(OUTSIDER).firestore();
    const search = (d, name, ...filters) => getDocs(query(collection(d, name), where('groupId', '==', G), ...filters, where('searchPrefixes', 'array-contains', 'ada'), limit(8)));
    const ok = [
      ['contacts search', () => search(db, 'contacts')],
      ['own personal contacts search (creatorId ==)', () => search(db, 'personal_contacts', where('creatorId', '==', U))],
      ['deals search', () => search(db, 'crm_deals')],
      ['invoices search', () => search(db, 'invoicing_documents')],
      ['inventory search', () => search(db, 'inventory_items')],
    ];
    const deny = [
      ['personal contacts search without the owner filter', () => search(db, 'personal_contacts')],
      ['another group\'s member searches contacts', () => search(outsider, 'contacts')],
      ['help tickets queried from the client', () => search(db, 'help_tickets', where('requesterUid', '==', U))],
      ['member writes searchPrefixes', () => updateDoc(doc(db, 'contacts/c1'), { searchPrefixes: ['x'], lastModifiedBy: U, lastModifiedAt: serverTimestamp() })],
      ['member creates a contact with searchPrefixes', () => setDoc(doc(db, 'contacts/c2'), { ...record('contacts'), creatorId: U, ownerIds: [U], lastModifiedBy: U, lastModifiedAt: serverTimestamp() })],
      ['owner writes searchPrefixes on a personal contact', () => updateDoc(doc(db, 'personal_contacts/p1'), { searchPrefixes: [], lastModifiedBy: U, lastModifiedAt: serverTimestamp() })],
    ];
    const fails = [];
    for (const [n, f] of ok) await assertSucceeds(f()).catch((e) => fails.push(`ALLOW expected: ${n}: ${String(e.message || e).replace(/\s+/g, ' ').slice(0, 400)}`));
    for (const [n, f] of deny) await assertFails(f()).catch(() => fails.push(`DENY expected: ${n}`));
    await releaseTestEnv(env);
    console.log(`record search: ${ok.length + deny.length - fails.length}/${ok.length + deny.length} as expected`);
    fails.forEach((f) => console.log('FAILCASE ' + f));
    if (fails.length) throw new Error(fails.join('\n'));
  });
}
