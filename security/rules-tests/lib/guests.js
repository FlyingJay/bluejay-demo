'use strict';
/**
 * Guests of the four embeddable apps (rules plan stage 5, D1), built the way
 * production builds them: a `role: 'guest'` membership (functions/guest_users.js),
 * the apps' production permission config, a corporate access config and a
 * guest attestation for the corporate app, then the REAL
 * buildUserAccessIndex (computeGuestAdmissions + computeEntitlements)
 * reading them back from the emulator, as rebuildUserAccessIndex reads
 * production. Used by test/app_query_shapes.test.js (Firestore) and
 * test/storage.test.js (Storage), so both test the same personas.
 *
 * Needs functions/node_modules (`npm ci` in functions/).
 */

const path = require('path');
const { accessIndexDb } = require('./access_index_db');

const ROOT = path.resolve(__dirname, '..', '..', '..');
// eslint-disable-next-line import/no-dynamic-require
const { buildUserAccessIndex } = require(path.join(ROOT, 'functions', '_shared.js'));
// eslint-disable-next-line import/no-dynamic-require
const { attestationRecord } = require(path.join(ROOT, 'functions', '_guest_identity.js'));

const G = 'gst';
/** Guest of every embeddable app; attested for the corporate one (NAIC Sight). */
const GUEST = 'guest-1';
/** Another guest of G: the author of "someone else's" application, job and upload. */
const OTHER_GUEST = 'guest-2';
/** A guest who never confirmed a work email: NAIC Sight (corporate only) doesn't admit them. */
const UNATTESTED = 'guest-3';
/** A member of G (not a guest), for the group directory fixtures. */
const MEMBER = 'member-1';

/**
 * The four embeddable apps' permission fields as production holds them
 * (apps/{id}, read 2026-11-06), except that each insurance product also
 * lists its config collection in externalCollections: production lists
 * only insurance_applications, which the rules now ignore for guests (not
 * guestShareable), and its form config needs adding (see the stage-5 PR).
 */
const EMBEDDABLE_APPS = {
  'rented-dwelling': {
    isEmbeddable: true, sharedEditing: false, embeddableAccessModes: [],
    externalCollections: ['insurance_applications', 'rented_dwelling_config'],
  },
  'course-of-construction': {
    isEmbeddable: true, sharedEditing: false, embeddableAccessModes: [],
    externalCollections: ['insurance_applications', 'insurance_coc_config'],
  },
  'naic-sight': { isEmbeddable: true, sharedEditing: false, embeddableAccessModes: ['corporate'], externalCollections: [] },
  'warehouse-uploader': {
    isEmbeddable: true, sharedEditing: false, embeddableAccessModes: ['public', 'corporate'], externalCollections: [],
  },
};
/** Installed alongside, as in production's groups (acme, globex, northwind). */
const OTHER_APPS = { 'warehouse-imports': { sharedEditing: false }, 'policy-editor': { sharedEditing: false } };

const APPS = { ...EMBEDDABLE_APPS, ...OTHER_APPS };
const ACTIVE = { status: 'ACTIVE', roles: [], clearance_level: 0 };
const ROLES = { [GUEST]: 'guest', [OTHER_GUEST]: 'guest', [UNATTESTED]: 'guest', [MEMBER]: 'member' };

/**
 * Seeds the guests' world into [db] (a rules-bypassing compat Firestore),
 * builds each persona's index with the real builder, writes it to
 * users/{uid}/metadata/access_index and returns { uid: index }.
 */
async function seedGuests(db) {
  const batch = db.batch();
  batch.set(db.doc(`groups/${G}`), {
    groupId: G, name: 'Guest Co', status: 'ACTIVE', installedApps: Object.keys(APPS), adminIds: [],
    memberIds: Object.keys(ROLES),
  });
  for (const [id, data] of Object.entries(APPS)) batch.set(db.doc(`apps/${id}`), { appId: id, allowedGroups: [], ...data });
  for (const [uid, role] of Object.entries(ROLES)) {
    batch.set(db.doc(`memberships/${G}_${uid}`), { groupId: G, groupSlug: G, userId: uid, role, creatorId: uid });
    batch.set(db.doc(`users/${uid}`), { uid, isGuest: role === 'guest', guestGroupId: G, creatorId: uid });
  }
  // NAIC Sight is corporate-only in production (acme, northwind): an
  // allowlist, and the attestation corporateAccessSetGuestIdentity writes.
  batch.set(db.doc(`corporate_access_configs/${G}__naic-sight`), {
    groupId: G, appId: 'app-access', targetAppId: 'naic-sight', accessMode: 'corporate',
    corporateEnabled: true, publicEnabled: false, allowedDomains: ['acme.example'],
  });
  for (const uid of [GUEST, OTHER_GUEST]) {
    const att = attestationRecord(db, {
      uid, groupSlug: G, groupDocId: G, appId: 'naic-sight', email: `${uid}@acme.example`, name: uid, now: new Date(0),
    });
    batch.set(att.ref, att.data);
  }
  await batch.commit();

  const indexes = {};
  const quiet = console.log;
  console.log = () => {};
  try {
    for (const uid of Object.keys(ROLES)) {
      const { index } = await buildUserAccessIndex(uid, { db: accessIndexDb(db), readAccess: async () => ({ ...ACTIVE }) });
      indexes[uid] = index;
      await db.doc(`users/${uid}/metadata/access_index`).set(index);
    }
  } finally {
    console.log = quiet;
  }
  return indexes;
}

module.exports = { G, GUEST, OTHER_GUEST, UNATTESTED, MEMBER, EMBEDDABLE_APPS, APPS, seedGuests };
