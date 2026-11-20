'use strict';
/**
 * The personas' access indexes, as the real builder (functions/_shared.js)
 * produced them from the seeded world. Pins the properties the matrix relies
 * on, so a computeEntitlements change shows up here by name rather than as a
 * shower of matrix differences.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { setup } = require('../lib/personas');
const W = require('../lib/world');

const A = W.GROUP_A;

test('persona access indexes come from the real builder', { timeout: 120000 }, async () => {
  const t = await setup('demo-bluejay-personas');
  try {
    const ix = t.indexes;
    const has = (uid, e) => ix[uid].entitlements.includes(e);

    assert.equal(ix.anon, null);
    assert.equal(ix['u-no-index'], null);
    const stored = await t.admin.db.doc('users/u-member/metadata/access_index').get();
    assert.deepEqual(stored.data().entitlements, ix['u-member'].entitlements, 'the rules read what the builder built');

    // Tiers: sharedEditing (alpha) gives every member :edit; beta doesn't.
    assert.ok(has('u-member', `${A}:alpha`) && has('u-member', `${A}:alpha:edit`));
    assert.ok(has('u-member', `${A}:beta`) && !has('u-member', `${A}:beta:edit`));
    assert.ok(has('u-editor', `${A}:beta:edit`) && !has('u-editor', `${A}:beta:admin`));
    assert.ok(has('u-owner', `${A}:beta:admin`));
    assert.ok(has('u-group-admin', `${A}:beta:admin`), 'adminIds is admin-tier whatever the membership role');

    // Segments: governed app only for the segment member and group admins.
    assert.ok(!has('u-member', `${A}:seg`));
    assert.ok(has('u-seg-member', `${A}:seg`));
    assert.ok(has('u-group-admin', `${A}:seg`));

    // Guests: embeddable apps only, :guest plus shared collections.
    assert.deepEqual([...ix['u-guest'].entitlements].sort(), [
      `${A}:delta:guest`, `${A}:gamma:collection:${W.UNDECLARED}`, `${A}:gamma:guest`,
    ]);

    // Portal clients: :guest for the portal's apps only, and only while active.
    assert.deepEqual([...ix['u-client'].entitlements].sort(),
      W.CLIENT_PORTAL_APPS.map((app) => `${A}:${app}:guest`).sort());
    assert.deepEqual(ix['u-client'].guest_groups, [A]);
    assert.deepEqual(ix['u-client-pending'].entitlements, []);
    assert.deepEqual(ix['u-client-frozen'].entitlements, []);
    assert.deepEqual(ix['u-client-frozen'].denied_scopes, [W.GROUP_FROZEN]);

    // memberRead excludes guests: the index lists the groups they're only a guest of.
    assert.deepEqual(ix['u-guest'].guest_groups, [A]);
    assert.deepEqual(ix['u-member'].guest_groups, []);

    // Cross-group, removed, frozen, steward.
    assert.ok(ix['u-member-b'].entitlements.every((e) => e.startsWith(`${W.GROUP_B}:`)));
    assert.deepEqual(ix['u-removed'].groups, []);
    assert.deepEqual(ix['u-removed'].entitlements, []);
    assert.deepEqual(ix['u-frozen'].denied_scopes, [W.GROUP_FROZEN]);
    assert.deepEqual(ix['u-frozen'].entitlements, []);
    assert.deepEqual(ix['u-steward'].entitlements, ['app:alpha:steward']);

    // Platform access comes from the claims, untouched by the builder.
    assert.equal(ix['u-suspended'].status, 'SUSPENDED');
    assert.equal(ix['u-clearance3'].clearance_level, 3);
    assert.deepEqual(ix['u-admin'].roles, ['admin']);
    assert.deepEqual(ix['u-auditor'].roles, ['auditor'], 'a stale auditor role reaches the index; the rules must grant it nothing');

    // Ids with `_` get no entitlements at all (T5), which is why the table
    // names continuing-education and policy-editor (T6 fixed the rules' ids).
    for (const [uid, index] of Object.entries(ix)) {
      if (!index) continue;
      for (const bad of ['continuing_education', 'insurance_admin']) {
        assert.ok(!index.entitlements.some((e) => e.split(':')[1] === bad), `${uid} has a ${bad} entitlement`);
      }
    }
    assert.ok(has('u-owner', `${A}:continuing-education:admin`));
    assert.ok(has('u-owner', `${A}:policy-editor:admin`));
  } finally {
    await t.teardown();
  }
});
