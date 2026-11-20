const test = require('node:test');
const assert = require('node:assert/strict');

const { automationProblems, automationSources } = require('./generate_automation');
const { loadTable } = require('./generate');

const table = (entry) => ({ collections: { things: { apps: ['crm'], ...entry } } });
const block = { events: ['record.updated'], fields: ['stage', 'dueAt'], dateFields: ['dueAt'] };

test('the checked-in table is valid and lists its opted-in collections', () => {
  const real = loadTable();
  assert.deepEqual(automationProblems(real), []);
  const sources = automationSources(real);
  assert.ok(sources.ce_profiles.dateFields.includes('cycleEndDate'));
  assert.equal(sources['projects/tasks'].parent, 'projects');
  assert.equal(sources['projects/tasks'].appId, 'lists');
  // help_tickets is kind server: only Help Desk's callables write it.
  assert.deepEqual(sources.help_tickets.writableFields, []);
  // serverFields never become writable, whatever the block lists.
  assert.ok(!sources.invoicing_documents.writableFields.includes('status'));
});

test('a valid block generates the engine config', () => {
  assert.deepEqual(automationProblems(table({ automation: block, auditTrail: true })), []);
  assert.deepEqual(automationSources(table({ automation: block, auditTrail: true })).things, {
    appId: 'crm',
    events: ['record.updated'],
    fields: ['dueAt', 'stage'],
    fieldTypes: { dueAt: 'date' },
    dateFields: ['dueAt'],
    webhookFields: [],
    writableFields: ['dueAt', 'stage'],
    audited: true,
  });
});

test('writableFields leaves out locked, identity and uid fields, and narrows to the block\'s own list', () => {
  const fields = ['title', 'stage', 'status', 'ownerId', 'assignee', 'kind', 'note'];
  const entry = {
    serverFields: ['status'],
    immutable: ['kind'],
    automation: { events: ['record.updated'], fields, fieldTypes: { assignee: 'uid' } },
  };
  assert.deepEqual(automationSources(table(entry)).things.writableFields, ['note', 'stage', 'title']);
  const narrowed = { ...entry, automation: { ...entry.automation, writableFields: ['note', 'status'] } };
  assert.deepEqual(automationSources(table(narrowed)).things.writableFields, ['note']);
  assert.deepEqual(automationSources(table({ ...entry, kind: 'server' })).things.writableFields, []);
});

test('a subcollection block is keyed parent/sub, belongs to the parent\'s app and drives no schedule', () => {
  const sub = { subcollections: { items: { automation: { label: 'Items', events: ['record.created'], fields: ['text'] } } } };
  assert.deepEqual(automationProblems(table(sub)), []);
  const source = automationSources(table(sub))['things/items'];
  assert.equal(source.parent, 'things');
  assert.equal(source.subcollection, 'items');
  assert.equal(source.label, 'Items');
  assert.equal(source.appId, 'crm');
  const dated = { subcollections: { items: { automation: { events: ['record.created'], fields: ['dueAt'], dateFields: ['dueAt'] } } } };
  assert.match(automationProblems(table(dated)).join('\n'), /can't drive schedules/);
});

test('bad blocks are refused with a reason', () => {
  const problems = (entry) => automationProblems(table(entry)).join('\n');
  assert.match(problems({ automation: { ...block, events: ['record.moved'] } }), /events must list/);
  assert.match(problems({ automation: { ...block, fields: [] } }), /fields must list/);
  assert.match(problems({ automation: { ...block, fields: ['stage', 'lastModifiedBy'] } }), /can't expose lastModifiedBy/);
  assert.match(problems({ automation: { ...block, dateFields: ['createdAt'] } }), /dateFields must list fields from/);
  assert.match(problems({ automation: { ...block, webhookFields: ['secret'] } }), /webhookFields must list fields from/);
  assert.match(problems({ automation: { ...block, writableFields: ['secret'] } }), /writableFields must list fields from/);
  assert.match(problems({ automation: { ...block, fieldTypes: { stage: 'colour' } } }), /must be one of/);
  assert.match(problems({ automation: { ...block, fieldTypes: { dueAt: 'string' } } }), /is a date field/);
  assert.match(problems({ automation: { ...block, fieldTypes: { other: 'string' } } }), /isn't in/);
  assert.match(problems({ automation: { ...block, extra: true } }), /extra isn't an automation setting/);
  assert.match(problems({ automation: block, apps: ['crm', 'sales'] }), /exactly one app/);
  assert.match(problems({ automation: block, kind: 'personal' }), /kind "tenant" or "server"/);
});

test('fieldCheck exemptions name exposed fields and say where they are written, and stay out of the engine config', () => {
  const exempt = { ...block, fieldCheck: { stage: 'written by the import job' } };
  assert.deepEqual(automationProblems(table({ automation: exempt })), []);
  assert.ok(!('fieldCheck' in automationSources(table({ automation: exempt })).things));
  const problems = automationProblems(table({ automation: { ...block, fieldCheck: { other: 'x', stage: ' ' } } }));
  assert.ok(problems.some((p) => /fieldCheck\.other isn't in/.test(p)));
  assert.ok(problems.some((p) => /fieldCheck\.stage must say where/.test(p)));
});
