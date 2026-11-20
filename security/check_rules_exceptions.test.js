'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { SCHEMA_PATH, validateTable } = require('./generate');
const { checkRulesExceptions, checkRepo, matchBlocksUnderRoot } = require('./check_rules_exceptions');

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));

const FIRESTORE = `
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    function f() { return {'a': {'b': true}}.get('a', {}); }
    // A comment mentioning match /ghost/{id} { must not count.
    match /approved/{id} {
      allow read: if true;
    }
    match /{collection}/{id} {
      allow read: if can('read', resource.data, collection);
      match /{subcollection}/{subId} {
        allow read: if true;
      }
    }
  }
}
`;

const STORAGE = `
service firebase.storage {
  match /b/{bucket}/o {
    match /groups/{groupId}/apps/{appId}/{allPaths=**} { allow read: if true; }
    match /groups/{groupId}/logo.jpg { allow read: if true; }
  }
}
`;

const exception = (extra) => ({ what: 'what it grants', why: 'why the generic rule cannot express it', reviewed: '2026-11-05', ...extra });
const TABLE = {
  collections: {},
  exceptions: {
    'EX-APPROVED-1': exception({ firestoreMatchBlocks: ['/approved/{id}'] }),
    'EX-LOGO-1': exception({ storageMatchBlocks: ['/groups/{groupId}/logo.jpg'] }),
  },
};
const check = (firestore = FIRESTORE, storage = STORAGE, table = TABLE) =>
  checkRulesExceptions({ 'firestore.rules': firestore, 'storage.rules': storage }, table, { schema });

test('the repo passes: every match block is generic or a reviewed exception', () => {
  assert.deepEqual(checkRepo(), []);
});

test('the fixture passes as written', () => {
  assert.deepEqual(check(), []);
});

test('an unlisted top-level match block fails', () => {
  const rules = FIRESTORE.replace('match /approved/{id} {', 'match /sneaky/{id} { allow read: if true; }\n    match /approved/{id} {');
  const problems = check(rules);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /firestore\.rules:7: match \/sneaky\/\{id\} is not the generic rule/);
});

test('an unlisted block nested inside an approved or generic block fails', () => {
  const inApproved = FIRESTORE.replace('allow read: if true;\n    }', 'allow read: if true;\n      match /inner/{x} { allow read: if true; }\n    }');
  assert.ok(check(inApproved).some((p) => p.includes('/approved/{id}/inner/{x}')));
  const inGeneric = FIRESTORE.replace('match /{subcollection}/{subId} {', 'match /secrets/{s} { allow read: if true; }\n      match /{subcollection}/{subId} {');
  assert.ok(check(inGeneric).some((p) => p.includes('/{collection}/{id}/secrets/{s}')));
});

test('storage.rules is guarded too', () => {
  const rules = STORAGE.replace('match /groups/{groupId}/logo.jpg', 'match /anything/{allPaths=**} { allow read: if true; }\n    match /groups/{groupId}/logo.jpg');
  assert.ok(check(FIRESTORE, rules).some((p) => p.startsWith('storage.rules:') && p.includes('/anything/{allPaths=**}')));
});

test('a listed block that no longer exists fails, so the list cannot rot', () => {
  const table = { ...TABLE, exceptions: { ...TABLE.exceptions, 'EX-GONE-1': exception({ firestoreMatchBlocks: ['/gone/{id}'] }) } };
  assert.ok(check(FIRESTORE, STORAGE, table).some((p) => p.includes('EX-GONE-1 lists firestore.rules /gone/{id}')));
});

test('a block listed by two exceptions fails', () => {
  const table = { ...TABLE, exceptions: { ...TABLE.exceptions, 'EX-TWICE-1': exception({ firestoreMatchBlocks: ['/approved/{id}'] }) } };
  assert.ok(check(FIRESTORE, STORAGE, table).some((p) => p.includes('listed by both EX-APPROVED-1 and EX-TWICE-1')));
});

test('a match block outside the service root fails', () => {
  const rules = FIRESTORE.replace(/\n}\n$/, '\n  match /stray/{id} { allow read: if true; }\n}\n');
  assert.ok(check(rules).some((p) => p.includes('/stray/{id} is outside')));
});

test('an exception without a why, a real reviewed date, or any block fails validation', () => {
  const problemsFor = (ex) => validateTable({ collections: {}, exceptions: { 'EX-X-1': ex } }, schema);
  assert.deepEqual(problemsFor(exception({ firestoreMatchBlocks: ['/a/{id}'] })), []);
  const cases = {
    'no why': { what: 'what it grants', reviewed: '2026-11-05', firestoreMatchBlocks: ['/a/{id}'] },
    'blank why': exception({ why: '   ', firestoreMatchBlocks: ['/a/{id}'] }),
    'no reviewed': { what: 'what it grants', why: 'why the generic rule cannot', firestoreMatchBlocks: ['/a/{id}'] },
    'reviewed not a date': exception({ reviewed: 'last week', firestoreMatchBlocks: ['/a/{id}'] }),
    'reviewed impossible date': exception({ reviewed: '2026-02-30', firestoreMatchBlocks: ['/a/{id}'] }),
    'no blocks': exception({}),
    'unknown key': exception({ firestoreMatchBlocks: ['/a/{id}'], approvedBy: 'me' }),
  };
  for (const [label, ex] of Object.entries(cases)) {
    assert.ok(problemsFor(ex).length > 0, label);
  }
  assert.ok(validateTable({ collections: {}, exceptions: { 'not-an-id': exception({ firestoreMatchBlocks: ['/a/{id}'] }) } }, schema).length > 0,
    'exception ids look like EX-NAME-1');
});

test('matchBlocksUnderRoot ignores comments and reports real lines', () => {
  const blocks = matchBlocksUnderRoot(FIRESTORE, '/databases/{database}/documents');
  assert.deepEqual(blocks.map((b) => [b.path, b.line]), [
    ['/approved/{id}', 7],
    ['/{collection}/{id}', 10],
    ['/{collection}/{id}/{subcollection}/{subId}', 12],
  ]);
});

test('a grant* function without inTenant() needs an exception listing it in ruleFunctions', () => {
  const { checkInTenantGrants } = require('./check_rules_exceptions');
  const rules = `
    function inTenant(ix, g) { return g in ix.groups; }
    function grantTenant(ix, d) { return inTenant(ix, d.groupId) && true; }
    function viaHelper(ix, d) { return inTenant(ix, d.groupId); }
    function grantIndirect(ix, d) { return viaHelper(ix, d); }
    function grantAdminRead(ix) { return ix.roles.hasAny(['admin']); }
    // function grantCommented() { return true; }
  `;
  const listed = { exceptions: { 'EX-ADMIN-1': exception({ ruleFunctions: ['grantAdminRead'] }) } };
  assert.deepEqual(checkInTenantGrants(rules, listed), []);
  assert.match(checkInTenantGrants(rules, { exceptions: {} }).join('\n'), /grantAdminRead\(\) grants without inTenant/);
  const stale = { exceptions: { 'EX-ADMIN-1': exception({ ruleFunctions: ['grantAdminRead', 'grantGone'] }) } };
  assert.match(checkInTenantGrants(rules, stale).join('\n'), /EX-ADMIN-1 lists rule function grantGone\(\)/);
  assert.match(checkInTenantGrants(`${rules} function grantX(d) { return d.visibility == 'public'; }`, listed).join('\n'), /visibility/);
  assert.match(checkInTenantGrants(`${rules} function grantY(d) { return d['visibility'] == 'public'; }`, listed).join('\n'), /visibility/);
  assert.match(checkInTenantGrants(`${rules} function grantZ(d) { return d.get('visibility', '') == 'public'; }`, listed).join('\n'), /visibility/);
  // Naming the field in a write-lock list reads nothing.
  assert.deepEqual(checkInTenantGrants(`${rules} function serverFields(c) { return {'apps': ['securityTier', 'visibility']}[c]; }`, listed), []);
  assert.match(checkInTenantGrants(`${rules} function hasRole(r) { return r == 'auditor'; }`, listed).join('\n'), /auditor/);
});
