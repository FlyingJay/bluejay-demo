'use strict';
/**
 * The generated matrix (plan 6.2): every collection in
 * security/collections.json and the undeclared default, persona x fixture x
 * operation, plus collection-group queries, against the committed
 * firestore.rules, in the emulator. Each decision must equal
 * lib/expected.js' for the same table. Also fails if any request hits
 * Firestore's 1000-expression limit.
 *
 * The cases are split into RULES_MATRIX_SHARDS shards (default
 * DEFAULT_SHARDS), round-robin by index, so every shard gets the same mix of
 * operations and collections and takes about as long as the others. CI runs
 * each shard in its own job, with its own emulator
 * (.github/workflows/rules-tests.yml): RULES_MATRIX_SHARD=<1..N> runs only
 * that shard. Without it, test/matrix.test.js runs every shard, one after
 * another.
 *
 * RULES_MATRIX_FULL=1 runs the full matrix for every entry instead of one
 * representative per equivalence class (see lib/generate_matrix.js).
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const { setup } = require('./personas');
const { generateMatrix } = require('./generate_matrix');
const { createEvaluator, KNOWN_ISSUES } = require('./expected');
const gen = require('../../generate');
const { runCases, EXPRESSION_LIMIT } = require('./run');
const { toRequest } = require('./request');

const FULL = process.env.RULES_MATRIX_FULL === '1';

/**
 * Collections whose denied writes may run out of the expression budget
 * instead of being refused by a rule (KI-DENY-PATH-COST). Anywhere else, and
 * on any request that should be allowed, hitting the limit fails the test.
 */
const DENY_PATH_EXHAUSTION = new Set([]);

/** Shards when RULES_MATRIX_SHARDS is unset. */
const DEFAULT_SHARDS = 3;

/** A positive integer from env var [name], or [fallback] when unset. */
function envInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} must be a positive integer, got ${JSON.stringify(raw)}`);
  return n;
}

const SHARDS = envInt('RULES_MATRIX_SHARDS', DEFAULT_SHARDS);

/**
 * Registers the matrix tests: shard RULES_MATRIX_SHARD (1-based) of SHARDS
 * when set, else every shard.
 */
function registerMatrix() {
  const only = envInt('RULES_MATRIX_SHARD', 0);
  if (only > SHARDS) throw new Error(`RULES_MATRIX_SHARD=${only} is past RULES_MATRIX_SHARDS=${SHARDS}`);
  for (let shard = 0; shard < SHARDS; shard++) if (!only || only === shard + 1) matrixShard(shard);
}

/** Registers the test for shard [shard] (0-based) of SHARDS (cases round-robin by index). */
function matrixShard(shard) {
  test(`generated rules matrix matches the expected-spec evaluator (shard ${shard + 1}/${SHARDS})`, { timeout: 30 * 60 * 1000 }, async () => {
    const table = gen.loadTable();
    const t = await setup(`demo-bluejay-matrix-${shard}`, { rules: fs.readFileSync(gen.RULES_PATH, 'utf8') });
    try {
      const evaluate = createEvaluator(table);
      const generated = generateMatrix({ table, full: FULL });
      const { classes, collections } = generated;
      // RULES_MATRIX_ONLY=<regex>: run only the cases whose key matches (local debugging).
      const only = process.env.RULES_MATRIX_ONLY ? new RegExp(process.env.RULES_MATRIX_ONLY) : null;
      const cases = generated.cases.filter((c, i) => i % SHARDS === shard && (!only || only.test(c.key)));
      const started = Date.now();
      const results = await runCases(t, cases);
      const seconds = ((Date.now() - started) / 1000).toFixed(1);

      const mismatches = [];
      const costFailures = [];
      const issueCounts = {};
      let allowed = 0;
      let exhaustedDenies = 0;
      cases.forEach((c, i) => {
        const got = results[i];
        const want = evaluate(toRequest(c, t.indexes));
        if (got.allow) allowed += 1;
        if (got.message.includes(EXPRESSION_LIMIT) && !(want.allow === false && DENY_PATH_EXHAUSTION.has(c.collection))) {
          costFailures.push(c.key);
        } else if (got.message.includes(EXPRESSION_LIMIT)) {
          exhaustedDenies += 1;
        }
        for (const ki of want.knownIssues) issueCounts[ki] = (issueCounts[ki] || 0) + 1;
        if (got.allow !== want.allow) {
          mismatches.push(`${c.key}: rules ${got.allow ? 'ALLOW' : 'DENY'}, expected ${want.allow ? 'ALLOW' : 'DENY'}` +
            (want.knownIssues.length ? ` [${want.knownIssues.join(', ')}]` : '') +
            (got.message ? `\n      ${got.message.split('\n').filter(Boolean).slice(-1)[0].slice(0, 220)}` : ''));
        }
      });

      if (process.env.RULES_MATRIX_DUMP) {
        require('fs').writeFileSync(`${process.env.RULES_MATRIX_DUMP}.${shard}`, JSON.stringify(cases.map((c, i) => ({
          key: c.key, allow: results[i].allow, message: results[i].message, want: evaluate(toRequest(c, t.indexes)),
        }))));
      }
      console.log(`matrix shard ${shard + 1}/${SHARDS}: ${cases.length} of ${generated.cases.length} cases (${allowed} allowed) over ${collections.length} collections, ` +
        `${Object.keys(classes).length} policy classes${FULL ? ', full mode' : ''}, in ${seconds}s ` +
        `(${results.filter((r) => r.resent).length} write(s) re-sent by the SDK and verified applied)`);
      issueCounts['KI-DENY-PATH-COST'] = exhaustedDenies;
      for (const [ki, n] of Object.entries(issueCounts).sort()) console.log(`  ${ki}: ${n} case(s) pinned`);

      assert.deepEqual(costFailures.slice(0, 20), [],
        `${costFailures.length} request(s) hit the 1000-expression limit outside the pinned KI-DENY-PATH-COST collections`);
      assert.equal(mismatches.length, 0,
        `${mismatches.length} case(s) differ from lib/expected.js:\n  ${mismatches.slice(0, 60).join('\n  ')}`);
      for (const ki of Object.keys(issueCounts)) assert.ok(KNOWN_ISSUES[ki], `unknown issue id ${ki}`);
    } finally {
      await t.teardown();
    }
  });
}

module.exports = { registerMatrix, matrixShard, SHARDS };
