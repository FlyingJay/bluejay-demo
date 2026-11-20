'use strict';
/**
 * Representative and heaviest realistic requests, each run alone and
 * measured (lib/cost.js), against the committed firestore.rules. Fails if
 * any decision changes, if any request hits Firestore's
 * 1000-expression limit, or has less than MIN_HEADROOM to spare: the
 * generated policy table once pushed every ordinary write over the limit
 * (plan section 10, "Found 2026-11-05"), and this is the regression test for
 * that whole class. Mirrored by security/tools/rules_api_smoke.js against
 * the production rules engine.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { serverTimestamp } = require('firebase/firestore');
const { setup, FIRESTORE_RULES } = require('../lib/personas');
const { perform, EXPRESSION_LIMIT } = require('../lib/run');
const { headrooms, byKey } = require('../lib/cost');
const { autoId } = require('../lib/generate_matrix');
const W = require('../lib/world');

/**
 * Fewest spare expressions an allowed request below may have (lib/cost.js).
 * The output lists every request's headroom; lower this only with a reason.
 */
const MIN_HEADROOM = 50;

/**
 * Denied requests whose deny comes from exhausting the budget rather than
 * from a rule saying no (KI-DENY-PATH-COST). Pinned so a new one fails.
 */
const KNOWN_EXHAUSTED_DENIES = [];

const A = W.GROUP_A;
const own = (uid, appId, extra = {}) => ({ groupId: A, appId, creatorId: uid, ownerIds: [uid], title: 'x', ...extra });
const applicant = 'u-member';
const draft = own(applicant, 'rented-dwelling', { status: 'draft' });
// What ScopedCollection adds to every write to an auditTrail collection (insurance_applications).
const audited = (uid, data) => ({ ...data, lastModifiedBy: uid, lastModifiedAt: serverTimestamp() });
const eventByOther = own(W.AUTHOR, 'event-planner');
const triviaHostedByOther = own(W.AUTHOR, 'trivia-night', { hostId: W.AUTHOR, ownerIds: [W.AUTHOR, 'u-member'], memberIds: [W.AUTHOR, 'u-member'] });
const inbox = (recipientId) => ({ groupId: A, appId: 'notes', recipientId, title: 'x', body: 'y', isRead: false });
const groupDoc = { groupId: 'g-cost', name: 'G', memberIds: ['u-member'], adminIds: ['u-member'], installedApps: ['notes'], isFrozen: false, creatorId: 'u-member' };
const myMembership = { groupId: A, userId: 'u-member', role: 'member', creatorId: 'u-member' };
const usersEvent = { groupId: A, appId: 'users', collection: 'memberships', docId: `${A}_u-member`, operation: 'update', actorUid: 'u-owner' };
const invitation = { groupId: A, appId: 'users', email: 'zed@bluejay.gg', role: 'member', status: 'pending', invitedBy: 'u-editor', creatorId: 'u-editor', ownerIds: ['u-editor'] };
// An audit_events entry of billing_events: recorded under Billing (the collection's one app).
const billingEvent = { groupId: A, appId: 'billing', collection: 'billing_events', docId: 'fee1', operation: 'create', actorUid: 'u-owner' };
const directory = { groupId: A, uid: W.AUTHOR, displayName: 'Author', role: 'member' };
const profile = (uid) => ({ uid, displayName: 'Me', roles: [], status: 'ACTIVE' });
const ceEvent = own(W.AUTHOR, 'continuing-education', { name: 'CE' });
const lesson = own(W.AUTHOR, 'language-learner');
const counter = own('u-member', 'usage-meter', { uid: 'u-member', date: '2026-11-05', apps: { notes: { opens: 1 } } });
// The comment thread (commentThread): a groupmate's bug, a member's own bug,
// and the comment / likes docs the shared widget writes (ScopedCollection.sub
// stamps the parent's tenant and the audit stamp).
const ticket = (uid) => ({ path: `bug_reports/${autoId(`cost-ticket-${uid}`)}`, data: own(uid, 'improve-apps', { description: 'd' }) });
const authorsBug = ticket(W.AUTHOR);
const membersBug = ticket('u-member');
const comment = (uid, extra = {}) => ({ ...own(uid, 'improve-apps'), text: 'hi', authorId: uid, timestamp: 1, parentCommentId: null,
  lastModifiedBy: uid, lastModifiedAt: 1, ...extra });
// A likes doc carries only its selfKeyed fields and the shim's identity (no title).
const likes = (uid, commentIds) => ({ groupId: A, appId: 'improve-apps', creatorId: uid, ownerIds: [uid], userId: uid, commentIds, updatedAt: 1 });
const softDelete = (uid) => audited(uid, { text: '', deletedAt: serverTimestamp(), deletedBy: uid });

// [label, persona, collection, op, expect, stored/created doc, update changes, doc id, parent {path, data}]
const CASES = [
  ['notes: read in own group', 'u-member', 'notes', 'get', true, own('u-member', 'notes')],
  ['notes: create own', 'u-member', 'notes', 'create', true, own('u-member', 'notes')],
  ['notes: create with a natural-key id', 'u-member', 'notes', 'create', false, own('u-member', 'notes'), null, 'my-note'],
  ['notes: create tagged with the group', 'u-member', 'notes', 'create', true, own('u-member', 'notes'), null, `${A}__k1`],
  ['notes: update own', 'u-member', 'notes', 'update', true, own('u-member', 'notes'), { title: 'y' }],
  ['notes: move to another group', 'u-member', 'notes', 'update', false, own('u-member', 'notes'), { groupId: W.GROUP_B }],
  ['notes: delete own', 'u-member', 'notes', 'delete', true, own('u-member', 'notes')],
  ['notes: other group reads', 'u-member-b', 'notes', 'get', false, own('u-member', 'notes')],
  ['notes: removed creator reads own (D1)', 'u-removed', 'notes', 'get', false, own('u-removed', 'notes')],
  ['notes: public doc of another group (D2)', 'u-member-b', 'notes', 'get', false, own(W.AUTHOR, 'notes', { visibility: 'public' })],
  ['unlisted collection: create own', 'u-member', W.UNDECLARED, 'create', true, own('u-member', 'notes')],
  ['access_index_rebuilds (first bucket): create blocked', 'u-member', 'access_index_rebuilds', 'create', false, own('u-member', 'notes')],
  ['payment_orders (server): create blocked', 'u-member', 'payment_orders', 'create', false, own('u-member', 'billing')],
  ['merchantAccounts (capital letter): create blocked', 'u-member', 'merchantAccounts', 'create', false, own('u-member', 'merchant-portal')],
  ['usage_daily: delete blocked', 'u-member', 'usage_daily', 'delete', false, own('u-member', 'usage-meter', { uid: 'u-member', date: '2026-11-05' })],
  // memberWrite + the idPattern placeholders: every client's counter flush.
  ['usage_daily: member creates own counter', 'u-member', 'usage_daily', 'create', true, counter, null, `2026-11-05_${A}_u-member`],
  ['usage_daily: member increments own counter', 'u-member', 'usage_daily', 'update', true, counter, { apps: { notes: { opens: 2 } } }, `2026-11-05_${A}_u-member`],
  ['usage_daily: guest creates own counter', 'u-guest', 'usage_daily', 'create', false, { ...counter, uid: 'u-guest', creatorId: 'u-guest', ownerIds: ['u-guest'] }, null, `2026-11-05_${A}_u-guest`],
  ['habits: single-owner create', 'u-member', 'habits', 'create', true, own('u-member', 'habit-tracker')],
  ['habits: co-owned create blocked', 'u-member', 'habits', 'create', false, own('u-member', 'habit-tracker', { ownerIds: ['u-member', 'u-editor'] })],
  ['vendor_market_listings: delete blocked', 'u-member', 'vendor_market_listings', 'delete', false, own('u-member', 'marketplace-admin')],
  ['warehouse_uploads (last bucket): create blocked', 'u-member', 'warehouse_uploads', 'create', false, own('u-member', 'warehouse-imports')],
  // insurance_applications: the heaviest path (staffOnly fields + values, staff lookup).
  ['insurance: applicant edits a draft', applicant, 'insurance_applications', 'update', true, draft, audited(applicant, { title: 'y' })],
  ['insurance: applicant sets policyNumber', applicant, 'insurance_applications', 'update', false, draft, audited(applicant, { policyNumber: 'P1' })],
  ['insurance: applicant activates', applicant, 'insurance_applications', 'update', false, draft, audited(applicant, { status: 'active' })],
  ['insurance: applicant creates a draft', applicant, 'insurance_applications', 'create', true, audited(applicant, draft)],
  ['insurance: staff sets policyNumber', 'u-editor', 'insurance_applications', 'update', true, draft, audited('u-editor', { policyNumber: 'P1', insurer: 'I' })],
  ['insurance: staff activates', 'u-editor', 'insurance_applications', 'update', true, draft, audited('u-editor', { status: 'active', activatedAt: 1 })],
  ['insurance: group admin activates', 'u-group-admin', 'insurance_applications', 'update', true, draft, audited('u-group-admin', { status: 'active' })],
  ['insurance: staff moves app (tenantUnchanged)', 'u-editor', 'insurance_applications', 'update', false, draft, audited('u-editor', { appId: 'course-of-construction' })],
  // event_planner_events: the longest adminOnly list.
  ['event planner: editor edits title', 'u-member', 'event_planner_events', 'update', true, eventByOther, { title: 'y' }],
  ['event planner: editor edits several fields', 'u-member', 'event_planner_events', 'update', true, eventByOther, { title: 'y', location: 'l', startsAt: 1, notes: 'n' }],
  ['event planner: editor sets rsvpCounts', 'u-member', 'event_planner_events', 'update', false, eventByOther, { rsvpCounts: { yes: 9 } }],
  // trivia_games: creatorOnly + protectedRoleField.
  ['trivia: co-owner edits title', 'u-member', 'trivia_games', 'update', true, triviaHostedByOther, { title: 'y' }],
  ['trivia: editor joins (memberIds)', 'u-editor', 'trivia_games', 'update', true, triviaHostedByOther, { memberIds: [W.AUTHOR, 'u-member', 'u-editor'] }],
  ['trivia: co-owner (not host) changes status', 'u-member', 'trivia_games', 'update', false, triviaHostedByOther, { status: 'finished' }],
  ['trivia: co-owner drops the host', 'u-member', 'trivia_games', 'update', false, triviaHostedByOther, { memberIds: ['u-member'] }],
  // Server-owned membership inputs and the reader-writable inbox.
  ['notifications: recipient reads', 'u-member', 'notifications', 'get', true, inbox('u-member')],
  ['notifications: recipient marks read', 'u-member', 'notifications', 'update', true, inbox('u-member'), { isRead: true }],
  ['notifications: recipient deletes', 'u-member', 'notifications', 'delete', true, inbox('u-member')],
  ['notifications: recipient edits the body', 'u-member', 'notifications', 'update', false, inbox('u-member'), { body: 'z' }],
  ['notifications: someone else marks read', 'u-editor', 'notifications', 'update', false, inbox('u-member'), { isRead: true }],
  ['memberships: member reads the group\'s', 'u-editor', 'memberships', 'get', true, myMembership],
  ['memberships: self-promote blocked', 'u-member', 'memberships', 'update', false, myMembership, { role: 'owner' }],
  // On the audit trail but still server-written: a stamp doesn't open a client write.
  ['memberships: stamped self-promote blocked', 'u-member', 'memberships', 'update', false, myMembership, audited('u-member', { role: 'owner' })],
  ['invitations: member reads the group\'s', 'u-member', 'invitations', 'get', true, invitation],
  // Membership and invitation history: recorded under the Users app, read by its :admin tier in the group.
  ['audit_events: owner reads a Users event', 'u-owner', 'audit_events', 'get', true, usersEvent],
  ['audit_events: group admin reads a Users event', 'u-group-admin', 'audit_events', 'get', true, usersEvent],
  ['audit_events: editor reads a Users event', 'u-editor', 'audit_events', 'get', false, usersEvent],
  ['audit_events: member reads a Users event', 'u-member', 'audit_events', 'get', false, usersEvent],
  ['audit_events: another group\'s member reads it', 'u-member-b', 'audit_events', 'get', false, usersEvent],
  ['invitations: editor creates one (callable only)', 'u-editor', 'invitations', 'create', false, audited('u-editor', invitation)],
  ['invitations: editor revokes by marking it (callable only)', 'u-editor', 'invitations', 'update', false, invitation, audited('u-editor', { status: 'revoked' })],
  ['invitations: editor deletes one (callable only)', 'u-editor', 'invitations', 'delete', false, invitation],
  ['audit_events: owner (Billing :admin) reads billing history', 'u-owner', 'audit_events', 'get', true, billingEvent],
  ['audit_events: editor (no :admin) reads billing history', 'u-editor', 'audit_events', 'get', false, billingEvent],
  ['audit_events: another group reads billing history', 'u-member-b', 'audit_events', 'get', false, billingEvent],
  ['group_members: member reads the directory', 'u-member', 'group_members', 'get', true, directory, null, `${A}__${W.AUTHOR}`],
  ['group_members: guest reads the directory', 'u-guest', 'group_members', 'get', false, directory, null, `${A}__${W.AUTHOR}`],
  ['group_members: other group reads', 'u-member-b', 'group_members', 'get', false, directory, null, `${A}__${W.AUTHOR}`],
  ['group_members: member writes blocked', 'u-member', 'group_members', 'update', false, directory, { displayName: 'x' }, `${A}__${W.AUTHOR}`],
  ['groups: member reads own group', 'u-member', 'groups', 'get', true, { ...groupDoc, groupId: A }, null, A],
  // Server-written: renames go through updateGroupDetails, deletes through adminDeleteGroup.
  ['groups: platform admin renames (callable only)', 'u-admin', 'groups', 'update', false, groupDoc, { name: 'G2' }, 'g-cost'],
  ['groups: developer renames (callable only)', 'u-developer', 'groups', 'update', false, groupDoc, { name: 'G2' }, 'g-cost'],
  ['groups: platform admin deletes (callable only)', 'u-admin', 'groups', 'delete', false, groupDoc, null, 'g-cost'],
  ['groups: developer reads any group', 'u-developer', 'groups', 'get', true, groupDoc, null, 'g-cost'],
  ['groups: platform admin reads any group', 'u-admin', 'groups', 'get', true, groupDoc, null, 'g-cost'],
  ['groups: platform admin adds a member', 'u-admin', 'groups', 'update', false, groupDoc, { memberIds: ['u-member', 'u-x'] }, 'g-cost'],
  ['groups: suspended admin renames', 'u-admin-suspended', 'groups', 'update', false, groupDoc, { name: 'G2' }, 'g-cost'],
  // personal, platform, platform_admin
  ['users: own profile read', 'u-member', 'users', 'get', true, profile('u-member'), null, 'u-member'],
  ['users: own lastActive', 'u-member', 'users', 'update', true, profile('u-member'), { lastActive: 1 }, 'u-member'],
  ['users: self-grant admin', 'u-member', 'users', 'update', false, profile('u-member'), { roles: ['admin'] }, 'u-member'],
  ['users: someone else\'s profile', 'u-member', 'users', 'get', false, profile('u-editor'), null, 'u-editor'],
  ['users: developer reads a profile', 'u-developer', 'users', 'get', true, profile('u-editor'), null, 'u-editor'],
  ['categories: admin write blocked', 'u-admin', 'categories', 'update', false, { name: 'c' }, { name: 'd' }],
  ['categories: member reads', 'u-member', 'categories', 'get', true, { name: 'c' }],
  ['apps: developer edits a description', 'u-developer', 'apps', 'update', true, { name: 'n', allowedGroups: [] }, { description: 'd' }],
  ['apps: developer sets allowedGroups', 'u-developer', 'apps', 'update', false, { name: 'n', allowedGroups: [] }, { allowedGroups: ['x'] }],
  ['script_runs: admin reads', 'u-admin', 'script_runs', 'get', true, { status: 'ok' }],
  ['script_runs: suspended admin reads', 'u-admin-suspended', 'script_runs', 'get', false, { status: 'ok' }],
  ['collection_catalog: member reads', 'u-member', 'collection_catalog', 'get', false, { docCount: 1 }],
  // writeTier edit (ce_events), ownerScoped (language learner)
  ['ce_events: member creates', 'u-member', 'ce_events', 'create', false, own('u-member', 'continuing-education')],
  ['ce_events: CE editor creates', 'u-editor', 'ce_events', 'create', true, own('u-editor', 'continuing-education')],
  ['ce_events: member reads', 'u-member', 'ce_events', 'get', true, ceEvent],
  ['language learner: co-member reads another\'s', 'u-editor', 'language_learner_messages', 'get', false, lesson],
  ['language learner: group owner reads', 'u-owner', 'language_learner_messages', 'get', true, lesson],
  // Comment threads: subcollection writes, the heaviest tenant path (parent get + governed policy).
  ['comments: member comments on a groupmate\'s bug', 'u-member', 'bug_reports', 'create', true,
    audited('u-member', comment('u-member')), null, `${authorsBug.path.split('/')[1]}/comments/c-cost-1`, authorsBug],
  ['comments: unstamped comment', 'u-member', 'bug_reports', 'create', false,
    comment('u-member'), null, `${authorsBug.path.split('/')[1]}/comments/c-cost-2`, authorsBug],
  ['comments: author soft-deletes own', 'u-member', 'bug_reports', 'update', true,
    comment('u-member'), softDelete('u-member'), `${authorsBug.path.split('/')[1]}/comments/c-cost-3`, authorsBug],
  ['comments: author hard-deletes own', 'u-member', 'bug_reports', 'delete', false,
    comment('u-member'), null, `${authorsBug.path.split('/')[1]}/comments/c-cost-4`, authorsBug],
  ['comments: requester soft-deletes a staff question', 'u-member', 'bug_reports', 'update', false,
    comment(W.AUTHOR), softDelete('u-member'), `${membersBug.path.split('/')[1]}/comments/c-cost-5`, membersBug],
  ['comments: editor likes by editing the comment', 'u-editor', 'bug_reports', 'update', false,
    comment(W.AUTHOR), audited('u-editor', { likedBy: ['u-editor'] }), `${authorsBug.path.split('/')[1]}/comments/c-cost-6`, authorsBug],
  ['comment_likes: member likes a comment', 'u-member', 'bug_reports', 'create', true,
    audited('u-member', likes('u-member', ['c1'])), null, `${authorsBug.path.split('/')[1]}/comment_likes/u-member`, authorsBug],
  ['comment_likes: member unlikes', 'u-member', 'bug_reports', 'update', true,
    likes('u-member', ['c1', 'c2']), audited('u-member', { commentIds: ['c2'], updatedAt: 2 }),
    `${authorsBug.path.split('/')[1]}/comment_likes/u-member`, authorsBug],
  ['comment_likes: member likes as someone else', 'u-member', 'bug_reports', 'create', false,
    audited('u-member', likes('u-member', ['c1'])), null, `${authorsBug.path.split('/')[1]}/comment_likes/u-editor`, authorsBug],
];

// What the 2025-12-16 permissive release allowed and the rules no longer do.
const FORMERLY_OPEN = [
  ['formerly open: insurance staff field by applicant', applicant, 'insurance_applications', 'update', false, draft, audited(applicant, { policyNumber: 'P1' })],
  ['formerly open: event planner rsvpCounts', 'u-member', 'event_planner_events', 'update', false, eventByOther, { rsvpCounts: { yes: 9 } }],
  ['formerly open: payment_orders create', 'u-member', 'payment_orders', 'create', false, own('u-member', 'billing')],
  ['formerly open: removed user reads', 'u-removed', 'notes', 'get', false, own(W.AUTHOR, 'notes')],
  ['formerly open: invitations signed out', 'anon', 'invitations', 'get', false, { groupId: A, email: 'x@y.z' }],
  ['formerly open: notes signed out', 'anon', 'notes', 'get', false, own('u-member', 'notes')],
];

async function measure(project, source, cases) {
  const t = await setup(project, { rules: source });
  try {
    const requests = cases.map(([label, persona, collection, op, expect, stored, changes, id, parent], i) => {
      const path = `${collection}/${id || autoId(`cost-${i}-${label}`)}`;
      const c = {
        key: label, persona, collection, op, path,
        seed: op === 'create' ? {} : { [path]: stored },
        data: op === 'create' ? stored : changes,
      };
      const run = async () => {
        // A subcollection case's parent doc, which the rules get().
        if (parent) await t.admin.db.doc(parent.path).set(parent.data);
        if (op === 'create') await t.admin.db.doc(path).delete();
        else await t.admin.db.doc(path).set(stored);
        return perform(t.clients[persona].db, c, t.admin.db);
      };
      // Headroom: padding the request survives with its decision intact (an
      // allow stays an allow; a deny stays a deny that didn't run out).
      const attempt = async () => {
        const r = await run();
        return expect ? r.allow : !r.allow && !r.message.includes(EXPRESSION_LIMIT);
      };
      // Requests on the same doc run one at a time (lib/cost.js).
      return { key: path, label, expect, run, attempt };
    });
    const first = new Map();
    await byKey(requests, async (r) => { first.set(r, await r.run()); });
    const rooms = await headrooms(project, source, requests);
    return requests.map((r, i) => ({
      label: r.label, expect: r.expect, got: first.get(r).allow, limit: first.get(r).message.includes(EXPRESSION_LIMIT), room: rooms[i],
    }));
  } finally {
    await t.teardown();
  }
}

function report(title, rows) {
  console.log(`${title}: expression headroom per request (least first; -1 = already over the limit):`);
  for (const r of [...rows].sort((a, b) => a.room - b.room)) {
    console.log(`  ${String(r.room).padStart(4)}  ${r.got ? 'ALLOW' : 'DENY '}  ${r.label}`);
  }
  return rows
    .filter((r) => r.got !== r.expect || (r.expect && (r.limit || r.room < MIN_HEADROOM)))
    .map((r) => `${r.label}: ${r.got ? 'ALLOW' : 'DENY'} (want ${r.expect ? 'ALLOW' : 'DENY'}), headroom ${r.room}` +
      `${r.limit ? ', HIT THE 1000-EXPRESSION LIMIT' : ''}`);
}

test('decisions and expression headroom (committed rules)', { timeout: 20 * 60 * 1000 }, async () => {
  const rows = await measure('demo-bluejay-cost', fs.readFileSync(FIRESTORE_RULES, 'utf8'), [...CASES, ...FORMERLY_OPEN]);
  const problems = report('committed', rows);
  assert.deepEqual(problems, [], `allowed requests need >= ${MIN_HEADROOM} expressions of headroom`);
  const exhausted = rows.filter((r) => !r.expect && r.limit).map((r) => r.label);
  assert.deepEqual(exhausted, KNOWN_EXHAUSTED_DENIES, 'denied requests that exhaust the expression budget (KI-DENY-PATH-COST)');
});

module.exports = { CASES, FORMERLY_OPEN };
