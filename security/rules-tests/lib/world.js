'use strict';
/**
 * The synthetic tenant world every rules test runs in: groups, apps,
 * memberships and segments, and the personas whose access indexes are built
 * from them by the real access-index builder (lib/personas.js).
 *
 * Nothing here is an access index. Personas are described the way production
 * describes users (memberships, group adminIds, segments, Auth claims), and
 * functions/_shared.js turns that into the index the rules read.
 */

const GROUP_A = 'grp-a';
const GROUP_B = 'grp-b';
/** Frozen (isFrozen): its members' indexes list it in denied_scopes. */
const GROUP_FROZEN = 'grp-z';
/** Steward group of app `alpha` (apps/alpha.stewardGroupIds). */
const GROUP_STEWARD = 'grp-s';

const APP_ALPHA = 'alpha'; // sharedEditing default (true): every member gets :edit
const APP_BETA = 'beta'; // sharedEditing false: only editor-tier roles get :edit
const APP_GAMMA = 'gamma'; // embeddable, shares the undeclared collection with guests
const APP_DELTA = 'delta'; // embeddable, shares nothing (no externalCollections)
const APP_SEG = 'seg'; // segment-governed in group A

/** Synthetic name for "a collection nobody declared" (plan 6.2 item 5). */
const UNDECLARED = 'zz_new_app_items';

/** Uid of the author of every "someone else's doc" fixture. */
const AUTHOR = 'u-author';

const notShared = { sharedEditing: false };

/**
 * apps/{id}. Besides the five synthetic apps, the ids the hand-written rules
 * name (canManageCeEvents' continuing_education, the insurance staffApps and
 * staffOnlyAppIds), so their checks meet the entitlements production would
 * build for them, including none at all for ids computeEntitlements skips.
 */
const APPS = {
  [APP_ALPHA]: { stewardGroupIds: [GROUP_STEWARD] },
  [APP_BETA]: notShared,
  [APP_GAMMA]: { ...notShared, isEmbeddable: true, externalCollections: [UNDECLARED] },
  [APP_DELTA]: { ...notShared, isEmbeddable: true },
  [APP_SEG]: notShared,
  // Ids with `_` are skipped by computeEntitlements (T5's tenant-id format);
  // seeded so the personas test can pin that they grant nothing.
  continuing_education: notShared,
  'continuing-education': notShared,
  insurance_admin: notShared,
  'policy-editor': notShared,
  'rented-dwelling': notShared,
  'course-of-construction': notShared,
  // Apps of the representative requests (test/cost.test.js, seeded from
  // security/tools/rules_api_smoke.js); sharedEditing default.
  notes: {},
  billing: {},
  'usage-meter': {},
  'habit-tracker': {},
  'marketplace-admin': {},
  warehouse: {},
  merchant: {},
  'event-planner': {},
  trivia: {},
};

// Every app the policy table names (apps, staffApps), installed like beta
// (sharedEditing false) unless listed above: the enforced rules take a
// single-app collection's scope from the table, so the personas need real
// entitlements to those ids. Installed in group B too, so cross-group cases
// meet a caller who holds the same app in their own group.
const TABLE_APPS = [];
for (const entry of Object.values(require('../../generate').loadTable().collections)) {
  for (const app of [...(entry.apps || []), ...(entry.staffApps || [])]) {
    if (!(app in APPS)) {
      APPS[app] = notShared;
      TABLE_APPS.push(app);
    }
  }
}

const GROUPS = {
  [GROUP_A]: {
    groupId: GROUP_A,
    status: 'ACTIVE',
    installedApps: Object.keys(APPS),
    adminIds: ['u-group-admin'],
  },
  [GROUP_B]: { groupId: GROUP_B, status: 'ACTIVE', installedApps: [APP_ALPHA, APP_BETA, ...TABLE_APPS], adminIds: [] },
  [GROUP_FROZEN]: { groupId: GROUP_FROZEN, status: 'ACTIVE', isFrozen: true, installedApps: [APP_BETA], adminIds: [] },
  [GROUP_STEWARD]: { groupId: GROUP_STEWARD, status: 'ACTIVE', installedApps: [], adminIds: [] },
};

/** app_access_segments: `seg` is governed in group A; one member qualifies. */
const SEGMENTS = {
  'seg-a': { groupId: GROUP_A, includedAppIds: [APP_SEG], memberUserIds: ['u-seg-member'] },
};

const ACTIVE = { status: 'ACTIVE', roles: [], clearance_level: 0 };

/** An approved portal client's membership. */
const CLIENT_ACTIVE = Object.freeze({ role: 'guest', guestType: 'client', clientStatus: 'active' });

/**
 * Apps with a client view: every app owning a collection that declares a
 * clientReaderListField. They get `clientPortal: true`, and the client
 * portals of groups A and Z give them to clients.
 */
const CLIENT_PORTAL_APPS = [];
for (const entry of Object.values(require('../../generate').loadTable().collections)) {
  if (entry.clientReaderListField && entry.apps) {
    for (const app of entry.apps) if (!CLIENT_PORTAL_APPS.includes(app)) CLIENT_PORTAL_APPS.push(app);
  }
}
for (const app of CLIENT_PORTAL_APPS) APPS[app] = { ...APPS[app], clientPortal: true };
for (const groupId of [GROUP_A, GROUP_FROZEN]) {
  GROUPS[groupId].installedApps = [...new Set([...GROUPS[groupId].installedApps, ...CLIENT_PORTAL_APPS])];
}

/** portal_configs/{groupId} */
const PORTAL_CONFIGS = {
  [GROUP_A]: { enabled: true, registration: 'invite_only', apps: CLIENT_PORTAL_APPS },
  [GROUP_FROZEN]: { enabled: true, registration: 'invite_only', apps: CLIENT_PORTAL_APPS },
};

/**
 * Personas (plan 6.2 item 1). `memberships` maps groupId -> role; `platform`
 * is what readPlatformAccess (the Auth claims) would return. `signedOut`
 * personas make requests without auth; `noIndex` ones are signed in but have
 * no access index document.
 */
const PERSONAS = {
  anon: { signedOut: true, about: 'signed out' },
  'u-no-index': { noIndex: true, about: 'signed in, no access index' },
  'u-member': { memberships: { [GROUP_A]: 'member' }, about: 'member of A (no segment)' },
  'u-editor': { memberships: { [GROUP_A]: 'editor' }, about: 'editor of A (:edit everywhere)' },
  'u-owner': { memberships: { [GROUP_A]: 'owner' }, about: 'owner role in A (:admin)' },
  'u-group-admin': { memberships: { [GROUP_A]: 'member' }, about: 'in A.adminIds, membership role member' },
  'u-guest': { memberships: { [GROUP_A]: 'guest' }, about: 'guest of A (embeddable apps only)' },
  // Portal clients (functions/_client_portal.js): a membership given as an
  // object is written as is. GROUP_A's portal gives clients every app with a
  // clientReaderListField collection (PORTAL_CONFIGS).
  'u-client': { memberships: { [GROUP_A]: CLIENT_ACTIVE }, about: 'active portal client of A' },
  'u-client-pending': { memberships: { [GROUP_A]: { ...CLIENT_ACTIVE, clientStatus: 'pending' } }, about: 'portal client of A awaiting approval' },
  'u-client-frozen': { memberships: { [GROUP_FROZEN]: CLIENT_ACTIVE }, about: 'portal client of frozen group Z' },
  'u-seg-member': { memberships: { [GROUP_A]: 'member' }, about: 'member of A in the seg segment' },
  'u-member-b': { memberships: { [GROUP_B]: 'member' }, about: 'member of B only' },
  'u-co-owner': { memberships: { [GROUP_B]: 'member' }, about: 'member of B, co-owner (ownerIds) of an A doc' },
  'u-removed': { memberships: {}, about: 'no memberships; still creator of `own` docs' },
  'u-frozen': { memberships: { [GROUP_FROZEN]: 'member' }, about: 'member of frozen group Z only' },
  'u-suspended': { memberships: { [GROUP_A]: 'member' }, platform: { ...ACTIVE, status: 'SUSPENDED' }, about: 'member of A, SUSPENDED' },
  'u-clearance3': { memberships: { [GROUP_A]: 'member' }, platform: { ...ACTIVE, clearance_level: 3 }, about: 'member of A, clearance 3' },
  'u-admin': { memberships: {}, platform: { ...ACTIVE, roles: ['admin'] }, about: 'platform admin' },
  'u-admin-suspended': { memberships: {}, platform: { ...ACTIVE, roles: ['admin'], status: 'SUSPENDED' }, about: 'platform admin, SUSPENDED' },
  'u-developer': { memberships: {}, platform: { ...ACTIVE, roles: ['developer'] }, about: 'platform developer' },
  'u-auditor': { memberships: { [GROUP_A]: 'member' }, platform: { ...ACTIVE, roles: ['auditor'] }, about: 'member of A with a stale auditor role' },
  'u-steward': { memberships: { [GROUP_STEWARD]: 'member' }, about: 'member of the steward group of alpha' },
};

const PERSONA_IDS = Object.keys(PERSONAS);

module.exports = {
  GROUP_A, GROUP_B, GROUP_FROZEN, GROUP_STEWARD,
  APP_ALPHA, APP_BETA, APP_GAMMA, APP_DELTA, APP_SEG,
  UNDECLARED, AUTHOR, APPS, GROUPS, SEGMENTS, PERSONAS, PERSONA_IDS, ACTIVE,
  CLIENT_PORTAL_APPS, PORTAL_CONFIGS,
};
