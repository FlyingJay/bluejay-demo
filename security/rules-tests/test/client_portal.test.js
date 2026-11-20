'use strict';
/**
 * Portal clients against the committed rules (plans/business-suite/
 * CLIENT_PORTAL_PLAN.md): a client reads the records whose
 * clientReaderListField names them, in their group, only while they hold
 * the app's :guest entitlement, and nothing else of the group. The matrix
 * covers every collection's own/other cases; this pins the scenarios by name.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { assertSucceeds, assertFails } = require('@firebase/rules-unit-testing');
const { doc, getDoc, collection, query, where, getDocs } = require('firebase/firestore');
const { setup } = require('../lib/personas');
const W = require('../lib/world');

const A = W.GROUP_A;
const Z = W.GROUP_FROZEN;
const record = (groupId, clientUids, extra = {}) => ({
  groupId, appId: 'invoices', creatorId: W.AUTHOR, ownerIds: [W.AUTHOR], kind: 'invoice', status: 'sent', clientUids, ...extra,
});

test('portal clients read their own records and nothing else', { timeout: 120000 }, async () => {
  const t = await setup('demo-bluejay-client-portal');
  try {
    const seed = {
      'invoicing_documents/mine': record(A, ['u-client']),
      'client_invoicing_documents/mine': record(A, ['u-client', 'u-client-pending', 'u-removed', 'u-guest']),
      'client_invoicing_documents/theirs': record(A, ['someone-else']),
      'client_invoicing_documents/frozen': record(Z, ['u-client-frozen']),
      'contacts/c1': { groupId: A, appId: 'contacts', creatorId: W.AUTHOR, ownerIds: [W.AUTHOR], linkedUids: ['u-client'] },
    };
    for (const [path, data] of Object.entries(seed)) await t.admin.db.doc(path).set(data);
    const db = (uid) => t.clients[uid].db;

    await assertSucceeds(getDoc(doc(db('u-client'), 'client_invoicing_documents/mine')));
    await assertFails(getDoc(doc(db('u-client'), 'client_invoicing_documents/theirs')));
    await assertSucceeds(getDocs(query(collection(db('u-client'), 'client_invoicing_documents'),
      where('groupId', '==', A), where('clientUids', 'array-contains', 'u-client'))));
    // A query that doesn't pin the client's own uid can't be proven.
    await assertFails(getDocs(query(collection(db('u-client'), 'client_invoicing_documents'), where('groupId', '==', A))));

    // Pending, removed, a frozen group, and a visitor guest get nothing from the list.
    await assertFails(getDoc(doc(db('u-client-pending'), 'client_invoicing_documents/mine')));
    await assertFails(getDoc(doc(db('u-removed'), 'client_invoicing_documents/mine')));
    await assertFails(getDoc(doc(db('u-guest'), 'client_invoicing_documents/mine')));
    await assertFails(getDoc(doc(db('u-client-frozen'), 'client_invoicing_documents/frozen')));

    // The record itself is staff-only: clients read only its client-safe copy.
    await assertFails(getDoc(doc(db('u-client'), 'invoicing_documents/mine')));
    await assertFails(getDocs(query(collection(db('u-client'), 'invoicing_documents'),
      where('groupId', '==', A), where('clientUids', 'array-contains', 'u-client'))));

    // Group data that names them is still staff-only: contacts, memberships, the portal config.
    await assertFails(getDoc(doc(db('u-client'), 'contacts/c1')));
    await assertFails(getDocs(query(collection(db('u-client'), 'memberships'), where('groupId', '==', A))));
    await assertFails(getDoc(doc(db('u-client'), `portal_configs/${A}`)));
    // Their own membership stays readable (readerField).
    await assertSucceeds(getDoc(doc(db('u-client'), `memberships/${A}_u-client`)));
    assert.ok(true);
  } finally {
    await t.teardown();
  }
});
