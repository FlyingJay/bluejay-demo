const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const gc = require('./generate_data_catalog');
const { loadTable } = require('./generate');

test('the committed data catalog is generated from the table', () => {
  assert.equal(fs.readFileSync(gc.JSON_PATH, 'utf8'), gc.renderJson(loadTable()));
});

test('dataCatalog lists the tenant collections only, sorted', () => {
  const table = { collections: {
    b: { apps: ['x'] },
    a: { kind: 'tenant', apps: ['y'], ownerScoped: true, auditTrail: true },
    s: { kind: 'server', apps: ['x'] },
    p: { kind: 'platform' },
    u: { kind: 'personal' },
    q: { kind: 'public' },
    n: {},
  } };
  assert.deepEqual(Object.keys(gc.dataCatalog(table)), ['a', 'b', 'n']);
  assert.deepEqual(gc.dataCatalog(table).a, { apps: ['y'], ownerScoped: true, auditTrail: true, redact: [] });
  assert.deepEqual(gc.dataCatalog(table).n, { apps: [], ownerScoped: false, auditTrail: false, redact: [] });
});

test('redact holds auditRedact plus the secret-looking fields the entry names', () => {
  const entry = {
    auditRedact: ['details.secureUrl', 'accessToken'],
    serverFields: ['status', 'inviteTokenHash', 'clientSecret'],
    immutable: ['uid', 'passwordHint'],
    creatorOnly: ['nonceValue', 'title'],
  };
  assert.deepEqual(gc.redactedFields(entry), ['accessToken', 'clientSecret', 'details.secureUrl', 'inviteTokenHash', 'nonceValue', 'passwordHint']);
  assert.deepEqual(gc.redactedFields({ serverFields: ['status'] }), []);
});

test('every catalog entry is a collection the generated rules treat as tenant', () => {
  const table = loadTable();
  const catalog = JSON.parse(fs.readFileSync(gc.JSON_PATH, 'utf8')).collections;
  for (const name of Object.keys(catalog)) {
    const kind = table.collections[name].kind || 'tenant';
    assert.equal(kind, 'tenant', `${name} is kind ${kind}`);
  }
});
