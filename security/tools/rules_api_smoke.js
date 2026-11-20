#!/usr/bin/env node
/**
 * Smoke-tests firestore.rules through the Firebase Rules API's `test` method
 * (the production rules engine), with a mocked access index. Nothing is
 * deployed and no ruleset is created; production is only read (the released
 * ruleset's name and source).
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=... node security/tools/rules_api_smoke.js [rules file]
 *
 * 1. RELEASED: reports whether the released cloud.firestore ruleset equals
 *    the committed rules (it differs between a merge and its deploy).
 * 2. CASES: the committed rules on representative cases, including the
 *    grants the 2025-12-16 permissive release made and the rules no longer
 *    do (any depth, signed-out invitations, no access index).
 * 3. EVERY COLLECTION: for every collection security/collections.json
 *    declares, a create by a member of another group (DENY) and, except for
 *    the kinds any signed-in user reads, that member's get (DENY).
 *
 * Needs credentials allowed to call firebaserules on bluejay-d926f (the
 * scripts/firestore_admin service account works), so it isn't part of CI.
 * It catches what static tests can't: compile errors, and requests that fail
 * Firestore's 1000-expression-per-request limit (every ordinary write did
 * until the generated table was split into buckets). The emulator suite in
 * security/rules-tests (plan T2) now covers these cases and many more in CI
 * (test/cost.test.js holds these same cases); this tool remains a way to
 * confirm a ruleset against the production rules engine itself.
 *
 * Uses google-auth-library from functions/node_modules (run `npm ci` there).
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const { GoogleAuth } = require(path.join(ROOT, 'functions', 'node_modules', 'google-auth-library'));

const gen = require(path.join(ROOT, 'security', 'generate.js'));

const PROJECT = 'bluejay-d926f';
const DOC_ID = 'AbCdEfGhIjKlMnOpQrSt'; // an auto-id-shaped id (the enforced rules check id formats on create)
const UID = 'u1';
const ACCESS_INDEX = {
  status: 'ACTIVE', roles: [], groups: ['g1'], denied_scopes: [], clearance_level: 0,
  entitlements: ['g1:notes', 'g1:notes:edit', 'g1:billing', 'g1:usage-meter', 'g1:habit-tracker',
    'g1:marketplace-admin', 'g1:warehouse-imports', 'g1:merchant-portal', 'g1:rented-dwelling',
    'g1:event-planner', 'g1:event-planner:edit', 'g1:trivia-night', 'g1:users', 'g1:language-learner'],
};
const OTHER_GROUP_INDEX = { ...ACCESS_INDEX, groups: ['g2'], entitlements: ACCESS_INDEX.entitlements.map((e) => e.replace('g1:', 'g2:')) };
const GUEST_INDEX = { ...ACCESS_INDEX, guest_groups: ['g1'], entitlements: ['g1:rented-dwelling:guest'] };
const SUSPENDED_ADMIN_INDEX = { ...ACCESS_INDEX, roles: ['admin'], status: 'SUSPENDED' };
const STAFF_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:policy-editor', 'g1:policy-editor:edit'] };
const CE_EDITOR_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:continuing-education', 'g1:continuing-education:edit'] };
const CE_MEMBER_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:continuing-education'] };
const own = (appId, extra = {}) => ({ groupId: 'g1', appId, creatorId: UID, ownerIds: [UID], title: 'x', ...extra });
const ADMIN_INDEX = { ...ACCESS_INDEX, roles: ['admin'] };
const APP_MAKER_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:app-maker', 'g1:app-maker:edit'] };
// AppRequest.toMap()'s shape; the review state (status, decline fields, builtAppId, shippedAt) is serverFields.
const appRequest = (extra = {}) => own('app-maker', { summary: '', attachments: [], ...extra });
/** The case's request time (testCase); the audit stamp a client write to an auditTrail collection carries. */
const REQUEST_TIME = '2026-11-05T00:00:00Z';
const STAMP = { lastModifiedBy: UID, lastModifiedAt: REQUEST_TIME };
const DEVELOPER_INDEX = { ...ACCESS_INDEX, roles: ['developer'] };
// A bug filed in a group the caller isn't in, as the parent of a comment case.
const TICKET_PARENT = {
  path: `bug_reports/${DOC_ID}`,
  data: { groupId: 'g9', appId: 'improve-apps', creatorId: 'u2', reporterId: 'u2', description: 'x' },
};
// A bug the caller filed in their own group (they hold improve-apps :edit).
const OWN_TICKET = {
  path: `bug_reports/${DOC_ID}`,
  data: { groupId: 'g1', appId: 'improve-apps', creatorId: UID, ownerIds: [UID], reporterId: UID, description: 'x' },
};
const IMPROVE_EDITOR_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:improve-apps', 'g1:improve-apps:edit'] };
// Rules plan T7: memberships, invitations and the groups access fields are server-written.
const myMembership = { groupId: 'g1', userId: UID, role: 'member', creatorId: UID };
const invitation = { ...own('users'), email: 'zed@bluejay.gg', role: 'member', status: 'pending', invitedBy: UID };
// An audit_events entry for a membership change, recorded under the Users app (auditAppId).
const membershipEvent = { groupId: 'g1', appId: 'users', collection: 'memberships', docId: `g1_${UID}`, operation: 'update', actorUid: 'u2' };
const USERS_ADMIN_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:users', 'g1:users:admin'] };
const USERS_EDITOR_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:users', 'g1:users:edit'] };
// A billing_events entry on the audit trail: recorded under Billing (the collection's one app), whatever app raised the charge.
const billingEvent = { groupId: 'g1', appId: 'billing', collection: 'billing_events', docId: 'fee1', operation: 'create', actorUid: 'u2' };
const BILLING_ADMIN_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:billing', 'g1:billing:admin'] };
const SOURCE_APP_ADMIN_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:group-admin', 'g1:group-admin:admin'] };
const group = {
  groupId: 'g1', name: 'G1', memberIds: [UID], adminIds: [UID], installedApps: ['notes'], isFrozen: false,
  creatorId: UID, createdBy: UID,
};
const otherHost = { creatorId: 'u2', hostId: 'u2', ownerIds: ['u2', UID], memberIds: ['u2', UID] };
const inbox = (recipientId) => ({ groupId: 'g1', appId: 'notes', recipientId, title: 'x', body: 'y', isRead: false });
const directory = { groupId: 'g1', uid: 'u2', displayName: 'U2', role: 'member' };
const profile = (uid) => ({ uid, displayName: 'Me', roles: [], status: 'ACTIVE' });

// Polls: a poll someone else created with the caller as a participant
// (ownerIds = participantIds, ownerScoped), and a member holding only the base
// scope (sharedEditing false), who votes through the self-keyed votes/{uid} subcollection.
const POLL_PARENT = { path: `polls/${DOC_ID}`, data: { groupId: 'g1', appId: 'polls', creatorId: 'u2', ownerIds: ['u2', UID], participantIds: ['u2', UID], title: 'x' } };
const POLLS_MEMBER_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:polls'] };
const POLLS_EDITOR_INDEX = { ...POLLS_MEMBER_INDEX, entitlements: [...POLLS_MEMBER_INDEX.entitlements, 'g1:polls:edit'] };
// A poll the caller created: they hold edit rights on it at the base tier.
const MY_POLL = { path: `polls/${DOC_ID}`, data: { groupId: 'g1', appId: 'polls', creatorId: UID, ownerIds: [UID], title: 'x' } };
const CALENDAR_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:calendar'] };
const MY_EVENT = { path: `calendar_events/${DOC_ID}`, data: { groupId: 'g1', appId: 'calendar', creatorId: UID, ownerIds: [UID], title: 'x' } };
const invitee = (uid) => ({ groupId: 'g1', appId: 'calendar', creatorId: UID, ownerIds: [UID], uid, status: 'invited', respondedAt: null });
const ballot = (uid, extra = {}) => ({ groupId: 'g1', appId: 'polls', creatorId: uid, ownerIds: [uid], userId: uid, votedAt: 1, ...extra });

// Improve Apps: a member with only the base scope (sharedEditing false),
// another member's idea and their own, and a vote on the self-keyed votes/{uid}.
const IMPROVE_MEMBER_INDEX = { ...ACCESS_INDEX, entitlements: [...ACCESS_INDEX.entitlements, 'g1:improve-apps'] };
const IDEA_PARENT = {
  path: `feature_requests/${DOC_ID}`,
  data: { groupId: 'g1', appId: 'improve-apps', creatorId: 'u2', ownerIds: ['u2'], requesterId: 'u2', title: 'x' },
};
const MY_IDEA = { groupId: 'g1', appId: 'improve-apps', creatorId: UID, ownerIds: [UID], requesterId: UID, title: 'x' };
const ticketVote = (uid, value) => ({ groupId: 'g1', appId: 'improve-apps', creatorId: uid, ownerIds: [uid], userId: uid, value, votedAt: 1 });

// [label, collection, method, expectation, stored doc, changes, caller's access index, doc id]
const CASES = [
  // The group's Users admins read the Users app's audit events; other tiers and groups don't.
  ['audit_events: Users admin reads a membership event', 'audit_events', 'get', 'ALLOW', membershipEvent, {}, USERS_ADMIN_INDEX],
  ['audit_events: Users editor reads a membership event', 'audit_events', 'get', 'DENY', membershipEvent, {}, USERS_EDITOR_INDEX],
  ['audit_events: another group\'s Users admin reads it', 'audit_events', 'get', 'DENY', { ...membershipEvent, groupId: 'g9' }, {}, USERS_ADMIN_INDEX],
  ['audit_events: Users admin writes one', 'audit_events', 'update', 'DENY', membershipEvent, { actorUid: UID }, USERS_ADMIN_INDEX],
  // Billing history is Billing's: its admins read it, the admins of the app that raised the charge don't.
  ['audit_events: Billing admin reads a billing_events entry', 'audit_events', 'get', 'ALLOW', billingEvent, {}, BILLING_ADMIN_INDEX],
  ['audit_events: source app admin reads a billing_events entry', 'audit_events', 'get', 'DENY', billingEvent, {}, SOURCE_APP_ADMIN_INDEX],
  // What the 2025-12-16 permissive release allowed and these rules don't.
  ['formerly open: deep subcollection delete', 'notes', 'delete', 'DENY', own('notes'), {}, ACCESS_INDEX, 'd1/a/b/c/d'],
  ['formerly open: no access index at all', 'notes', 'get', 'DENY', own('notes'), {}, null],
  ['formerly open: cross-tenant write', 'notes', 'update', 'DENY', { ...own('notes'), groupId: 'g9' }, { title: 'y' }],
  ['formerly open: access index write', 'users', 'update', 'DENY', ACCESS_INDEX, { roles: ['admin'] }, ACCESS_INDEX, `${UID}/metadata/access_index`],

  ['notes: read in own group', 'notes', 'get', 'ALLOW', own('notes')],
  ['notes: create own', 'notes', 'create', 'ALLOW', own('notes')],
  ['notes: create with a natural-key id', 'notes', 'create', 'DENY', own('notes'), {}, ACCESS_INDEX, 'my-note'],
  ['notes: create tagged with the group', 'notes', 'create', 'ALLOW', own('notes'), {}, ACCESS_INDEX, 'g1__k1'],
  ['notes: create tagged with another group', 'notes', 'create', 'DENY', own('notes'), {}, ACCESS_INDEX, 'g2__k1'],
  ['notes: another group reads', 'notes', 'get', 'DENY', own('notes'), {}, OTHER_GROUP_INDEX],
  ['notes: removed creator reads own (D1)', 'notes', 'get', 'DENY', own('notes'), {}, { ...ACCESS_INDEX, groups: [], entitlements: [] }],
  ['notes: public doc of another group (D2)', 'notes', 'get', 'DENY', own('notes', { visibility: 'public' }), {}, OTHER_GROUP_INDEX],
  ['notes: move to another group', 'notes', 'update', 'DENY', own('notes'), { groupId: 'g2' }],
  ['notes: update own', 'notes', 'update', 'ALLOW', own('notes'), { title: 'y' }],
  ['notes: delete own', 'notes', 'delete', 'ALLOW', own('notes')],
  ['unlisted collection: create own', 'zzz_unlisted', 'create', 'ALLOW', own('notes')],
  ['access_index_rebuilds (first bucket): create blocked', 'access_index_rebuilds', 'create', 'DENY', own('notes')],
  ['payment_orders (server): create blocked', 'payment_orders', 'create', 'DENY', own('billing')],
  ['merchantAccounts (capital letter): create blocked', 'merchantAccounts', 'create', 'DENY', own('merchant')],
  ['usage_daily: delete blocked', 'usage_daily', 'delete', 'DENY', own('usage-meter', { uid: UID, date: '2026-11-05' })],
  ['usage_daily: member without usage-meter creates own counter', 'usage_daily', 'create', 'ALLOW', own('usage-meter', { uid: UID, date: '2026-11-05' }), {},
    { ...ACCESS_INDEX, entitlements: ['g1:notes'] }, `2026-11-05_g1_${UID}`],
  ['usage_daily: member creates another\'s counter', 'usage_daily', 'create', 'DENY', own('usage-meter', { uid: 'u2', date: '2026-11-05' }), {},
    ACCESS_INDEX, '2026-11-05_g1_u2'],
  ['habits: single-owner create', 'habits', 'create', 'ALLOW', own('habit-tracker')],
  ['habits: co-owned create blocked', 'habits', 'create', 'DENY', own('habit-tracker', { ownerIds: [UID, 'u2'] })],
  ['vendor_market_listings: delete blocked', 'vendor_market_listings', 'delete', 'DENY', own('marketplace-admin')],
  ['warehouse_uploads (last bucket): create blocked', 'warehouse_uploads', 'create', 'DENY', own('warehouse')],
  // insurance_applications is on the audit trail: every client write must stamp lastModifiedAt
  // with the request time, which a Rules API test case (plain JSON data) can't express, so
  // these check the unstamped write is refused. The stamped allows, and their expression
  // headroom, are covered by security/rules-tests/test/cost.test.js.
  ['insurance: applicant edits a draft without the audit stamp', 'insurance_applications', 'update', 'DENY', own('rented-dwelling', { status: 'draft' }), { title: 'y' }],
  ['insurance: applicant sets policyNumber', 'insurance_applications', 'update', 'DENY', own('rented-dwelling', { status: 'draft' }), { policyNumber: 'P1' }],
  ['insurance: applicant activates', 'insurance_applications', 'update', 'DENY', own('rented-dwelling', { status: 'draft' }), { status: 'active' }],
  ['event planner: editor edits title', 'event_planner_events', 'update', 'ALLOW', own('event-planner', { creatorId: 'u2', ownerIds: ['u2'] }), { title: 'y' }],
  ['event planner: editor sets rsvpCounts', 'event_planner_events', 'update', 'DENY', own('event-planner', { creatorId: 'u2', ownerIds: ['u2'] }), { rsvpCounts: { yes: 9 } }],
  ['trivia: co-owner edits title', 'trivia_games', 'update', 'ALLOW', own('trivia-night', otherHost), { title: 'y' }],
  ['trivia: co-owner (not host) changes status', 'trivia_games', 'update', 'DENY', own('trivia-night', otherHost), { status: 'finished' }],
  ['insurance: staff activates without the audit stamp', 'insurance_applications', 'update', 'DENY', own('rented-dwelling', { status: 'draft' }), { status: 'active' }, STAFF_INDEX],
  ['group_members: member reads', 'group_members', 'get', 'ALLOW', directory, {}, ACCESS_INDEX, 'g1__u2'],
  ['group_members: guest reads', 'group_members', 'get', 'DENY', directory, {}, GUEST_INDEX, 'g1__u2'],
  ['group_members: other group reads', 'group_members', 'get', 'DENY', directory, {}, OTHER_GROUP_INDEX, 'g1__u2'],
  ['group_members: member writes', 'group_members', 'update', 'DENY', directory, { displayName: 'x' }, ACCESS_INDEX, 'g1__u2'],
  ['group_members: co-member lists the group', 'group_members', 'list', 'ALLOW', directory, {}, ACCESS_INDEX, 'g1__u2'],
  ['group_members: client create blocked', 'group_members', 'create', 'DENY', directory, {}, ACCESS_INDEX, 'g1__u2'],
  ['group_members: platform admin edit blocked', 'group_members', 'update', 'DENY', directory, { role: 'owner' }, ADMIN_INDEX, 'g1__u2'],
  ['group_members: delete blocked', 'group_members', 'delete', 'DENY', directory, {}, ADMIN_INDEX, 'g1__u2'],
  ['users: own lastActive', 'users', 'update', 'ALLOW', profile(UID), { lastActive: 1 }, ACCESS_INDEX, UID],
  ['users: self-grant admin', 'users', 'update', 'DENY', profile(UID), { roles: ['admin'] }, ACCESS_INDEX, UID],
  ['users: self-verify a contact', 'users', 'update', 'DENY', profile(UID), { contactVerification: { emailVerified: true } }, ACCESS_INDEX, UID],
  ['users: someone else\'s profile', 'users', 'get', 'DENY', profile('u2'), {}, ACCESS_INDEX, 'u2'],
  ['users: developer reads a profile', 'users', 'get', 'ALLOW', profile('u2'), {}, DEVELOPER_INDEX, 'u2'],
  ['categories: admin write blocked', 'categories', 'update', 'DENY', { name: 'c' }, { name: 'd' }, ADMIN_INDEX],
  ['script_runs: suspended admin reads', 'script_runs', 'get', 'DENY', { status: 'ok' }, {}, SUSPENDED_ADMIN_INDEX],
  ['script_runs: admin reads', 'script_runs', 'get', 'ALLOW', { status: 'ok' }, {}, ADMIN_INDEX],
  ['collection_catalog: member reads', 'collection_catalog', 'get', 'DENY', { docCount: 1 }],
  ['apps: developer sets allowedGroups', 'apps', 'update', 'DENY', { name: 'n' }, { allowedGroups: ['g9'] }, DEVELOPER_INDEX],
  ['apps: developer edits a description', 'apps', 'update', 'ALLOW', { name: 'n' }, { description: 'd' }, DEVELOPER_INDEX],
  ['ce_events: member creates', 'ce_events', 'create', 'DENY', own('continuing-education'), {}, CE_MEMBER_INDEX],
  ['ce_events: CE editor creates', 'ce_events', 'create', 'ALLOW', own('continuing-education'), {}, CE_EDITOR_INDEX],
  ['language learner: co-member reads another\'s', 'language_learner_messages', 'get', 'DENY', own('language-learner', { creatorId: 'u2', ownerIds: ['u2'] })],
  ['memberships: self-create as owner blocked', 'memberships', 'create', 'DENY', { ...myMembership, role: 'owner' }],
  ['memberships: self-promote blocked', 'memberships', 'update', 'DENY', myMembership, { role: 'owner' }],
  ['memberships: platform admin edit blocked', 'memberships', 'update', 'DENY', myMembership, { role: 'owner' }, ADMIN_INDEX],
  ['memberships: delete blocked', 'memberships', 'delete', 'DENY', myMembership, {}, ADMIN_INDEX],
  ['memberships: member reads own', 'memberships', 'get', 'ALLOW', myMembership],
  ['invitations: read in own group', 'invitations', 'get', 'ALLOW', invitation],
  ['invitations: create blocked', 'invitations', 'create', 'DENY', invitation],
  ['invitations: role change blocked', 'invitations', 'update', 'DENY', invitation, { role: 'owner' }],
  ['invitations: accept (status) blocked', 'invitations', 'update', 'DENY', invitation, { status: 'completed' }],
  ['invitations: platform admin delete blocked', 'invitations', 'delete', 'DENY', invitation, {}, ADMIN_INDEX],
  ['invitation_lookup_rate_limits: create blocked', 'invitation_lookup_rate_limits', 'create', 'DENY', own('users')],
  ['invitation_claim_tokens: create blocked', 'invitation_claim_tokens', 'create', 'DENY', own('users')],
  ['groups: member reads own group', 'groups', 'get', 'ALLOW', group, {}, ACCESS_INDEX, 'g1'],
  // groups is serverWritten: renames go through updateGroupDetails.
  ['groups: platform admin renames (callable only)', 'groups', 'update', 'DENY', group, { name: 'G2' }, ADMIN_INDEX],
  ['groups: suspended admin renames', 'groups', 'update', 'DENY', group, { name: 'G2' }, SUSPENDED_ADMIN_INDEX],
  ['groups: developer renames (callable only)', 'groups', 'update', 'DENY', group, { name: 'G2' }, DEVELOPER_INDEX],
  ['groups: platform admin adds a member', 'groups', 'update', 'DENY', group, { memberIds: [UID, 'u2'] }, ADMIN_INDEX],
  ['groups: platform admin sets adminIds', 'groups', 'update', 'DENY', group, { adminIds: [UID, 'u2'] }, ADMIN_INDEX],
  ['groups: developer sets installedApps', 'groups', 'update', 'DENY', group, { installedApps: ['notes', 'wiki'] }, DEVELOPER_INDEX],
  ['groups: developer freezes', 'groups', 'update', 'DENY', group, { isFrozen: true }, DEVELOPER_INDEX],
  ['groups: creator (no platform role) adds a member', 'groups', 'update', 'DENY', group, { memberIds: [UID, 'u2'] }],
  ['groups: platform admin creates with members', 'groups', 'create', 'DENY', group, {}, ADMIN_INDEX],
  // notifications (T8): sent only through notificationsSend; the recipient owns its read state.
  ['notifications: client create (own group, own app) blocked', 'notifications', 'create', 'DENY', { ...own('notes'), recipientId: 'u2', isRead: false }],
  ['notifications: recipient reads own', 'notifications', 'get', 'ALLOW', inbox(UID)],
  ['notifications: other user reads', 'notifications', 'get', 'DENY', inbox('u2')],
  ['notifications: recipient marks read', 'notifications', 'update', 'ALLOW', inbox(UID), { isRead: true }],
  ['notifications: recipient edits title', 'notifications', 'update', 'DENY', inbox(UID), { title: 'forged' }],
  ['notifications: recipient marks read + reassigns', 'notifications', 'update', 'DENY', inbox(UID), { isRead: true, recipientId: 'u2' }],
  ['notifications: other user marks read', 'notifications', 'update', 'DENY', inbox('u2'), { isRead: true }],
  ['notifications: recipient deletes own', 'notifications', 'delete', 'ALLOW', inbox(UID)],
  ['notifications: other user deletes', 'notifications', 'delete', 'DENY', inbox('u2')],
  // app_requests is on the audit trail. The Rules API compares a string with
  // request.time, so STAMP (ScopedCollection's lastModifiedBy/lastModifiedAt
  // at the case's request time) expresses a correctly stamped write. Every
  // DENY below is stamped unless the stamp is what it tests, so each fails
  // for one reason.
  ['app_requests: requester submits (stamped)', 'app_requests', 'create', 'ALLOW', appRequest(STAMP), {}, APP_MAKER_INDEX],
  ['app_requests: requester edits own content (stamped)', 'app_requests', 'update', 'ALLOW', appRequest({ status: 'building' }), { title: 'y', ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: requester submits without the audit stamp', 'app_requests', 'create', 'DENY', appRequest(), {}, APP_MAKER_INDEX],
  ['app_requests: requester submits stamped as someone else', 'app_requests', 'create', 'DENY', appRequest({ ...STAMP, lastModifiedBy: 'u2' }), {}, APP_MAKER_INDEX],
  ['app_requests: requester edits own content without the audit stamp', 'app_requests', 'update', 'DENY', appRequest({ status: 'building' }), { title: 'y' }, APP_MAKER_INDEX],
  ['app_requests: requester deletes own request', 'app_requests', 'delete', 'DENY', appRequest(STAMP), {}, APP_MAKER_INDEX],
  ['app_requests: requester sets deletedAt', 'app_requests', 'update', 'DENY', appRequest(), { deletedAt: 1, ...STAMP }, APP_MAKER_INDEX],
  // The generic soft-delete lock (softDeleteOk): a deleted request takes no edit, restore or comment.
  // (A live request's stamped comment needs auth.token, which these cases don't model; the
  // emulator suite's app_query_shapes covers it.)
  ['app_requests: requester edits own deleted request (stamped)', 'app_requests', 'update', 'DENY', appRequest({ deletedAt: 1, deletedBy: UID }), { title: 'y', ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: requester restores own deleted request (stamped)', 'app_requests', 'update', 'DENY', appRequest({ deletedAt: 1, deletedBy: UID }), { deletedAt: null, deletedBy: null, ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: requester comments on own deleted request', 'app_requests', 'create', 'DENY',
    { authorId: UID, text: 'x', groupId: 'g1', appId: 'app-maker', creatorId: UID, ownerIds: [UID], ...STAMP }, {}, APP_MAKER_INDEX,
    `${DOC_ID}/comments/c1`, false, { path: `app_requests/${DOC_ID}`, data: appRequest({ deletedAt: 1, deletedBy: UID }) }],
  ['app_requests: submit claiming a submitterEmail', 'app_requests', 'create', 'DENY', appRequest({ submitterEmail: 'boss@x.example', ...STAMP }), {}, APP_MAKER_INDEX],
  ['app_requests: requester sets submitterEmail', 'app_requests', 'update', 'DENY', appRequest(), { submitterEmail: 'boss@x.example', ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: submit with builtAppId', 'app_requests', 'create', 'DENY', appRequest({ builtAppId: 'notes', ...STAMP }), {}, APP_MAKER_INDEX],
  ['app_requests: submit with status', 'app_requests', 'create', 'DENY', appRequest({ status: 'new', ...STAMP }), {}, APP_MAKER_INDEX],
  ['app_requests: requester sets builtAppId', 'app_requests', 'update', 'DENY', appRequest(), { builtAppId: 'notes', ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: requester ships own request', 'app_requests', 'update', 'DENY', appRequest({ status: 'building' }), { status: 'shipped', ...STAMP }, APP_MAKER_INDEX],
  ['app_requests: requester sets declineNote', 'app_requests', 'update', 'DENY', appRequest(), { declineNote: 'x', ...STAMP }, APP_MAKER_INDEX],
  // restrictEditToCreator: an app:edit holder in the group can't edit someone else's request.
  ['app_requests: group editor edits a groupmate\'s request (stamped)', 'app_requests', 'update', 'DENY',
    appRequest({ creatorId: 'u2', ownerIds: ['u2'] }), { title: 'y', ...STAMP }, APP_MAKER_INDEX],
  // adminComments: platform admins and developers read and comment on any group's ticket, never edit it.
  ['app_requests: developer reads another group\'s request', 'app_requests', 'get', 'ALLOW', { ...appRequest(), groupId: 'g9' }, {}, DEVELOPER_INDEX],
  ['app_requests: developer edits another group\'s request (stamped)', 'app_requests', 'update', 'DENY', { ...appRequest(), groupId: 'g9' }, { title: 'y', ...STAMP }, DEVELOPER_INDEX],
  // Comment threads (commentThread) are on the audit trail, so, as for insurance above, only
  // the refusals are checkable here; the stamped allows are in security/rules-tests (cost.test.js,
  // app_query_shapes.test.js).
  ['bug_reports: developer comments without the audit stamp', 'bug_reports', 'create', 'DENY',
    { authorId: UID, text: 'Looking at it' }, {}, DEVELOPER_INDEX, `${DOC_ID}/comments/c1`, false, TICKET_PARENT],
  ['bug_reports: requester (parent editor) comments as a platform admin', 'bug_reports', 'create', 'DENY',
    { authorId: 'admin-uid', text: 'forged', lastModifiedBy: UID }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c2`, false, OWN_TICKET],
  ['bug_reports: author reassigns own comment', 'bug_reports', 'update', 'DENY',
    { authorId: UID, text: 'mine' }, { authorId: 'u2' }, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c1`, false, OWN_TICKET],
  ['bug_reports: comment filed under another group\'s tenant', 'bug_reports', 'create', 'DENY',
    { authorId: UID, text: 'x', groupId: 'g9', appId: 'improve-apps' }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c3`, false, OWN_TICKET],
  ['bug_reports: likes doc with more than 500 ids', 'bug_reports', 'create', 'DENY',
    { userId: UID, commentIds: Array.from({ length: 501 }, (_, i) => `c${i}`), groupId: 'g1', appId: 'improve-apps' }, {},
    IMPROVE_EDITOR_INDEX, `${DOC_ID}/comment_likes/${UID}`, false, OWN_TICKET],
  ['bug_reports: requester deletes a staff question', 'bug_reports', 'delete', 'DENY',
    { authorId: 'u2', text: 'q' }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c1`, false, OWN_TICKET],
  ['bug_reports: requester edits a staff question', 'bug_reports', 'update', 'DENY',
    { authorId: 'u2', text: 'q' }, { text: 'changed' }, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c1`, false, OWN_TICKET],
  ['bug_reports: author hard-deletes own comment', 'bug_reports', 'delete', 'DENY',
    { authorId: UID, text: 'mine' }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c1`, false, OWN_TICKET],
  ['bug_reports: editor likes by editing the comment', 'bug_reports', 'update', 'DENY',
    { authorId: 'u2', text: 'q', likedBy: [] }, { likedBy: [UID] }, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comments/c1`, false, OWN_TICKET],
  ['bug_reports: member likes without the audit stamp', 'bug_reports', 'create', 'DENY',
    { userId: UID, commentIds: ['c1'] }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comment_likes/${UID}`, false, OWN_TICKET],
  ['bug_reports: member deletes their likes doc', 'bug_reports', 'delete', 'DENY',
    { userId: UID, commentIds: ['c1'] }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comment_likes/${UID}`, false, OWN_TICKET],
  ['bug_reports: member reads the thread\'s likes', 'bug_reports', 'get', 'ALLOW',
    { userId: 'u2', commentIds: ['c1'] }, {}, IMPROVE_EDITOR_INDEX, `${DOC_ID}/comment_likes/u2`, false, OWN_TICKET],
  ['bug_reports: developer reads another group\'s comments', 'bug_reports', 'get', 'ALLOW',
    { authorId: 'u2', text: 'x' }, {}, DEVELOPER_INDEX, `${DOC_ID}/comments/c1`, false, TICKET_PARENT],
  ['bug_reports: developer comments as someone else', 'bug_reports', 'create', 'DENY',
    { authorId: 'u2', text: 'x' }, {}, DEVELOPER_INDEX, `${DOC_ID}/comments/c1`, false, TICKET_PARENT],
  ['bug_reports: other group member comments', 'bug_reports', 'create', 'DENY',
    { authorId: UID, text: 'x' }, {}, OTHER_GROUP_INDEX, `${DOC_ID}/comments/c1`, false, TICKET_PARENT],
  ['bug_reports: suspended developer reads comments', 'bug_reports', 'get', 'DENY',
    { authorId: 'u2', text: 'x' }, {}, { ...DEVELOPER_INDEX, status: 'SUSPENDED' }, `${DOC_ID}/comments/c1`, false, TICKET_PARENT],
  // Votes are on the audit trail: a Rules API case can't carry the stamp (a
  // server timestamp), so an unstamped vote is refused here and the stamped
  // ALLOW cases are in security/rules-tests (app_query_shapes.test.js).
  ['feature_requests: member votes without the audit stamp', 'feature_requests', 'create', 'DENY', ticketVote(UID, 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, IDEA_PARENT],
  ['feature_requests: member withdraws own vote without the audit stamp', 'feature_requests', 'update', 'DENY', ticketVote(UID, 1), { value: 0 },
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, IDEA_PARENT],
  ['feature_requests: member votes as someone else', 'feature_requests', 'create', 'DENY', ticketVote('u3', 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, IDEA_PARENT],
  ['feature_requests: member deletes own vote', 'feature_requests', 'delete', 'DENY', ticketVote(UID, 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, IDEA_PARENT],
  ['feature_requests: another group votes', 'feature_requests', 'create', 'DENY', ticketVote(UID, 1), {},
    OTHER_GROUP_INDEX, `${DOC_ID}/votes/${UID}`, false, IDEA_PARENT],
  ['feature_requests: creator writes a vote for another on own idea', 'feature_requests', 'create', 'DENY', ticketVote('u3', 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, { path: `feature_requests/${DOC_ID}`, data: MY_IDEA }],
  ['feature_requests: creator deletes another\'s vote on own idea', 'feature_requests', 'delete', 'DENY', ticketVote('u3', 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, { path: `feature_requests/${DOC_ID}`, data: MY_IDEA }],
  ['feature_requests: editor (sharedEditing true) forges a vote', 'feature_requests', 'create', 'DENY', ticketVote('fake123', 1), {},
    { ...IMPROVE_MEMBER_INDEX, entitlements: [...IMPROVE_MEMBER_INDEX.entitlements, 'g1:improve-apps:edit'] }, `${DOC_ID}/votes/fake123`, false, IDEA_PARENT],
  ['feature_requests: member votes on a deleted idea', 'feature_requests', 'create', 'DENY', ticketVote(UID, 1), {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, { ...IDEA_PARENT, data: { ...IDEA_PARENT.data, deletedAt: 1 } }],
  // A Rules API case can't carry the audit stamp (a server timestamp), so a
  // ticket write here is refused for its missing stamp as well as any field
  // lock. The stamped checks of each lock (resolution flags on create and
  // update, closedBy, the tally, edits to a deleted ticket) are in
  // security/rules-tests (app_query_shapes.test.js, stage 4).
  ['feature_requests: creator files an idea already closed', 'feature_requests', 'create', 'DENY', { ...MY_IDEA, isClosed: true }, {}, IMPROVE_MEMBER_INDEX],
  ['feature_requests: creator files an idea already completed', 'feature_requests', 'create', 'DENY', { ...MY_IDEA, isCompleted: true }, {}, IMPROVE_MEMBER_INDEX],
  ['feature_requests: member changes a seeded vote without the audit stamp', 'feature_requests', 'update', 'DENY', ticketVote(UID, 1), { value: -1, votedAt: 2 },
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, IDEA_PARENT],
  ['feature_requests: member comments on a deleted idea', 'feature_requests', 'create', 'DENY', { authorId: UID, text: 'x', groupId: 'g1', appId: 'improve-apps', creatorId: UID, ownerIds: [UID] }, {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/comments/c1`, false, { ...IDEA_PARENT, data: { ...IDEA_PARENT.data, deletedAt: 1 } }],
  ['feature_requests: creator comments on own deleted idea', 'feature_requests', 'create', 'DENY', { authorId: UID, text: 'x', groupId: 'g1', appId: 'improve-apps', creatorId: UID, ownerIds: [UID] }, {},
    IMPROVE_MEMBER_INDEX, `${DOC_ID}/comments/c1`, false, { path: `feature_requests/${DOC_ID}`, data: { ...MY_IDEA, deletedAt: 1 } }],
  ['feature_requests: member writes the tally', 'feature_requests', 'update', 'DENY', IDEA_PARENT.data, { voteCount: 99 }, IMPROVE_MEMBER_INDEX],
  ['feature_requests: creator hard-deletes own idea', 'feature_requests', 'delete', 'DENY', MY_IDEA, {}, IMPROVE_MEMBER_INDEX],
  ['feature_requests: creator marks own idea deleted (callable only)', 'feature_requests', 'update', 'DENY', MY_IDEA, { deletedAt: 1 }, IMPROVE_MEMBER_INDEX],
  ['feature_requests: unstamped edit of own idea (audit trail)', 'feature_requests', 'update', 'DENY', MY_IDEA, { title: 'y' }, IMPROVE_MEMBER_INDEX],
  ['feature_requests: member edits another\'s idea', 'feature_requests', 'update', 'DENY', IDEA_PARENT.data, { title: 'y' },
    IMPROVE_MEMBER_INDEX],
  ['app_requests: platform admin sets status (callable only, stamped)', 'app_requests', 'update', 'DENY', appRequest(), { status: 'planned', ...STAMP }, { ...APP_MAKER_INDEX, roles: ['admin'] }],
  ['notification_send_rate_limits: client write blocked', 'notification_send_rate_limits', 'update', 'DENY', { recentAttemptTimes: [] }, { recentAttemptTimes: [1] }],
  ['polls: member casts own vote on another\'s poll', 'polls', 'create', 'ALLOW', ballot(UID, { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member changes own vote', 'polls', 'update', 'ALLOW', ballot(UID, { choiceId: 'yes' }), { choiceId: 'no' },
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member reads own ballot', 'polls', 'get', 'ALLOW', ballot(UID, { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member reads another\'s ballot (selfRead)', 'polls', 'get', 'DENY', ballot('u2', { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u2`, false, POLL_PARENT],
  ['polls: member votes as someone else', 'polls', 'create', 'DENY', ballot('u3', { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, POLL_PARENT],
  ['polls: member changes another\'s vote', 'polls', 'update', 'DENY', ballot('u2', { choiceId: 'yes' }), { choiceId: 'no' },
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u2`, false, POLL_PARENT],
  ['polls: member deletes own vote', 'polls', 'delete', 'DENY', ballot(UID, { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  // A ballot is only ever its voter's (selfKeyed without editorsWrite): the
  // poll's creator and editors can't forge, change or delete another's.
  ['polls: creator writes a ballot for another member', 'polls', 'create', 'DENY', ballot('u3', { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, MY_POLL],
  ['polls: creator writes a ballot under a made-up id', 'polls', 'create', 'DENY', ballot('fake123', { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/fake123`, false, MY_POLL],
  ['polls: creator changes another\'s ballot', 'polls', 'update', 'DENY', ballot('u3', { choiceId: 'yes' }), { choiceId: 'no' },
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, MY_POLL],
  ['polls: creator deletes another\'s ballot', 'polls', 'delete', 'DENY', ballot('u3', { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/u3`, false, MY_POLL],
  ['polls: editor deletes another\'s ballot', 'polls', 'delete', 'DENY', ballot('u3', { choiceId: 'yes' }), {},
    POLLS_EDITOR_INDEX, `${DOC_ID}/votes/u3`, false, POLL_PARENT],
  ['polls: member re-assigns own ballot to another uid', 'polls', 'update', 'DENY', ballot(UID, { choiceId: 'yes' }), { userId: 'u3' },
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member adds a foreign userId to own ballot', 'polls', 'update', 'DENY', { groupId: 'g1', appId: 'polls', creatorId: UID, ownerIds: [UID], votedAt: 1, choiceId: 'yes' }, { userId: 'u3' },
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member\'s own ballot naming another creatorId', 'polls', 'create', 'DENY', { ...ballot(UID, { choiceId: 'yes' }), creatorId: 'u3' }, {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member\'s own ballot sharing ownerIds', 'polls', 'create', 'DENY', { ...ballot(UID, { choiceId: 'yes' }), ownerIds: [UID, 'u3'] }, {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: creator votes on own poll', 'polls', 'create', 'ALLOW', ballot(UID, { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, MY_POLL],
  ['polls: member votes on a soft-deleted poll', 'polls', 'create', 'DENY', ballot(UID, { choiceId: 'yes' }), {},
    POLLS_MEMBER_INDEX, `${DOC_ID}/votes/${UID}`, false, { ...POLL_PARENT, data: { ...POLL_PARENT.data, deletedAt: 1 } }],
  // Calendar attendees opt into editorsWrite: the event's host invites and removes them.
  ['calendar_events: host invites an attendee', 'calendar_events', 'create', 'ALLOW', invitee('u3'), {},
    CALENDAR_INDEX, `${DOC_ID}/attendees/u3`, false, MY_EVENT],
  ['calendar_events: host removes an attendee', 'calendar_events', 'delete', 'ALLOW', invitee('u3'), {},
    CALENDAR_INDEX, `${DOC_ID}/attendees/u3`, false, MY_EVENT],
  ['calendar_events: attendee RSVPs', 'calendar_events', 'update', 'ALLOW', invitee(UID), { status: 'going' },
    CALENDAR_INDEX, `${DOC_ID}/attendees/${UID}`, false, { ...MY_EVENT, data: { ...MY_EVENT.data, creatorId: 'u2', ownerIds: ['u2'] } }],
  ['polls: guest votes', 'polls', 'create', 'DENY', ballot(UID, { choiceId: 'yes' }), {},
    GUEST_INDEX, `${DOC_ID}/votes/${UID}`, false, POLL_PARENT],
  ['polls: member edits another\'s poll', 'polls', 'update', 'DENY', POLL_PARENT.data, { title: 'y' }, POLLS_MEMBER_INDEX],
];

function testCase(docPath, method, expectation, stored, changes, index, signedOut, parent) {
  const request = {
    path: `/databases/(default)/documents/${docPath}`,
    method,
    time: REQUEST_TIME,
  };
  // Signed out: an explicit null (the Rules API answers 500 when `auth` is absent).
  request.auth = signedOut ? null : { uid: UID };
  if (method === 'create') request.resource = { data: stored };
  if (method === 'update') request.resource = { data: { ...stored, ...changes } };
  return {
    expectation,
    request,
    ...(method === 'create' ? {} : { resource: { data: stored } }),
    functionMocks: [{
      function: 'get',
      args: [{ exactValue: `/databases/(default)/documents/users/${UID}/metadata/access_index` }],
      result: index ? { value: { data: index } } : { undefined: {} },
    },
    // A subcollection case's parent doc, which the rules read with get().
    ...(parent ? [{
      function: 'get',
      args: [{ exactValue: `/databases/(default)/documents/${parent.path}` }],
      result: { value: { data: parent.data } },
    }] : [])],
  };
}

const toCase = ([, collection, method, expectation, stored, changes = {}, index = ACCESS_INDEX, id = DOC_ID, signedOut = false, parent = null]) =>
  testCase(`${collection}/${id}`, method, expectation, stored, changes, index, signedOut, parent);

/** Kinds any signed-in user reads. */
const SIGNED_IN_READ_KINDS = ['platform', 'public'];

/**
 * Deny probes for every declared collection: a member of another group
 * creates a doc tagged with g1, reads one (not for the signed-in-read
 * kinds), and a signed-out caller reads one.
 */
function everyCollectionCases(table) {
  const out = [];
  for (const [name, entry] of Object.entries(table.collections).sort(([a], [b]) => (a < b ? -1 : 1))) {
    const doc = own((entry.apps || [])[0] || 'notes', { recipientId: UID, userId: UID, uid: UID });
    const id = entry.kind === 'personal' ? 'u2' : DOC_ID;
    out.push([`${name}: another group creates`, name, 'create', 'DENY', { ...doc, creatorId: 'u2', ownerIds: ['u2'] }, {}, OTHER_GROUP_INDEX, id]);
    if (!SIGNED_IN_READ_KINDS.includes(entry.kind)) {
      // Someone else's doc: the caller is in no reader field.
      out.push([`${name}: another group reads`, name, 'get', 'DENY',
        { ...doc, creatorId: 'u2', ownerIds: ['u2'], recipientId: 'u2', userId: 'u2', uid: 'u2' }, {}, OTHER_GROUP_INDEX, id]);
    }
    out.push([`${name}: signed out reads`, name, 'get', 'DENY', doc, {}, ACCESS_INDEX, id, true]);
  }
  return out;
}

async function runSuite(client, title, source, cases) {
  const res = await client.request({
    url: `https://firebaserules.googleapis.com/v1/projects/${PROJECT}:test`,
    method: 'POST',
    validateStatus: () => true,
    data: {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: cases.map(toCase) },
    },
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

// The Rules API takes a bounded number of test cases per call.
const CHUNK = 25;

async function main() {
  const file = process.argv[2] || path.join(ROOT, 'firestore.rules');
  const committed = fs.readFileSync(file, 'utf8');
  const client = await new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] }).getClient();

  // 1. RELEASED: is the committed file what production runs?
  const base = `https://firebaserules.googleapis.com/v1/projects/${PROJECT}`;
  const release = (await client.request({ url: `${base}/releases/cloud.firestore` })).data;
  const ruleset = (await client.request({ url: `https://firebaserules.googleapis.com/v1/${release.rulesetName}` })).data;
  const live = ruleset.source.files.map((f) => f.content).join('\n');
  console.log(`${live === committed ? 'ok  ' : 'note'} the released ruleset ${release.rulesetName} (updated ${release.updateTime}) ` +
    `${live === committed ? 'equals' : 'DIFFERS FROM'} ${path.relative(ROOT, file)}`);

  // 2. and 3.
  const results = [];
  results.push(await runSuite(client, 'representative cases', committed, CASES));
  const every = everyCollectionCases(gen.loadTable());
  for (let i = 0; i < every.length; i += CHUNK) {
    results.push(await runSuite(client, `every collection (${i + 1}-${Math.min(i + CHUNK, every.length)} of ${every.length})`,
      committed, every.slice(i, i + CHUNK)));
  }
  if (results.some((ok) => !ok)) process.exitCode = 1;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = { CASES, everyCollectionCases, toCase };
