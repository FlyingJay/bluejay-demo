const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const {
  allPackages, checkRepo, checkSource, codeOnly, compareToBaseline, countFindings, tightenBaseline,
  textStyleSuggestion,
} = require('./check_design_tokens');

const rules = (source, rel = 'packages/app/lib/screen.dart') => checkSource(rel, source).map((v) => `${v.rule}:${v.line}`);

test('raw Colors are flagged except white, black and transparent', () => {
  const source = [
    'final a = Colors.white;',
    'final b = Colors.black;',
    'final c = Colors.transparent;',
    'final d = Colors.grey[600];',
    'final e = Colors.redAccent;',
    'final f = Colors.white70;',
    'final g = material.Colors.blue;',
  ].join('\n');
  assert.deepEqual(rules(source), ['raw-color:4', 'raw-color:5', 'raw-color:6', 'raw-color:7']);
  const [grey, red] = checkSource('x.dart', source);
  assert.match(grey.suggestion, /BjNeutral/);
  assert.match(red.suggestion, /BjTone\.danger/);
  assert.equal(grey.snippet, 'Colors.grey');
});

test('colour literals are flagged; computed colours are not', () => {
  const source = [
    'const a = Color(0xFF7C3AED);',
    'final b = Color.fromARGB(255, 10, 20, 30);',
    'final c = Color.fromRGBO(1, 2, 3, 0.5);',
    'final d = Color(tag.color);',
    'final e = Color.fromARGB(alpha, r, g, b);',
    'final f = BjNeutral.ink;',
  ].join('\n');
  assert.deepEqual(rules(source), ['color-literal:1', 'color-literal:2', 'color-literal:3']);
});

test('TextStyle is flagged only when it sets fontSize, across lines', () => {
  const source = [
    'final a = TextStyle(fontWeight: FontWeight.w600);',
    'final b = TextStyle(',
    '  color: pick(Colors.white, x),',
    '  fontSize: 13,',
    ');',
    'final c = theme.textTheme.bodySmall!.copyWith(fontSize: 12);',
    'final d = const TextStyle(fontSize: 22);',
  ].join('\n');
  const found = checkSource('x.dart', source);
  assert.deepEqual(found.map((v) => `${v.rule}:${v.line}`), ['font-size:2', 'font-size:7']);
  assert.match(found[0].suggestion, /bodySmall/);
  assert.match(found[1].suggestion, /headlineSmall/);
  assert.match(found[0].snippet, /^TextStyle\( color: .* fontSize: 13, \)$/);
});

test('package:pdf text styles are not flagged', () => {
  const source = [
    "pw.Text('Total', style: pw.TextStyle(fontSize: 18));",
    'final s = const pw.TextStyle(fontSize: 7);',
    'final t = TextStyle(fontSize: 7);',
  ].join('\n');
  assert.deepEqual(checkSource('x.dart', source).map((v) => `${v.rule}:${v.line}`), ['font-size:3']);
});

test('textStyleSuggestion maps sizes onto the text theme', () => {
  assert.match(textStyleSuggestion(11), /labelSmall/);
  assert.match(textStyleSuggestion(14), /bodyMedium/);
  assert.match(textStyleSuggestion(16), /titleMedium/);
  assert.match(textStyleSuggestion(20), /titleLarge/);
  assert.match(textStyleSuggestion(NaN), /textTheme style/);
});

test('per-list dragDevices overrides are flagged', () => {
  const source = [
    'ScrollConfiguration(',
    '  behavior: ScrollConfiguration.of(context).copyWith(',
    '    dragDevices: {PointerDeviceKind.mouse},',
    '  ),',
    '  // design-ok: a vertical canvas a mouse pans',
    '  child: x.copyWith(dragDevices: kinds),',
    ')',
  ].join('\n');
  assert.deepEqual(rules(source), ['drag-devices:3']);
});

test('a MaterialApp must use BjScrollBehavior', () => {
  const source = [
    'final a = MaterialApp(',
    '  home: x,',
    ');',
    'final b = MaterialApp(theme: t, scrollBehavior: const BjScrollBehavior(), home: x);',
    'final c = MaterialApp.router(routerConfig: r);',
    'final d = MaterialApp(scrollBehavior: const MaterialScrollBehavior());',
  ].join('\n');
  assert.deepEqual(rules(source), ['scroll-behavior:1', 'scroll-behavior:5', 'scroll-behavior:6']);
});

test('comments and strings are not code', () => {
  const source = [
    '/// Never use Colors.grey here; see TextStyle(fontSize: 12).',
    "final a = Text('Colors.red and Color(0xFF000000)');",
    'final b = "it\'s Colors.blue"; // Colors.green',
    "final c = r'\\' + 'x'; final d = Colors.orange;",
    '/* outer /* nested Colors.pink */ still Colors.teal */ final e = 1;',
    "final f = '''",
    'Colors.purple',
    "''';",
  ].join('\n');
  assert.deepEqual(rules(source), ['raw-color:4']);
  assert.equal(codeOnly('a\n// b\nc').split('\n').length, 3);
});

test('design-ok on the line or the line above, with a reason, escapes a finding', () => {
  const source = [
    'final a = Colors.brown; // design-ok: chess board square',
    '// design-ok: the user picked this colour',
    'final b = Color(0xFF123456);',
    'final c = Colors.amber; // design-ok:',
    '',
    'final d = Colors.cyan;',
  ].join('\n');
  assert.deepEqual(rules(source), ['raw-color:4', 'raw-color:6']);
});

test('a *_theme.dart file is flagged unless its header justifies it', () => {
  assert.deepEqual(rules('class AppTheme {}', 'packages/app/lib/app_theme.dart'), ['theme-file:1']);
  assert.deepEqual(rules('// design-ok: chess piece set colours\nclass ChessTheme {}', 'packages/app/lib/chess_theme.dart'), []);
});

test('checkRepo scans lib/ of every package except the design system, plus the root lib/', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'design-tokens-'));
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), text);
  };
  write('packages/bluejay_design/lib/tokens.dart', 'const a = Color(0xFF000000);');
  write('packages/migrated/lib/src/row.dart', 'final a = Colors.red;');
  write('packages/migrated/lib/old_theme.dart', 'class OldTheme {}');
  write('packages/migrated/lib/model.g.dart', 'final b = Colors.red;');
  write('packages/migrated/test/fake.dart', 'final c = Colors.red;');
  write('packages/legacy/lib/a.dart', 'final a = Colors.red;');
  write('packages/no_lib/pubspec.yaml', 'name: no_lib');
  write('lib/main.dart', 'final a = Colors.indigo;');
  try {
    assert.deepEqual(allPackages(root), ['legacy', 'migrated']);
    const { files, violations } = checkRepo(root);
    assert.equal(files, 4);
    assert.deepEqual(violations.map((v) => `${v.file}:${v.rule}`), [
      'packages/legacy/lib/a.dart:raw-color',
      'packages/migrated/lib/old_theme.dart:theme-file',
      'packages/migrated/lib/src/row.dart:raw-color',
      'lib/main.dart:raw-color',
    ]);
    assert.equal(checkRepo(root, ['legacy'], { includeRoot: false }).files, 1);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the baseline ratchet fails on new findings and on unrecorded improvements', () => {
  const counts = countFindings([
    { file: 'a.dart', rule: 'raw-color' },
    { file: 'a.dart', rule: 'raw-color' },
    { file: 'b.dart', rule: 'font-size' },
  ]);
  assert.deepEqual(counts, { 'a.dart': { 'raw-color': 2 }, 'b.dart': { 'font-size': 1 } });

  const exact = compareToBaseline(counts, { 'a.dart': { 'raw-color': 2 }, 'b.dart': { 'font-size': 1 } });
  assert.deepEqual(exact, { over: [], under: [] });

  // A new file, or more of a rule in a known file, is over.
  const worse = compareToBaseline(counts, { 'a.dart': { 'raw-color': 1 } });
  assert.deepEqual(worse.over.map((o) => `${o.file}:${o.rule}:${o.count}/${o.allowed}`), [
    'a.dart:raw-color:2/1',
    'b.dart:font-size:1/0',
  ]);

  // Fewer findings, or a file that's gone, is under.
  const better = compareToBaseline(counts, {
    'a.dart': { 'raw-color': 3 }, 'b.dart': { 'font-size': 1 }, 'gone.dart': { 'theme-file': 1 },
  });
  assert.deepEqual(better.under.map((u) => `${u.file}:${u.count}/${u.allowed}`), ['a.dart:2/3', 'gone.dart:0/1']);
});

test('tightenBaseline only lowers counts and never adds entries', () => {
  const baseline = { 'a.dart': { 'raw-color': 3, 'font-size': 1 }, 'gone.dart': { 'theme-file': 1 } };
  const counts = { 'a.dart': { 'raw-color': 5 }, 'new.dart': { 'raw-color': 1 } };
  assert.deepEqual(tightenBaseline(baseline, counts), { 'a.dart': { 'raw-color': 3 } });
  assert.deepEqual(tightenBaseline(baseline, { 'a.dart': { 'raw-color': 1 } }), { 'a.dart': { 'raw-color': 1 } });
});

test('the repository passes the check', () => {
  execFileSync(process.execPath, [path.join(__dirname, 'check_design_tokens.js')], { stdio: 'pipe' });
});
