'use strict';
/**
 * Every collection, against the committed firestore.rules: what the
 * 2025-12-16 permissive release granted everywhere and the rules must not.
 * Stage 7 (plan 8.3) deleted the open mode that reproduced that release, so
 * this checks, for every declared collection and an undeclared one:
 * signed-out callers get nothing; nothing two subcollections down is
 * readable or writable by anyone (admins included); an unfiltered list of
 * another group's docs is denied; collection-group queries read only the
 * declared groups. Each decision must equal lib/expected.js'.
 * (fixtures/live-firestore-2025-12-16.rules is kept only as the documented
 * emergency rollback, security/RULES_ROLLBACK.md.)
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const gen = require('../../generate');
const { setup } = require('../lib/personas');
const { everyCollectionCases } = require('../lib/generate_matrix');
const { createEvaluator } = require('../lib/expected');
const { runCases, EXPRESSION_LIMIT } = require('../lib/run');
const { toRequest } = require('../lib/request');

test('every collection: no signed-out access, nothing below one subcollection, declared collection groups only', { timeout: 20 * 60 * 1000 }, async () => {
  const table = gen.loadTable();
  const cases = everyCollectionCases({ table });
  const evaluate = createEvaluator(table);
  const t = await setup('demo-bluejay-every', { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') });
  try {
    const results = await runCases(t, cases);
    const problems = [];
    let allowed = 0;
    cases.forEach((c, i) => {
      const got = results[i].allow;
      if (got) allowed += 1;
      if (results[i].message.includes(EXPRESSION_LIMIT)) problems.push(`${c.key}: hit the expression limit`);
      const want = evaluate(toRequest(c, t.indexes)).allow;
      if (got !== want) problems.push(`${c.key}: rules ${got ? 'ALLOW' : 'DENY'}, lib/expected.js ${want ? 'ALLOW' : 'DENY'}`);
      if (c.persona === 'anon' && got) problems.push(`${c.key}: a signed-out caller was allowed`);
      if (c.fixture === 'deep' && got) problems.push(`${c.key}: a doc two subcollections down was reachable`);
    });
    console.log(`every collection: ${cases.length} cases (${allowed} allowed)`);
    assert.deepEqual(problems.slice(0, 40), [], `${problems.length} case(s) differ`);
  } finally {
    await t.teardown();
  }
});
