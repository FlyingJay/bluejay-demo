'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { loadTable } = require('./generate');
const { DART_PATH, shimPolicy, shimPolicies, isPassThrough, renderDart, writeDart, checkDart } = require('./generate_dart');

test('the committed Dart table is up to date (run `node security/generate.js`)', () => {
  assert.equal(fs.readFileSync(DART_PATH, 'utf8'), renderDart(loadTable()));
  assert.ok(checkDart(loadTable()));
});

test('kinds, apps, server ownership and natural keys come from the table', () => {
  assert.deepEqual(shimPolicy('notes', {}), {
    kind: 'tenant', apps: [], serverOwned: false, naturalKeyIds: false, auditTrail: false, subcollections: {}, auditedSubcollections: [],
    selfReadSubcollections: [], publishTo: null, source: null,
    readerField: null, readerListField: null, clientReaderListField: null,
    editTierWrites: false, ownerScoped: false, singleOwner: false, blockDelete: false, serverFields: [], searchable: false,
  });
  assert.equal(shimPolicy('contacts', { search: { fields: ['name'] } }).searchable, true);
  const locked = shimPolicy('inventory_items', {
    writeTier: 'edit', ownerScoped: true, singleOwner: true, blockDelete: true, serverFields: ['stock', 'onHand'],
  });
  assert.deepEqual(
    [locked.editTierWrites, locked.ownerScoped, locked.singleOwner, locked.blockDelete, locked.serverFields],
    [true, true, true, true, ['onHand', 'stock']],
  );
  assert.equal(shimPolicy('payment_orders', { kind: 'server' }).blockDelete, true);
  assert.equal(shimPolicy('files', { publishTo: 'public_files' }).publishTo, 'public_files');
  assert.equal(shimPolicy('public_files', { kind: 'public', source: 'files' }).source, 'files');
  assert.deepEqual(shimPolicy('payment_orders', { kind: 'server' }).serverOwned, true);
  assert.equal(shimPolicy('vendor_market_threads', { serverWritten: true }).kind, 'tenant');
  assert.equal(shimPolicy('vendor_market_threads', { serverWritten: true }).serverOwned, true);
  assert.equal(shimPolicy('public_x', { kind: 'public' }).serverOwned, true);
  assert.deepEqual(shimPolicy('insurance_applications', { apps: ['a', 'b'] }).apps, ['a', 'b']);
  assert.equal(shimPolicy('farkle_stats', { naturalKeyIds: true }).naturalKeyIds, true);
  assert.equal(shimPolicy('x', { idPattern: '^.*$' }).naturalKeyIds, true);
  assert.deepEqual(
    shimPolicy('naic_sight_jobs', { subcollections: { batches: { serverWritten: true }, notes: {} } }).subcollections,
    { batches: { serverOwned: true }, notes: { serverOwned: false } },
  );
  assert.deepEqual(
    shimPolicy('polls', { subcollections: { votes: { selfKeyed: { fields: ['userId'], selfCreate: true, selfDelete: false, selfRead: true } } } })
      .selfReadSubcollections,
    ['votes'],
  );
  assert.throws(() => shimPolicy('x', { kind: 'mystery' }), /KINDS/);
});

test('every non-tenant kind is a pass-through', () => {
  const policies = shimPolicies({
    collections: {
      a: { kind: 'server' }, b: { kind: 'personal' }, c: { kind: 'platform' },
      d: { kind: 'platform_admin' }, e: { kind: 'public' }, f: {}, g: { serverWritten: true },
    },
  });
  assert.deepEqual(
    Object.keys(policies).filter((n) => isPassThrough(policies, n)),
    ['a', 'b', 'c', 'd', 'e'],
  );
  assert.equal(isPassThrough(policies, 'undeclared'), false);
});

test('renders a Dart map literal with defaults left out', () => {
  const dart = renderDart({
    collections: {
      zeta: {},
      alpha: { kind: 'platform_admin' },
      multi: { apps: ['a-app', "o'brien"], naturalKeyIds: true, subcollections: { h: { serverWritten: true } } },
    },
  });
  assert.match(dart, /'alpha': CollectionPolicy\(kind: CollectionKind\.platformAdmin\),\n {2}'multi'/);
  assert.match(dart, /'multi': CollectionPolicy\(apps: \['a-app', 'o\\'brien'\], naturalKeyIds: true, subcollections: \{'h': true\}\),/);
  assert.match(dart, /'zeta': CollectionPolicy\(\),/);
});

test('writeDart writes only on change; checkDart notices drift', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gen-dart-'));
  const file = path.join(dir, 'nested', 'p.g.dart');
  const table = { collections: { notes: {} } };
  assert.equal(checkDart(table, file), false);
  assert.equal(writeDart(table, file), true);
  assert.equal(writeDart(table, file), false);
  assert.equal(checkDart(table, file), true);
  assert.equal(checkDart({ collections: { notes: { kind: 'server' } } }, file), false);
});

test('auditTrail reaches the shim, so ScopedCollection stamps audited writes', () => {
  const gd = require('./generate_dart');
  const table = { collections: { ledger: { apps: ['books'], auditTrail: true }, notes: { apps: ['notes'] } } };
  assert.equal(gd.shimPolicies(table).ledger.auditTrail, true);
  assert.equal(gd.shimPolicies(table).notes.auditTrail, false);
  assert.match(gd.renderDart(table), /'ledger': CollectionPolicy\(apps: \['books'\], auditTrail: true\)/);
});

test('an audited subcollection (the comment thread) reaches the shim, so ScopedCollection.sub stamps its writes', () => {
  const { applyTemplates } = require('./generate');
  const gd = require('./generate_dart');
  const table = applyTemplates({ collections: { tickets: { apps: ['t'], commentThread: true } } });
  assert.deepEqual(gd.shimPolicies(table).tickets.auditedSubcollections, ['comment_likes', 'comments']);
  assert.match(gd.renderDart(table), /'tickets': CollectionPolicy\(apps: \['t'\], subcollections: \{'comments': false, 'comment_likes': false\}, auditedSubcollections: \{'comment_likes', 'comments'\}\)/);
});
