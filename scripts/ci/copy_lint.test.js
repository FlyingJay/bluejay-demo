'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  lintDiff, parseRules, globToRegExp, parseAddedLines, lintLine, ruleApplies, skipFile, ALLOW_MARKER,
} = require('./copy_lint');

const TABLE = [
  'Intro text with a | pipe that is not a table.',
  '',
  '| Pattern | Files | Except | Message | Decision |',
  '|---|---|---|---|---|',
  '| `\\bAcmeCo\\b` | `**/*.md`, `**/*.dart` | `docs/old/**` | Write "Acme". | 2026-01-01, test |',
  '| `(?i)\\bfast\\|quick\\b` | `**` | | No speed words. | 2026-01-02, test |',
  '',
  '| Other | Table |',
  '|---|---|',
  '| `\\bignored\\b` | x |',
].join('\n');

test('parseRules reads the rules table and stops at its end', () => {
  const rules = parseRules(TABLE);
  assert.equal(rules.length, 2);
  assert.equal(rules[0].pattern, '\\bAcmeCo\\b');
  assert.deepEqual(rules[0].files, ['**/*.md', '**/*.dart']);
  assert.deepEqual(rules[0].except, ['docs/old/**']);
  assert.equal(rules[0].message, 'Write "Acme".');
  assert.equal(rules[0].decision, '2026-01-01, test');
  assert.equal(rules[0].regex.flags, '');
  assert.deepEqual(rules[1].except, []);
});

test('parseRules turns (?i) into the i flag and \\| into an alternation', () => {
  const [, rule] = parseRules(TABLE);
  assert.equal(rule.pattern, '(?i)\\bfast|quick\\b');
  assert.equal(rule.regex.source, '\\bfast|quick\\b');
  assert.equal(rule.regex.flags, 'i');
  assert.ok(rule.regex.test('QUICK'));
  assert.ok(rule.regex.test('Fast'));
});

test('parseRules rejects a bad regex, a row with no files and a missing table', () => {
  const head = '| Pattern | Files | Except | Message | Decision |\n|---|---|---|---|---|\n';
  assert.throws(() => parseRules(`${head}| \`(\` | \`**\` | | m | d |`), /line 3: bad pattern/);
  assert.throws(() => parseRules(`${head}| \`a\` | | | m | d |`), /no Files globs/);
  assert.throws(() => parseRules('no table here'), /no rules table/);
});

test('the repository COPY_RULES.md parses, and every rule names files and a decision', () => {
  const rules = parseRules(fs.readFileSync(path.join(__dirname, '..', '..', 'COPY_RULES.md'), 'utf8'));
  assert.ok(rules.length >= 1);
  for (const r of rules) {
    assert.ok(r.files.length, r.pattern);
    assert.match(r.decision, /\d{4}-\d{2}-\d{2}/, `${r.pattern} needs a dated decision`);
    assert.ok(r.message.length > 10, r.pattern);
  }
});

test('the brand rule flags misspellings in text but not inside identifiers', () => {
  // Built from parts so this file passes scripts/check_brand_name.js and the rule itself.
  const wrong = ['Blue', 'Jay'].join('');
  const rules = parseRules(fs.readFileSync(path.join(__dirname, '..', '..', 'COPY_RULES.md'), 'utf8'));
  const brand = rules.filter((r) => r.regex.test('Bluejay') === false && r.regex.test(`Welcome to ${wrong}`));
  assert.equal(brand.length, 1);
  for (const ok of ['Bluejay', `${wrong}App`, `k${wrong}Theme`, 'bluejay.gg', 'Blue Jays']) {
    assert.equal(brand[0].regex.test(ok), false, ok);
  }
});

test('globToRegExp handles **, * and ?', () => {
  const g = (glob, file) => globToRegExp(glob).test(file);
  assert.ok(g('**/*.md', 'README.md'));
  assert.ok(g('**/*.md', 'a/b/c.md'));
  assert.ok(!g('**/*.md', 'a/b/c.mdx'));
  assert.ok(g('**', 'any/thing.txt'));
  assert.ok(g('docs/*.md', 'docs/a.md'));
  assert.ok(!g('docs/*.md', 'docs/sub/a.md'));
  assert.ok(g('documentation/**/user.md', 'documentation/crm/user.md'));
  assert.ok(g('documentation/**/user.md', 'documentation/user.md'));
  assert.ok(g('file?.js', 'file1.js'));
  assert.ok(!g('file?.js', 'file12.js'));
  assert.ok(!g('a.b', 'aXb'), 'dots are literal');
});

test('ruleApplies uses Files and Except', () => {
  const [rule] = parseRules(TABLE);
  assert.ok(ruleApplies(rule, 'docs/new/a.md'));
  assert.ok(ruleApplies(rule, 'lib/x.dart'));
  assert.ok(!ruleApplies(rule, 'docs/old/a.md'));
  assert.ok(!ruleApplies(rule, 'lib/x.js'));
});

test('lintLine reports hits and skips lines with the allow marker', () => {
  const rules = parseRules(TABLE);
  const hits = lintLine(rules, 'a.md', 7, 'AcmeCo is fast');
  assert.deepEqual(hits.map((h) => [h.line, h.match]), [[7, 'AcmeCo'], [7, 'fast']]);
  assert.deepEqual(lintLine(rules, 'a.md', 7, `AcmeCo is fast <!-- ${ALLOW_MARKER} -->`), []);
  assert.deepEqual(lintLine(rules, 'docs/old/a.md', 1, 'AcmeCo'), []);
});

test('parseAddedLines keeps only added lines, numbered in the new file', () => {
  const diff = [
    'diff --git a/a.md b/a.md',
    'index 1111111..2222222 100644',
    '--- a/a.md',
    '+++ b/a.md',
    '@@ -3 +3 @@',
    '-old line',
    '+new line three',
    '@@ -10,0 +11,2 @@',
    '+added eleven',
    '+++ looks like a header',
    '\\ No newline at end of file',
    'diff --git a/gone.md b/gone.md',
    'deleted file mode 100644',
    '--- a/gone.md',
    '+++ /dev/null',
    '@@ -1 +0,0 @@',
    '-was here',
    'diff --git a/new dir/n.md b/new dir/n.md',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/new dir/n.md',
    '@@ -0,0 +1 @@',
    '+first',
    'diff --git a/img.png b/img.png',
    'Binary files a/img.png and b/img.png differ',
  ].join('\n');
  const added = parseAddedLines(diff);
  assert.deepEqual([...added.keys()], ['a.md', 'new dir/n.md']);
  assert.deepEqual(added.get('a.md'), [
    { line: 3, text: 'new line three' },
    { line: 11, text: 'added eleven' },
    { line: 12, text: '++ looks like a header' },
  ]);
  assert.deepEqual(added.get('new dir/n.md'), [{ line: 1, text: 'first' }]);
});

test('parseAddedLines counts context lines when the diff has them', () => {
  const diff = 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,4 @@\n one\n+two\n three\n+four\n';
  assert.deepEqual(parseAddedLines(diff).get('x'), [{ line: 2, text: 'two' }, { line: 4, text: 'four' }]);
});

test('skipFile skips the rules file, binaries, big files and missing files', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'copy-lint-'));
  const rules = path.join(dir, 'rules.md');
  const write = (name, data) => {
    fs.writeFileSync(path.join(dir, name), data);
    return path.join(dir, name);
  };
  write('rules.md', 'x');
  assert.ok(skipFile(rules, rules));
  assert.ok(skipFile(write('COPY_RULES.md', 'x'), rules));
  assert.ok(skipFile(write('logo.png', 'x'), rules));
  assert.ok(skipFile(write('blob.dat', Buffer.from([65, 0, 66])), rules));
  assert.ok(skipFile(write('big.md', 'a'.repeat(1024 * 1024 + 1)), rules));
  assert.ok(skipFile(path.join(dir, 'missing.md'), rules));
  assert.ok(!skipFile(write('ok.md', 'text'), rules));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('lintDiff with worktree counts uncommitted and untracked lines, and without it only commits', () => {
  const { execFileSync } = require('node:child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'copy-lint-wt-'));
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args]);
  try {
    git('init', '-q', '-b', 'main');
    fs.writeFileSync(path.join(dir, 'a.md'), 'fine\n');
    git('add', '.');
    git('commit', '-qm', 'base');
    git('checkout', '-qb', 'work');
    fs.writeFileSync(path.join(dir, 'a.md'), 'fine\nBad edit\n');
    fs.writeFileSync(path.join(dir, 'new.md'), 'Bad new file\n');
    const rules = parseRules([
      '| Pattern | Files | Except | Message | Decision |',
      '| --- | --- | --- | --- | --- |',
      '| `Bad` | `**` | | no | test |',
      '',
    ].join('\n'));
    const rulesPath = path.join(dir, 'COPY_RULES.md');
    assert.equal(lintDiff(dir, 'main', rules, rulesPath).hits.length, 0);
    const hits = lintDiff(dir, 'main', rules, rulesPath, true).hits.map((h) => `${h.file}:${h.line}`).sort();
    assert.deepEqual(hits, ['a.md:2', 'new.md:1']);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
