'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const {
  RULES_PATH, SCHEMA_PATH, duplicateKeys, validateTable, loadTable, expandEntry,
  collectionPolicies, selfKeyedSubcollections, serverFieldsByCollection, readerWritesByCollection, serverWrittenSubcollections,
  selfReadSubcollections, subcollectionPoliciesByCollection,
  policyBuckets, costBuckets, entryCost, generateRules, collectionGroups, applyTemplates, subcollectionPolicies, COMMENT_THREAD,
} = require('./generate');

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
const problemsFor = (collections) => validateTable({ collections }, schema);

/** Evaluates a generated rules map literal back into a JS object. */
function rulesMap(rulesText, fn, end) {
  const start = rulesText.indexOf(`function ${fn}(`);
  const open = rulesText.indexOf('return {', start) + 'return '.length;
  const close = rulesText.indexOf(end, open);
  const body = rulesText.slice(open, close + 1).split('\n')
    .filter((l) => !l.trim().startsWith('//')).join('\n')
    .replace(/'/g, '"').replace(/,(\s*[}\]])/g, '$1');
  return JSON.parse(body);
}

/**
 * Evaluates a generated bucketed lookup [fnName](name, ...) for each name,
 * up to its `.get(collection, <fallback>)`, by running the rules expression
 * itself as JavaScript (the bucket tree is plain comparisons, ternaries and
 * map or list literals, which mean the same in both).
 */
function evalLookup(rulesText, fnName, names) {
  const start = rulesText.indexOf(`function ${fnName}(collection`);
  const open = rulesText.indexOf('return (', start) + 'return '.length;
  const close = rulesText.indexOf(').get(collection, ', open);
  const expr = rulesText.slice(open, close + 1).split('\n')
    .filter((l) => !l.trim().startsWith('//')).join('\n');
  const fallbackStart = close + ').get(collection, '.length;
  const fallbackText = rulesText.slice(fallbackStart, rulesText.indexOf(')', fallbackStart));
  const fallback = JSON.parse(fallbackText.replace(/'/g, '"'));
  const fn = new Function('collection', `return ${expr};`);
  return Object.fromEntries(names.map((n) => [n, Object.hasOwn(fn(n), n) ? fn(n)[n] : fallback]));
}

const evalCollectionPolicy = (rulesText, names) => evalLookup(rulesText, 'collectionPolicy', names);

test('firestore.rules is up to date with security/collections.json (run `node security/generate.js`)', () => {
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  assert.equal(generateRules(rules, loadTable()), rules);
});

test('the generated rules maps say exactly what the table says', () => {
  const table = loadTable();
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  const policies = collectionPolicies(table);
  const probes = [...Object.keys(policies), 'zzz_unlisted', 'aaa_unlisted', 'notes', 'Users'];
  const expected = Object.fromEntries(probes.map((n) => [n, policies[n] || {}]));
  assert.deepEqual(evalCollectionPolicy(rules, probes), expected);
  assert.deepEqual(rulesMap(rules, 'selfKeyedSubcollections', '};'), selfKeyedSubcollections(table));
  const serverFields = serverFieldsByCollection(table);
  const readerWrites = readerWritesByCollection(table);
  assert.deepEqual(evalLookup(rules, 'serverFields', probes), Object.fromEntries(probes.map((n) => [n, serverFields[n] || []])));
  assert.deepEqual(evalLookup(rules, 'readerWrites', probes), Object.fromEntries(probes.map((n) => [n, readerWrites[n] || {}])));
  assert.deepEqual(rulesMap(rules, 'serverWrittenSubcollections', '};'), serverWrittenSubcollections(table));
  // subcollectionPolicy(): the collection's map of governed subcollections,
  // then `.get(subcollection, {})`.
  const subProbes = [...Object.keys(table.collections), 'zzz_unlisted', 'aaa_unlisted', 'Users'];
  const byCollection = subcollectionPoliciesByCollection(table);
  assert.match(rules, /\)\.get\(collection, \{\}\)\.get\(subcollection, \{\}\);/);
  assert.deepEqual(evalLookup(rules, 'subcollectionPolicy', subProbes),
    Object.fromEntries(subProbes.map((n) => [n, byCollection[n] || {}])));
  for (const [key, policy] of Object.entries(subcollectionPolicies(table))) {
    const [name, sub] = key.split('/');
    assert.deepEqual(evalLookup(rules, 'subcollectionPolicy', [name])[name][sub], policy, key);
  }
});

test('server-written subcollections are generated and enforced by every subcollection write rule', () => {
  const table = { collections: {
    insurance_applications: { staffApps: ['x'], subcollections: { transactions: { serverWritten: true }, edit_history: {} } },
    users: { subcollections: { metadata: { serverWritten: true, comment: 'access index' } } },
  } };
  assert.deepEqual(serverWrittenSubcollections(table), { 'insurance_applications/transactions': true, 'users/metadata': true });
  assert.deepEqual(expandEntry(table.collections.users), {}, 'subcollections never leak into collectionPolicy()');
  const rules = generateRules(fs.readFileSync(RULES_PATH, 'utf8'), table);
  assert.deepEqual(rulesMap(rules, 'serverWrittenSubcollections', '};'),
    { 'insurance_applications/transactions': true, 'users/metadata': true });

  // The generated map must actually gate the generic subcollection rule's
  // create, update and delete (not only exist).
  const sub = rules.slice(rules.indexOf('match /{subcollection}/{subId} {'));
  const block = sub.slice(0, sub.indexOf('\n      }\n'));
  for (const verb of ['create', 'update', 'delete']) {
    const start = block.indexOf(`allow ${verb}:`);
    const rule = block.slice(start, block.indexOf(';', start));
    assert.match(rule, new RegExp(`subWrite\\(collection, id, subcollection, subId, '${verb}'`), verb);
  }
  assert.match(rules, /function subWrite\([^)]*\) \{[^}]*!serverWrittenSubcollections\(\)\.get\(collection \+ '\/' \+ subcollection, false\)/);
});

test('selfKeyed.selfRead generates selfReadSubcollections(), which routes the generic subcollection read', () => {
  const keyed = (extra) => ({ selfKeyed: { fields: ['userId', 'choiceId'], selfCreate: true, selfDelete: false, ...extra } });
  const table = { collections: {
    polls: { apps: ['polls'], subcollections: { votes: keyed({ selfRead: true }) } },
    events: { apps: ['calendar'], subcollections: { attendees: keyed({}) } },
  } };
  assert.deepEqual(selfReadSubcollections(table), ['polls/votes']);
  assert.equal(selfKeyedSubcollections(table)['polls/votes'].selfRead, undefined, 'writes never see selfRead');
  const rules = generateRules(fs.readFileSync(RULES_PATH, 'utf8'), table);
  assert.match(rules, /function selfReadSubcollections\(\) \{\n {6}return \['polls\/votes'\];/);
  // The generic read passes the subcollection and its doc id, and a listed
  // subcollection reads through selfKeyedRead() instead of the parent's read.
  assert.match(rules, /allow read: if isAuthenticated\(\) &&\n\s+subRead\(collection, id, subcollection, subId, collectionPolicy\(collection\)\);/);
  const fnBody = (name) => {
    const start = rules.indexOf(`function ${name}(`);
    return rules.slice(start, rules.indexOf('\n    }\n', start));
  };
  assert.match(fnBody('subRead'), /\(collection \+ '\/' \+ subcollection\) in selfReadSubcollections\(\)\) \?\n\s+selfKeyedRead\(/);
  assert.match(fnBody('selfKeyedRead'), /subId == request\.auth\.uid && readByIndex\(/);
  assert.match(fnBody('selfKeyedRead'), /grantAdminRead\(ix\)/);
  assert.doesNotMatch(fnBody('selfKeyedRead'), /:admin/, 'the app\'s :admin tier never reads another uid\'s ballot');

  assert.deepEqual(problemsFor({ polls: { apps: ['polls'], subcollections: { votes: keyed({ selfRead: true }) } } }), []);
  assert.ok(problemsFor({ inbox: { kind: 'personal', subcollections: { votes: keyed({ selfRead: true }) } } })
    .some((p) => /selfRead applies under a tenant collection only/.test(p)));
  assert.ok(problemsFor({ polls: { apps: ['polls'], subcollections: { votes: { ...keyed({ selfRead: true }), collectionGroup: { readerField: 'userId' } } } } })
    .some((p) => /combines selfKeyed.selfRead and collectionGroup/.test(p)));
});

test('readerMayUpdate/readerMayDelete generate readerWrites() and gate only the reader\'s own update/delete', () => {
  const table = { collections: {
    inbox: { kind: 'server', readerField: 'recipientId', readerMayUpdate: ['isRead'], readerMayDelete: true },
    receipts: { kind: 'server', readerField: 'uid', readerMayUpdate: ['seenAt', 'archived'] },
    ledger: { kind: 'server', readerField: 'uid' },
  } };
  assert.deepEqual(readerWritesByCollection(table), {
    inbox: { field: 'recipientId', update: ['isRead'], delete: true },
    receipts: { field: 'uid', update: ['seenAt', 'archived'], delete: false },
  });
  assert.deepEqual(expandEntry(table.collections.inbox),
    { kind: 'server', blockCreate: true, blockUpdate: true, blockDelete: true, serverOnly: true, readerField: 'recipientId' },
    'reader writes never leak into collectionPolicy()');
  const rules = generateRules(fs.readFileSync(RULES_PATH, 'utf8'), table);
  const readerWrites = readerWritesByCollection(table);
  const names = [...Object.keys(readerWrites), 'notes'];
  assert.deepEqual(evalLookup(rules, 'readerWrites', names), Object.fromEntries(names.map((n) => [n, readerWrites[n] || {}])));

  // The kind "server" update and delete consult them; create never does.
  const fn = (name) => rules.slice(rules.indexOf(`function ${name}(`), rules.indexOf('\n    }\n', rules.indexOf(`function ${name}(`)));
  assert.match(fn('docUpdate'), /k == 'server' \? readerUpdate\(collection, before, changed\)/);
  assert.match(fn('docDelete'), /k == 'server' \? readerDelete\(collection, d\)/);
  assert.doesNotMatch(fn('docCreate'), /reader/);
  // Only the reader, only the listed fields.
  assert.match(fn('readerUpdate'), /before\.get\(cfg\.get\('field', ''\), ''\) == request\.auth\.uid/);
  assert.match(fn('readerUpdate'), /changed\.hasOnly\(cfg\.get\('update', \[\]\)\)/);

  const problems = (collections) => problemsFor(collections);
  assert.deepEqual(problems(table.collections), []);
  assert.ok(problems({ a: { serverWritten: true, readerMayUpdate: ['x'] } }).length, 'needs kind server');
  assert.ok(problems({ a: { kind: 'personal', readerField: 'uid' } }).length, 'readerField needs server or tenant');
  assert.deepEqual(problems({ a: { serverWritten: true, auditTrail: true, auditAppId: 'users' } }), []);
  assert.ok(problems({ a: { serverWritten: true, auditAppId: 'users' } }).length, 'auditAppId needs auditTrail');
  assert.ok(problems({ a: { auditTrail: true, auditAppId: 'Not An App' } }).length, 'auditAppId must be an app id');
  assert.ok(problems({ a: { kind: 'server', auditAppId: 'users' } }).length, 'auditAppId needs auditTrail');
  // auditRedact: field names or dotted paths into a map, on audited collections only.
  assert.deepEqual(problems({ a: { auditTrail: true, auditRedact: ['token', 'details.secureUrl'] } }), []);
  assert.ok(problems({ a: { auditRedact: ['token'] } }).length, 'auditRedact needs auditTrail');
  assert.ok(problems({ a: { auditTrail: true, auditRedact: [] } }).length, 'auditRedact lists something');
  assert.ok(problems({ a: { auditTrail: true, auditRedact: ['a b'] } }).length, 'auditRedact names fields');
  assert.ok(problems({ a: { auditTrail: true, auditRedact: ['x', 'x'] } }).length, 'auditRedact names each field once');
  // auditExempt: only the allowlisted deliveries and ledgers, never an app's own collection.
  assert.deepEqual(problems({ notifications: { kind: 'server', auditExempt: 'Delivery, not a record: a message about a change.' } }), []);
  assert.ok(problems({ notes: { apps: ['notes'], auditExempt: 'Not a record, honest: just some notes here.' } }).length, 'not allowlisted');
  assert.deepEqual(problems({ credits: { kind: 'server', auditTrail: true, subcollections: { ledger: { serverWritten: true, auditExempt: 'Append-only ledger entries, each the record itself.' } } } }), []);
  assert.ok(problems({ credits: { kind: 'server', subcollections: { ledger: { serverWritten: true, auditExempt: 'Append-only ledger entries, each the record itself.' } } } }).length, 'ledger needs an audited parent');
  assert.ok(problems({ things: { kind: 'server', auditTrail: true, subcollections: { history: { serverWritten: true, auditExempt: 'History entries that someone thinks need no trail.' } } } }).length, 'only ledgers');
  assert.ok(problems({ a: { kind: 'server', readerMayDelete: true } }).length, 'needs a readerField');
  assert.ok(problems({ a: { kind: 'server', readerField: 'uid', readerMayUpdate: ['uid'] } }).length,
    'the reader may not reassign the doc');
  assert.ok(problems({ a: { kind: 'server', readerField: 'uid', readerMayDelete: false } }).length, 'readerMayDelete must be true');
});

test('notifications: recipients may only mark read or delete their own (rules plan T8)', () => {
  const { notifications } = loadTable().collections;
  assert.equal(notifications.kind, 'server');
  assert.equal(notifications.readerField, 'recipientId');
  assert.deepEqual(notifications.readerMayUpdate, ['isRead']);
  assert.equal(notifications.readerMayDelete, true);
});

test('collectionPolicy() is split into small sorted buckets (Firestore\'s 1000-expression limit)', () => {
  const buckets = policyBuckets(loadTable());
  const names = buckets.flatMap((b) => b.entries.map((e) => e.name));
  assert.deepEqual(names, [...names].sort(), 'sorted');
  for (const b of buckets) {
    assert.ok(b.entries.length === 1 || b.cost <= 40, `bucket starting ${b.entries[0].name} costs ${b.cost}`);
    assert.equal(b.cost, b.entries.reduce((sum, e) => sum + entryCost(e.policy), 0));
  }
  assert.equal(entryCost({ blockCreate: true, adminOnly: ['a', 'b'] }), 6);
});

test('every per-collection lookup on a write path is bucketed, so the table\'s size never taxes a request', () => {
  // serverFields(), readerWrites() and subcollectionPolicy() run on writes;
  // a flat map literal or a linear chain of name comparisons costs every
  // entry on every call, which ran denied insurance updates out of the
  // 1000-expression budget.
  const table = loadTable();
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  for (const [fn, end, entries] of [
    ['serverFields', 'serverFields', Object.entries(serverFieldsByCollection(table)).map(([name, v]) => ({ name, cost: entryCost(v) }))],
    ['readerWrites', 'readerWrites', Object.entries(readerWritesByCollection(table)).map(([name, v]) => ({ name, cost: entryCost(v) }))],
    ['subcollectionPolicy', 'subcollectionPolicies',
      Object.entries(subcollectionPoliciesByCollection(table)).map(([name, v]) => ({ name, cost: entryCost(v) }))],
  ]) {
    const body = rules.slice(rules.indexOf(`function ${fn}(collection`), rules.indexOf(`END GENERATED ${end}`));
    assert.match(body, /return \(\n/, `${fn}() picks a bucket by name`);
    assert.match(body, /\)\.get\(collection, /, `${fn}() looks its collection up through the tree`);
    assert.doesNotMatch(body, /return \{/, `${fn}() never returns one flat map literal`);
    assert.doesNotMatch(body, /collection == /, `${fn}() never compares names one by one`);
    for (const b of costBuckets(entries)) {
      assert.ok(b.entries.length === 1 || b.cost <= 40, `${fn}: bucket starting ${b.entries[0].name} costs ${b.cost}`);
    }
  }
  assert.deepEqual(costBuckets([]), []);
});

test('kind server may name its owning app; the rules never see it', () => {
  assert.deepEqual(problemsFor({ ok: { kind: 'server', apps: ['notes'], auditTrail: true } }), []);
  assert.deepEqual(expandEntry({ kind: 'server', apps: ['notes'] }),
    { kind: 'server', blockCreate: true, blockUpdate: true, blockDelete: true, serverOnly: true });
  assert.ok(problemsFor({ bad: { kind: 'platform', apps: ['notes'] } }).length > 0, 'other kinds still refuse apps');
  assert.ok(problemsFor({ bad: { kind: 'server', memberRead: true } }).length > 0, 'other tenant keys still refused');
});

test('shorthands expand to the collectionPolicy() keys they stand for', () => {
  assert.deepEqual(expandEntry({ kind: 'server' }),
    { kind: 'server', blockCreate: true, blockUpdate: true, blockDelete: true, serverOnly: true });
  assert.deepEqual(expandEntry({ kind: 'server', readerField: 'uid' }),
    { kind: 'server', blockCreate: true, blockUpdate: true, blockDelete: true, serverOnly: true, readerField: 'uid' });
  assert.deepEqual(expandEntry({ serverWritten: true, comment: 'x' }), { blockCreate: true, blockUpdate: true, blockDelete: true });
  assert.deepEqual(expandEntry({ kind: 'tenant', apps: ['notes'] }), { apps: ['notes'] }, 'tenant is the default kind');
  assert.deepEqual(Object.keys(expandEntry({ singleOwner: true, blockDelete: true })), ['singleOwner', 'blockDelete'],
    'raw keys keep their order');
  assert.deepEqual(expandEntry({ kind: 'platform', adminWritable: true }), { kind: 'platform', adminWritable: true });
  assert.deepEqual(expandEntry({ naturalKeyIds: true }), {}, 'naturalKeyIds is shim data (generate_dart.js), not a rules key');
  assert.deepEqual(expandEntry({ kind: 'platform', serverFields: ['a', 'b'] }), { kind: 'platform' },
    'serverFields goes to its own serverFields() map, keeping collectionPolicy() out of hot paths');
  assert.deepEqual(expandEntry({ subcollections: { a: { selfKeyed: { fields: ['x'], selfCreate: false, selfDelete: false } } } }), {});
});

test('the validator rejects tables that would generate wrong or ambiguous rules', () => {
  assert.deepEqual(problemsFor({ ok: { kind: 'server', readerField: 'uid' } }), []);
  const cases = {
    'unknown key': { a: { blokCreate: true } },
    'wrong type': { a: { blockCreate: 'yes' } },
    'empty field list': { a: { adminOnly: [] } },
    'two shorthands': { a: { kind: 'server', serverWritten: true } },
    'shorthand plus its expansion': { a: { serverWritten: true, blockDelete: true } },
    'raw serverOnly': { a: { blockCreate: true, serverOnly: true } },
    'readerField on a personal collection': { a: { kind: 'personal', readerField: 'uid' } },
    'tenant-only key on another kind': { a: { kind: 'platform', apps: ['x'] } },
    'serverWritten on another kind': { a: { kind: 'personal', serverWritten: true } },
    'invalid app id': { a: { apps: ['insurance_admin'] } },
    'invalid staff app id': { a: { staffApps: ['continuing_education'] } },
    'public without a source or projection': { public_a: { kind: 'public' } },
    'public not named public_<source>': { a: { publishTo: 'public_a' }, pub_a: { kind: 'public', source: 'a', projection: ['x'] } },
    'public source without publishTo': { a: {}, public_a: { kind: 'public', source: 'a', projection: ['x'] } },
    'publishTo to a missing public entry': { a: { publishTo: 'public_a' } },
    'publishTo on another name': { a: { publishTo: 'public_b' }, public_b: { kind: 'public', source: 'b', projection: ['x'] }, b: { publishTo: 'public_b' } },
    'public source not tenant': { a: { kind: 'platform', publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'] } },
    'public projection with tenant identity': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x', 'ownerIds'] } },
    'public projection with a reserved field': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['sourceGroupId'] } },
    'public fileFields outside the projection': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'], fileFields: ['y'] } },
    'public with a client grant': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'], adminWritable: true } },
    'public with subcollections': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'], subcollections: { s: {} } } },
    'public with an object publishWhen value': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'], publishWhen: { s: {} } } },
    'public keys on a tenant entry': { a: { projection: ['x'] } },
    'unknown publishTier': { a: { publishTo: 'public_a' }, public_a: { kind: 'public', source: 'a', projection: ['x'], publishTier: 'anyone' } },
    'a removed rollout key': { a: { enforce: 'enforced' } },
    'a removed rollout stage': { a: { stage: 4 } },
    'collectionGroup without a reader': { a: { subcollections: { s: { collectionGroup: {} } } } },
    'negative clearance': { a: { requiredClearance: -1 } },
    'single quote': { a: { adminOnly: ["it's"] } },
    'bad collection name': { 'a/b': { serverWritten: true } },
    'adminWritable on a server collection': { a: { kind: 'server', adminWritable: true } },
    'developerWritable on a personal collection': { a: { kind: 'personal', developerWritable: true } },
    'serverFields on a serverWritten collection': { a: { serverWritten: true, serverFields: ['x'] } },
    'adminWritable not true': { a: { adminWritable: false } },
    'naturalKeyIds not true': { a: { naturalKeyIds: false } },
    'selfKeyed missing flags': { a: { subcollections: { s: { selfKeyed: { fields: ['x'] } } } } },
    'serverWritten not true': { a: { subcollections: { s: { serverWritten: false } } } },
    'serverWritten and selfKeyed': { a: { subcollections: { s: { serverWritten: true,
      selfKeyed: { fields: ['x'], selfCreate: false, selfDelete: false } } } } },
    'memberWrite without singleOwner': { a: { memberWrite: true } },
    'memberWrite not true': { a: { memberWrite: false, singleOwner: true } },
    'memberWrite on another kind': { a: { kind: 'personal', memberWrite: true } },
    'memberWrite with an edit write tier': { a: { memberWrite: true, singleOwner: true, writeTier: 'edit' } },
    'memberWrite with a clearance': { a: { memberWrite: true, singleOwner: true, requiredClearance: 2 } },
    'memberWrite on a serverWritten collection': { a: { memberWrite: true, singleOwner: true, serverWritten: true } },
    'unknown idPattern placeholder': { a: { idPattern: '^<date>_<uid>$' } },
  };
  for (const [label, collections] of Object.entries(cases)) {
    assert.ok(problemsFor(collections).length > 0, label);
  }
});

test('the public namespace (D2): a public entry emits only its kind, its source points back', () => {
  const ok = { a: { apps: ['x'], publishTo: 'public_a' },
    public_a: { kind: 'public', source: 'a', projection: ['title', 'photo'], fileFields: ['photo'], publishTier: 'owner',
      publishWhen: { status: 'published', isPublic: true }, requiredFields: ['title'], maxBytes: 4096 } };
  assert.deepEqual(problemsFor(ok), []);
  assert.deepEqual(expandEntry(ok.public_a), { kind: 'public' }, 'projection and publish config never reach the rules');
  assert.deepEqual(expandEntry(ok.a), { apps: ['x'] }, 'publishTo is table data');
  const table = loadTable();
  for (const [name, entry] of Object.entries(table.collections)) {
    if (entry.kind !== 'public') continue;
    assert.equal(name, `public_${entry.source}`);
    assert.equal(table.collections[entry.source].publishTo, name);
  }
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  assert.match(rules, /\(k == 'platform' \|\| k == 'public'\) \? true :/, 'docRead: any signed-in reader');
  assert.match(rules, /\(k == 'public' \|\| p\.get\('blockDelete', false\)\) \? false :/, 'docDelete: never');
});

test('memberWrite and idPattern placeholders: valid shapes and their generated rule', () => {
  assert.deepEqual(problemsFor({ a: { memberWrite: true, singleOwner: true, readerField: 'uid',
    idPattern: '^[0-9]{4}_<groupId>_<uid>$' } }), []);
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  const [usage] = Object.values(evalCollectionPolicy(rules, ['usage_daily']));
  assert.equal(usage.memberWrite, true);
  assert.equal(usage.readerField, 'uid');
  assert.match('2026-11-05_g1_u1', new RegExp(usage.idPattern.replace('<groupId>', 'g1').replace('<uid>', 'u1')));
  // The grant sits in create and update only; delete never reaches it.
  const fnBody = (name) => rules.slice(rules.indexOf(`function ${name}(`), rules.indexOf('\n    }\n', rules.indexOf(`function ${name}(`)));
  assert.match(fnBody('tenantCreate'), /memberWriteOk\(ix, p, d\)/);
  assert.match(fnBody('tenantUpdate'), /memberWriteOk\(ix, p, after\)/);
  for (const fn of ['docDelete', 'mayMutate', 'tenantSubWrite']) assert.doesNotMatch(fnBody(fn), /memberWriteOk/, fn);
  assert.match(fnBody('memberWriteOk'), /isMember\(ix, d\.get\('groupId', ''\)\)/, 'guests are not members');
});

test('a collection listed twice is caught (JSON.parse would silently keep the last)', () => {
  const text = '{"collections": {"a": {"kind": "server"}, "b": {}, "a": {"serverWritten": true}}}';
  assert.deepEqual(duplicateKeys(text), ['a']);
  assert.deepEqual(duplicateKeys('{"a": {"x": 1}, "b": {"x": 2}}'), [], 'same key in different objects is fine');
  assert.ok(validateTable(JSON.parse(text), schema, text).some((p) => p.includes('"a" appears twice')));
});

test('apps permission fields are serverFields, and the admin-writable set is what the plan declares (D4)', () => {
  const table = loadTable();
  assert.deepEqual(table.collections.apps.serverFields, [
    'allowedGroups', 'stewardGroupIds', 'isEmbeddable', 'clientPortal', 'embeddableAccessModes',
    'externalCollections', 'sharedEditing', 'securityTier', 'visibility',
  ]);
  const adminWritable = Object.keys(table.collections).filter((c) => table.collections[c].adminWritable).sort();
  // domain_verifications: the platform team's SES checklist (T14). Not groups:
  // serverWritten since updateGroupDetails / setGroupDefaultHomeScreenApps.
  // executive_advisors / executive_team_settings: the advisor fleet's
  // configuration and round schedule, edited in the Executive Team app.
  assert.deepEqual(adminWritable, [
    'app_categories', 'apps', 'domain_verifications', 'executive_advisors', 'executive_team_settings',
    'platform_config', 'script_runs',
  ]);
  const developerWritable = Object.keys(table.collections).filter((c) => table.collections[c].developerWritable).sort();
  assert.deepEqual(developerWritable, ['app_categories', 'apps', 'domain_verifications', 'platform_config']);
  // Where platform admins may comment on any group's doc (T14 triage screens).
  const adminComments = Object.keys(table.collections).filter((c) => table.collections[c].adminComments).sort();
  assert.deepEqual(adminComments, ['app_requests', 'bug_reports', 'feature_requests']);
});

test('T6/stage 7: one ruleset, kinds, and no open mode left', () => {
  const table = loadTable();
  assert.equal(table.defaults, undefined, 'no rollout default');
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  // An undeclared collection is kind tenant: collectionPolicy() falls back to {}.
  assert.deepEqual(evalCollectionPolicy(rules, ['zzz_unlisted']).zzz_unlisted, {});
  assert.match(rules, /\)\.get\(collection, \{\}\);/);
  // Open mode is gone: no any-depth block, no enforcement switch, no
  // signed-out invitations read; collection groups read only what's declared.
  assert.doesNotMatch(rules, /\{document=\*\*\}/);
  assert.doesNotMatch(rules, /isEnforced|enforcedSubcollections|'enforce'/);
  assert.doesNotMatch(rules, /match \/invitations\//);
  assert.match(rules, /match \/\{path=\*\*\}\/\{group\}\/\{id\} \{\s*allow list: if isAuthenticated\(\) && string\(path\) == '\/' && collectionGroupRead\(group, resource\.data\);/);
  assert.equal(problemsFor({ a: {} }).length, 0);
  assert.ok(validateTable({ defaults: { enforce: 'open' }, collections: {} }, schema).length > 0, 'defaults is gone');
  // collectionGroupRead() has one clause per declared collection group.
  assert.deepEqual(Object.keys(collectionGroups(table)).sort(), ['attendees', 'registrations', 'transactions']);
  assert.match(rules, /\(group == 'attendees' && \(d\.get\('uid', ''\) == request\.auth\.uid\)\)/);
  // The former dedicated blocks are kinds now.
  const kinds = Object.fromEntries(Object.entries(table.collections).filter(([, e]) => e.kind).map(([n, e]) => [n, e.kind]));
  for (const [name, kind] of Object.entries({
    users: 'personal', calendar_user_settings: 'personal', apps: 'platform', categories: 'platform',
    platform_config: 'platform', app_categories: 'platform', collection_catalog: 'platform_admin',
    collection_policies: 'platform_admin', script_runs: 'platform_admin',
  })) assert.equal(kinds[name], kind, name);
  // Fixed app ids (T2's KI-CE-TENANT-ID, KI-STAFF-APP-ID).
  assert.deepEqual(table.collections.ce_events.apps, ['continuing-education']);
  assert.deepEqual(table.collections.insurance_applications.staffApps, ['policy-editor']);
  // Privilege sources on users/{uid} are server-only (plan 4.5).
  for (const f of ['roles', 'status', 'clearance_level']) assert.ok(table.collections.users.serverFields.includes(f), f);
});

test('commentThread gives an entry the shared comment thread, and the governed-subcollection rule enforces it', () => {
  const raw = { collections: { tickets: { apps: ['t'], commentThread: true }, other: { apps: ['o'] } } };
  const table = applyTemplates(raw);
  assert.equal(raw.collections.tickets.subcollections, undefined, 'applyTemplates does not change its input');
  assert.deepEqual(Object.keys(table.collections.tickets.subcollections), ['comments', 'comment_likes']);
  assert.deepEqual(table.collections.other, raw.collections.other);
  assert.deepEqual(subcollectionPolicies(table), {
    'tickets/comments': { auditTrail: true, blockDelete: true, authorField: 'authorId',
      authorMayUpdate: ['text', 'deletedAt', 'deletedBy'], authorEmailField: 'authorEmail', softDelete: true, softDeleteClears: 'text' },
    'tickets/comment_likes': { auditTrail: true, blockDelete: true, boundedList: { field: 'commentIds', max: 500 }, selfKeyed: {
      fields: [...COMMENT_THREAD.comment_likes.selfKeyed.fields, 'lastModifiedAt', 'lastModifiedBy'],
      selfCreate: true, selfDelete: false, threadReaders: true } },
  });
  // A governed selfKeyed config travels in its policy (the likes doc's owner also writes the
  // audit stamp), so its writes never build the generic selfKeyedSubcollections() map.
  assert.equal(selfKeyedSubcollections(table)['tickets/comment_likes'], undefined);
  // Every collection that shows the shared widget declares the thread.
  const committed = loadTable();
  for (const name of ['app_requests', 'bug_reports', 'feature_requests']) {
    assert.equal(committed.collections[name].commentThread, true, name);
    assert.ok(committed.collections[name].subcollections.comments.blockDelete, name);
  }
  const rules = fs.readFileSync(RULES_PATH, 'utf8');
  const fn = (name) => rules.slice(rules.indexOf(`function ${name}(`), rules.indexOf('\n    }\n', rules.indexOf(`function ${name}(`)));
  assert.match(fn('tenantSubWrite'), /subcollectionPolicy\(collection, subcollection\)/);
  assert.match(fn('governedSubWrite'), /blockDelete/);
  assert.match(fn('governedSubWrite'), /authorMayUpdate/);
  // A governed self-keyed doc's owner writes as a tenant reader of the parent unless the
  // entry opts into the thread's reader set (threadReaders: the likes doc).
  assert.match(fn('governedSubWrite'), /keyed\.get\('threadReaders', false\)/);
  assert.match(fn('governedSubWrite'), /grantTenant\(ix, p, 'read', collection, parent\)/);
  assert.match(fn('subFieldsOk'), /auditStampOk\(sp, d, touched\)/);
  assert.match(fn('subFieldsOk'), /request\.time/);
  assert.match(fn('subFieldsOk'), /parent\.get\('groupId', ''\)/);
  assert.match(fn('subFieldsOk'), /request\.auth\.token\.get\('email', null\)/);
  // A reader marks only their own uid in selfArrayFields and their own entry in selfMapFields.
  assert.match(fn('governedSubWrite'), /selfFieldsUpdateOk\(sp\)/);
  assert.match(fn('governedSubWrite'), /selfFieldsCreateOk\(sp\)/);
  // A list gains the caller's uid at its end or loses its one copy (no padding, reordering or duplicates).
  assert.match(fn('selfListOk'), /a\.toSet\(\)\.size\(\) == a\.size\(\)/);
  assert.match(fn('selfListOk'), /a == b\.concat\(\[me\]\)/);
  assert.match(fn('selfListOk'), /a\.size\(\) == b\.size\(\) - 1 && a == b\.removeAll\(\[me\]\)/);
  assert.match(fn('selfMapOk'), /affectedKeys\(\)\.hasOnly\(\[request\.auth\.uid\]\)/);
  assert.match(fn('selfMapOk'), /selfEntryOk\(/);
  assert.match(fn('selfEntryOk'), /v is string && v\.size\(\) <= 64/);
  // The audit stamp rides along only on an audited subcollection.
  assert.match(fn('selfFieldsUpdateOk'), /sp\.get\('auditTrail', false\) \|\| !changed\.hasAny\(\['lastModifiedAt', 'lastModifiedBy'\]\)/);
  assert.match(fn('subFieldsOk'), /createdAt == '' \|\| d\.get\(createdAt, null\) == request\.time/);
  // Nothing is written under a soft-deleted parent, governed or not: one check in tenantSubWrite.
  assert.match(fn('tenantSubWrite'), /parent\.get\('deletedAt', null\) == null/);
});

test('the validator rejects governed subcollections that contradict themselves', () => {
  const sub = (cfg) => problemsFor({ x: { apps: ['x'], subcollections: { s: cfg } } });
  assert.equal(sub({ selfKeyed: { fields: ['a'], selfCreate: true, selfDelete: false, threadReaders: true } }).length, 1,
    'threadReaders needs a governed subcollection');
  assert.deepEqual(sub({ auditTrail: true, blockDelete: true, authorField: 'authorId', authorMayUpdate: ['text'] }), []);
  assert.ok(sub({ serverWritten: true, auditTrail: true }).some((p) => /combines serverWritten/.test(p)));
  assert.ok(sub({ authorField: 'a' }).some((p) => /authorField and authorMayUpdate go together/.test(p)));
  assert.ok(sub({ softDelete: true }).some((p) => /softDelete needs blockDelete/.test(p)));
  assert.ok(sub({ softDelete: true, blockDelete: true, authorField: 'a', authorMayUpdate: ['text'] })
    .some((p) => /must list deletedAt and deletedBy/.test(p)));
  assert.ok(sub({ authorField: 'a', authorMayUpdate: ['a'] }).some((p) => /can't include the authorField/.test(p)));
  assert.ok(sub({ authorEmailField: 'e' }).some((p) => /authorEmailField needs authorField/.test(p)));
  assert.ok(sub({ softDeleteClears: 'text' }).some((p) => /softDeleteClears needs softDelete/.test(p)));
  assert.ok(sub({ boundedList: { field: 'x', max: 5 } }).some((p) => /boundedList.field/.test(p)));
  assert.ok(sub({ authorField: 'a', authorMayUpdate: ['x'], selfKeyed: { fields: ['x'], selfCreate: true, selfDelete: false } })
    .some((p) => /combines authorField and selfKeyed/.test(p)));
  // selfArrayFields / selfMapFields: readers' own-uid fields on an author's doc.
  const author = { authorField: 'senderId', authorMayUpdate: ['text'] };
  assert.deepEqual(sub({ ...author, selfArrayFields: ['readBy'], selfMapFields: ['reactionsByUser'] }), []);
  assert.ok(sub({ blockDelete: true, selfArrayFields: ['readBy'] }).some((p) => /need authorField/.test(p)));
  assert.ok(sub({ ...author, selfArrayFields: ['a', 'b', 'c'] }).some((p) => /more than 2 fields/.test(p)));
  assert.ok(sub({ ...author, selfArrayFields: ['a'], selfMapFields: ['a'] }).some((p) => /listed twice/.test(p)));
  // createdAtField: set to the request time on create, never updated.
  assert.deepEqual(sub({ ...author, createdAtField: 'timestamp' }), []);
  assert.ok(sub({ blockDelete: true, createdAtField: 'timestamp' }).some((p) => /createdAtField needs authorField/.test(p)));
  for (const field of ['text', 'groupId', 'lastModifiedAt']) {
    assert.ok(sub({ ...author, createdAtField: field }).some((p) => /createdAtField needs authorField/.test(p)), field);
  }
  assert.ok(sub({ ...author, selfArrayFields: ['readBy'], createdAtField: 'readBy' }).some((p) => /createdAtField/.test(p)));
  for (const field of ['text', 'senderId', 'ownerIds', 'lastModifiedBy']) {
    assert.ok(sub({ ...author, selfArrayFields: [field] }).some((p) => /can't name the authorField/.test(p)), field);
  }
  assert.ok(problemsFor({ x: { apps: ['x'], commentThread: true, subcollections: { comments: {} } } })
    .some((p) => /clashes with commentThread/.test(p)));
  assert.ok(problemsFor({ x: { kind: 'server', commentThread: true } }).some((p) => /commentThread only applies to kind "tenant"/.test(p)));
});

test('clientReaderListField: tenant kind, one app, and a serverField', () => {
  const ok = { apps: ['invoices'], serverFields: ['clientUids'], clientReaderListField: 'clientUids' };
  assert.deepEqual(problemsFor({ a: ok }), []);
  assert.ok(problemsFor({ a: { ...ok, serverFields: [] } }).some((p) => p.includes('must be in serverFields')));
  assert.ok(problemsFor({ a: { ...ok, apps: ['x', 'y'] } }).some((p) => p.includes('exactly one app')));
  assert.ok(problemsFor({ a: { kind: 'server', clientReaderListField: 'clientUids' } }).length > 0, 'tenant only');
});
