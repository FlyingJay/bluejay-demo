'use strict';
/**
 * The public namespace (D2, plan 2.7, T27), against the committed rules:
 * a published projection (public_<source>) is readable by any signed-in
 * user from any group, by get and by list with or without a source-group
 * filter; nobody writes one from a client (members, editors, admins, the
 * source doc's creator, platform admins); and a tenant source doc stamped
 * `visibility: 'public'` grants nothing outside its group. The generated
 * matrix covers the same entries generically; these are the cases the plan
 * names (6.2 item 2), spelled out.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { setup } = require('../lib/personas');
const gen = require('../../generate');
const W = require('../lib/world');

const SOURCE = 'vendor_market_listings';
const PUBLIC = 'public_vendor_market_listings';
const SOURCE_ID = 'listing1';
const PUBLIC_ID = `${W.GROUP_A}__${SOURCE_ID}`;

async function allowed(promise) {
  try {
    await promise;
    return true;
  } catch (err) {
    if (err && err.code === 'permission-denied') return false;
    throw err;
  }
}

test('public namespace: signed-in read of published projections, no client writes, visibility grants nothing', { timeout: 5 * 60 * 1000 }, async () => {
  const table = gen.loadTable();
  assert.equal(table.collections[PUBLIC].kind, 'public');
  assert.equal(table.collections[SOURCE].publishTo, PUBLIC);

  const t = await setup('demo-bluejay-public', { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') });
  try {
    const projection = {
      sourceGroupId: W.GROUP_A, sourceAppId: 'marketplace-admin', sourceCollection: SOURCE, sourceId: SOURCE_ID,
      publishedBy: W.AUTHOR, projectionVersion: 'v1', name: 'Listing', status: 'published',
    };
    const source = {
      groupId: W.GROUP_A, appId: 'marketplace-admin', creatorId: W.AUTHOR, ownerIds: [W.AUTHOR],
      name: 'Listing', status: 'published', visibility: 'public',
    };
    await t.admin.db.doc(`${PUBLIC}/${PUBLIC_ID}`).set(projection);
    await t.admin.db.doc(`${SOURCE}/${SOURCE_ID}`).set(source);

    const failures = [];
    const expect = async (label, want, promise) => {
      const got = await allowed(promise);
      if (got !== want) failures.push(`${label}: expected ${want ? 'ALLOW' : 'DENY'}, got ${got ? 'ALLOW' : 'DENY'}`);
    };

    const readers = ['u-member', 'u-member-b', 'u-removed', 'u-guest', 'u-frozen', 'u-no-index', 'u-admin', 'u-developer'];
    for (const p of readers) {
      const db = t.clients[p].db;
      await expect(`${p} get published`, true, db.doc(`${PUBLIC}/${PUBLIC_ID}`).get());
      await expect(`${p} get missing published`, true, db.doc(`${PUBLIC}/${W.GROUP_B}__nope`).get());
      await expect(`${p} list all`, true, db.collection(PUBLIC).get());
      await expect(`${p} list by source group`, true, db.collection(PUBLIC).where('sourceGroupId', '==', W.GROUP_A).get());
    }
    const anon = t.clients.anon.db;
    await expect('signed out get', false, anon.doc(`${PUBLIC}/${PUBLIC_ID}`).get());
    await expect('signed out list', false, anon.collection(PUBLIC).get());

    // No client writes: not its group's members, editors or admins, nor
    // platform admins. Only the Admin SDK (publicPublish).
    const writers = ['u-member', 'u-editor', 'u-owner', 'u-group-admin', 'u-member-b', 'u-admin', 'u-developer'];
    for (const p of writers) {
      const db = t.clients[p].db;
      await expect(`${p} create`, false, db.doc(`${PUBLIC}/${W.GROUP_A}__forged-${p}`).set({ ...projection, sourceId: `forged-${p}` }));
      await expect(`${p} create in own group`, false,
        db.doc(`${PUBLIC}/${W.GROUP_B}__forged-${p}`).set({ ...projection, sourceGroupId: W.GROUP_B, publishedBy: p }));
      await expect(`${p} update`, false, db.doc(`${PUBLIC}/${PUBLIC_ID}`).update({ name: 'defaced' }));
      await expect(`${p} delete`, false, db.doc(`${PUBLIC}/${PUBLIC_ID}`).delete());
      await expect(`${p} subcollection write`, false, db.doc(`${PUBLIC}/${PUBLIC_ID}/x/y`).set({ a: 1 }));
    }

    // D2: the tenant rule ignores `visibility`. A member of group B can't
    // read the source doc or list group A's "public" docs.
    const b = t.clients['u-member-b'].db;
    await expect('group B get of a visibility:public source', false, b.doc(`${SOURCE}/${SOURCE_ID}`).get());
    await expect('group B list of visibility:public sources', false,
      b.collection(SOURCE).where('groupId', '==', W.GROUP_A).where('visibility', '==', 'public').get());
    // ...while group A's own members still read it as tenant data.
    await expect('group A member get of the source', true, t.clients['u-member'].db.doc(`${SOURCE}/${SOURCE_ID}`).get());

    assert.deepEqual(failures, []);
  } finally {
    await t.teardown();
  }
});
