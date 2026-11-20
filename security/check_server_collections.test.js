'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  extractReferences, globalBindings, scanFunctions, serverOwned, loadAllowlist, check,
} = require('./check_server_collections');
const { loadTable } = require('./generate');

const names = (refs, sub = false) => [...new Set(refs.filter((r) => r.sub === sub).map((r) => r.name))].sort();

/** A throwaway repo root with functions/ files and one client file. */
function fixture(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'server-collections-'));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), text);
  }
  return root;
}

const TABLE = {
  collections: {
    payment_orders: { kind: 'server' },
    vendor_market_threads: { serverWritten: true },
    apps: { ownMatchBlock: true },
    insurance_applications: { subcollections: { transactions: { serverWritten: true } } },
  },
};

test('the repo passes: every collection functions use is declared server-owned or allowlisted', () => {
  const problems = check({ scan: scanFunctions(), table: loadTable(), allowlist: loadAllowlist() });
  assert.deepEqual(problems, []);
});

test('extracts the reference shapes functions code uses', () => {
  const source = `
    const db = admin.firestore();
    const FOO_COLLECTION = 'foo_things';
    const UNUSED_COLLECTION = 'exported_only';
    const COLLECTIONS = Object.freeze({ orders: 'payment_orders', accounts: 'group_payment_accounts' });
    const REGIONS_DOC = { collection: 'platform_config', id: 'warehouse_regions' };
    const PATH = ['usage_config', 'pricing'];
    db.collection('literal_one').doc(id).set({});
    db.collection(FOO_COLLECTION).add({});
    db.collection(COLLECTIONS.orders).doc(x);
    db.collection(REGIONS_DOC.collection).doc(REGIONS_DOC.id);
    db.collection(PATH[0]).doc(PATH[1]);
    db.doc(\`naic_jobs/\${jobId}/batches/\${batchId}\`);
    db.doc('settings_root/abc');
    db.collection('parents').doc(pid).collection('kids').doc().set({});
    snap.ref.collection('ref_kids').add({});
    const eventRef = db.collection('events_x').doc(e);
    eventRef.collection('event_kids').get();
    db.collectionGroup('grouped_kids').get();
    await enforceRateLimits({ collection: 'limits_x', key });
    // db.collection('commented_out').add({});
    /* db.collection('block_commented').add({}); */
    db.collection(dynamicName).get();
  `;
  const { refs, unresolved } = extractReferences(source);
  assert.deepEqual(names(refs), [
    'events_x', 'exported_only', 'foo_things', 'group_payment_accounts', 'limits_x', 'literal_one',
    'naic_jobs', 'parents', 'payment_orders', 'platform_config', 'settings_root', 'usage_config',
  ]);
  assert.deepEqual(names(refs, true), ['batches', 'event_kids', 'grouped_kids', 'kids', 'ref_kids']);
  assert.deepEqual(unresolved.map((u) => u.text), ['.collection(dynamicName)']);
});

test('a constant imported from another module resolves through the global bindings', () => {
  const globals = globalBindings([
    "const INVOICES = 'invoices';\nmodule.exports = { INVOICES };",
    "const SAME = 'a';", "const SAME = 'b';",
  ]);
  assert.equal(globals.INVOICES, 'invoices');
  assert.equal(globals.SAME, undefined, 'conflicting bindings are dropped, not guessed');
  const { refs } = extractReferences("const { INVOICES } = require('./x');\ndb.collection(INVOICES).get();", globals);
  assert.deepEqual(names(refs), ['invoices']);
});

test('a constant used as a subcollection name is not also counted as a root collection', () => {
  const { refs } = extractReferences(
    "const HISTORY_COLLECTION = 'history';\nref.collection(HISTORY_COLLECTION).add({});",
  );
  assert.deepEqual(names(refs), []);
  assert.deepEqual(names(refs, true), ['history']);
});

test('a fooSubcollection config property names a subcollection', () => {
  const { refs } = extractReferences(
    "const GAME = { gamesCollection: 'games_x', turnsSubcollection: 'turns_x' };",
  );
  assert.deepEqual(names(refs), ['games_x']);
  assert.deepEqual(names(refs, true), ['turns_x']);
});

test('fails on a fixture that adds an undeclared server write, and names the fix', () => {
  const root = fixture({
    'functions/index.js': "db.collection('payment_orders').add({});\ndb.collection('shadow_ledger').doc(k).set({});\n",
    'functions/index.test.js': "db.collection('test_only').add({});\n",
  });
  const problems = check({ scan: scanFunctions(root), table: TABLE, allowlist: {}, root });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /collection "shadow_ledger" is used by Cloud Functions \(functions\/index\.js:2\)/);
  assert.match(problems[0], /kind "server"/);
});

test('an undeclared server-written subcollection fails; declared on any parent passes', () => {
  const root = fixture({
    'functions/a.js': "db.collection('insurance_applications').doc(id).collection('transactions').doc(k).set({});\n" +
      "db.collection('insurance_applications').doc(id).collection('ledger_rows').add({});\n",
  });
  const allowlist = { collections: { insurance_applications: { reason: 'applicants', clientWriters: [] } } };
  const problems = check({ scan: scanFunctions(root), table: TABLE, allowlist, root });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /subcollection "ledger_rows"/);
});

test('ownMatchBlock is not server ownership', () => {
  assert.ok(!serverOwned(TABLE).collections.has('apps'));
  assert.ok(serverOwned(TABLE).collections.has('payment_orders'));
  assert.ok(serverOwned(TABLE).collections.has('vendor_market_threads'));
  assert.ok(serverOwned(TABLE).subcollections.has('transactions'));
});

test('allowlist entries need a reason and real client writer files, and go stale', () => {
  const root = fixture({
    'functions/a.js': "db.collection('notes').add({}); db.collection('payment_orders').add({});\n",
    'packages/notes/lib/notes_service.dart': '// writes notes\n',
  });
  const scan = scanFunctions(root);
  const ok = { collections: { notes: { reason: 'members write notes', clientWriters: ['packages/notes/lib/notes_service.dart'] } } };
  assert.deepEqual(check({ scan, table: TABLE, allowlist: ok, root }), []);

  const cases = {
    'no reason': { collections: { notes: { clientWriters: [] } } },
    'no clientWriters': { collections: { notes: { reason: 'x' } } },
    'missing writer file': { collections: { notes: { reason: 'x', clientWriters: ['packages/gone.dart'] } } },
    'stale (functions no longer use it)': { collections: { ...ok.collections, old_thing: { reason: 'x', clientWriters: [] } } },
    'also declared server-owned': { collections: { ...ok.collections, payment_orders: { reason: 'x', clientWriters: [] } } },
    'unknown top-level key': { ...ok, collectionz: {} },
  };
  for (const [label, allowlist] of Object.entries(cases)) {
    assert.ok(check({ scan, table: TABLE, allowlist, root }).length > 0, label);
  }
});
