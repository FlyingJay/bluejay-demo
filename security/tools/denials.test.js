'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { parseArgs, windowStartMs, groupReports, formatGroups } = require('./denials');

const T0 = Date.parse('2026-11-05T17:30:00Z');

test('parseArgs and windowStartMs: --since overrides --minutes', () => {
  assert.equal(windowStartMs(parseArgs([]), T0), T0 - 60 * 60 * 1000);
  assert.equal(windowStartMs(parseArgs(['--minutes', '15']), T0), T0 - 15 * 60 * 1000);
  assert.equal(windowStartMs(parseArgs(['--minutes', '15', '--since', '2026-11-05T17:00:00Z']), T0),
    Date.parse('2026-11-05T17:00:00Z'));
  assert.throws(() => windowStartMs(parseArgs(['--since', 'yesterday-ish']), T0), /not a date/);
  assert.throws(() => parseArgs(['--bogus']), /Unknown option/);
  assert.throws(() => parseArgs(['--minutes', '0']), /positive/);
});

test('groupReports groups by (service, collection, op, app) with distinct users and first/last seen', () => {
  const r = (extra) => ({
    service: 'firestore', collection: 'notes', op: 'list', appId: 'notes', uid: 'u1', groupId: 'g1',
    filterFields: ['groupId'], clientVersion: 'abcdef123', receivedAtMs: T0, ...extra,
  });
  const groups = groupReports([
    r({}),
    r({ uid: 'u2', receivedAtMs: T0 + 60_000, filterFields: ['creatorId'] }),
    r({ uid: 'u1', receivedAtMs: T0 - 60_000 }),
    r({ uid: null }),
    r({ op: 'get' }),
    r({ service: 'storage', collection: 'groups/{groupId}/apps/notes/files', op: 'upload' }),
  ]);
  assert.equal(groups.length, 3);
  const [top] = groups;
  assert.equal(top.op, 'list');
  assert.equal(top.count, 4);
  assert.equal(top.distinctUsers, 2);
  assert.equal(top.signedOut, 1);
  assert.deepEqual(top.filterFields, ['creatorId', 'groupId']);
  assert.equal(top.firstSeen, new Date(T0 - 60_000).toISOString());
  assert.equal(top.lastSeen, new Date(T0 + 60_000).toISOString());

  const text = formatGroups(groups, { sinceMs: T0, total: 6, truncated: false });
  assert.match(text, /6 report\(s\), 3 group\(s\)/);
  assert.match(text, /storage:groups\/\{groupId\}\/apps\/notes\/files\s+upload/);
  assert.match(formatGroups([], { sinceMs: T0, total: 0 }), /None\./);
});
