const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const ga = require('./generate_audit');
const { loadTable } = require('./generate');

test('the committed audit list is generated from the table', () => {
  assert.equal(fs.readFileSync(ga.JSON_PATH, 'utf8'), ga.renderJson(loadTable()));
});

test('auditedCollections lists exactly the auditTrail entries, sorted', () => {
  const table = { collections: {
    b: { auditTrail: true }, a: { auditTrail: true }, c: {}, d: { auditTrail: false },
  } };
  assert.deepEqual(ga.auditedCollections(table), ['a', 'b']);
});

test('the audit list names every audited subcollection, the comment thread included', () => {
  const { applyTemplates } = require('./generate');
  const table = applyTemplates({ collections: {
    t: { commentThread: true },
    u: { subcollections: { notes: { auditTrail: true }, other: { selfKeyed: { fields: ['x'], selfCreate: true, selfDelete: false } } } },
  } });
  assert.deepEqual(JSON.parse(ga.renderJson(table)).subcollections, ['t/comment_likes', 't/comments', 'u/notes']);
});

test('auditRedactions and auditedStewardRead cover audited collections only', () => {
  const table = { collections: {
    s: { auditTrail: true, auditRedact: ['z', 'details.url'], stewardRead: true },
    u: { auditRedact: ['x'], stewardRead: true },
    v: { auditTrail: true },
  } };
  assert.deepEqual(ga.auditRedactions(table), { s: ['details.url', 'z'] });
  assert.deepEqual(ga.auditedStewardRead(table), ['s']);
});

test('auditAppIds: an audited collection records under its auditAppId, else its one app (the rules scope)', () => {
  const table = { collections: {
    m: { auditTrail: true, auditAppId: 'users' },
    g: { auditTrail: true, apps: ['groups'], auditAppId: 'group-admin' },
    b: { auditTrail: true, apps: ['billing'] },
    several: { auditTrail: true, apps: ['a', 'b'] },
    a: { auditTrail: true },
    x: { apps: ['billing'] },
  } };
  assert.deepEqual(ga.auditAppIds(table), { b: 'billing', g: 'group-admin', m: 'users' });
});
