'use strict';

/**
 * Fails when app Dart code shifts by a literal 31 or more (`1 << 32`,
 * `x >> 40`). On the web Dart compiles shifts to 32-bit JavaScript
 * operations: `1 << 31` is negative and `1 << 32` is 0, so code that works
 * on mobile breaks in the browser (Dev Pipeline's `Random.nextInt(1 << 32)`
 * threw a RangeError on every ticket close). Write the constant out
 * (`0x7FFFFFFF`, `4294967296`) or use a helper such as
 * shared_services' newIdempotencyKey() instead.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ROOT, appDartFiles, blankCommentsAndStrings, lineAt } = require('./dart_source');

/** Shifts by a literal of 31 or more in [source]: {line, text}. */
function unsafeShifts(source) {
  const code = blankCommentsAndStrings(source);
  const out = [];
  for (const match of code.matchAll(/(<<|>>>?)=?\s*(\d+)\b/g)) {
    if (Number(match[2]) >= 31) out.push({ line: lineAt(code, match.index), text: match[0].replace(/\s+/g, ' ') });
  }
  return out;
}

test('finds shifts of 31 or more, but not smaller ones, comments or strings', () => {
  const source = [
    'final a = random.nextInt(1 << 32);',
    'final b = x.clamp(0, 1<<31);',
    'final c = 1 << 30;',
    'final d = y >>> 40;',
    'h <<= 33;',
    '// 1 << 32 in a comment',
    "final e = 'a << 64 string';",
  ].join('\n');
  assert.deepEqual(unsafeShifts(source), [
    { line: 1, text: '<< 32' },
    { line: 2, text: '<<31' },
    { line: 4, text: '>>> 40' },
    { line: 5, text: '<<= 33' },
  ]);
});

test('app code never shifts by 31 or more', () => {
  const problems = [];
  for (const file of appDartFiles()) {
    for (const use of unsafeShifts(fs.readFileSync(path.join(ROOT, file), 'utf8'))) {
      problems.push(`${file}:${use.line}: ${use.text}`);
    }
  }
  assert.deepEqual(
    problems,
    [],
    'On the web Dart shifts are 32-bit, so `1 << 31` is negative and `1 << 32` is 0.\n'
      + `Write the constant out (0x7FFFFFFF, 4294967296) instead:\n  ${problems.join('\n  ')}`,
  );
});
