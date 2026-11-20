'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { classifyPr, globToRegExp } = require('./pr_lanes');
const { copyOnlyChange, isProse } = require('./copy_only_diff');

const ADVISOR = 'claude/advisor-brand-20261115';

function lane(files, { branch = ADVISOR, base = {}, head = {} } = {}) {
  const readFile = async (p, side) => (side === 'base' ? base[p] : head[p]);
  return classifyPr({ files, branch, readFile });
}
const modified = (filename) => ({ filename, status: 'modified' });

test('globs follow GitHub paths syntax', () => {
  assert.equal(globToRegExp('**/CLAUDE.md').test('CLAUDE.md'), true);
  assert.equal(globToRegExp('**/CLAUDE.md').test('packages/x/CLAUDE.md'), true);
  assert.equal(globToRegExp('packages/*/lib/**/*.dart').test('packages/notes/lib/a.dart'), true);
  assert.equal(globToRegExp('packages/*/lib/**/*.dart').test('packages/notes/lib/src/a.dart'), true);
  assert.equal(globToRegExp('packages/*/lib/**/*.dart').test('packages/a/b/lib/a.dart'), false);
  assert.equal(globToRegExp('*.md').test('plans/x.md'), false);
});

test('documentation-only PRs are the docs lane for any author', async () => {
  const c = await lane([modified('documentation/notes/user.md')], { branch: 'someone/branch' });
  assert.deepEqual(c, { lane: 'docs', requireChecks: false, reason: 'documentation-only' });
});

test('non-advisor branches never get the prose or copy lanes', async () => {
  assert.equal((await lane([modified('plans/x/DESIGN.md')], { branch: 'claude/feature' })).lane, 'review');
});

test('advisor markdown outside documentation/ is the prose lane and waits for checks', async () => {
  const c = await lane([modified('plans/automations/DESIGN.md'), modified('.claude/skills/x/SKILL.md'),
    { filename: 'README.md', status: 'added' }, modified('documentation/a/user.md')]);
  assert.equal(c.lane, 'prose');
  assert.equal(c.requireChecks, true);
});

test('guarded files always need review, even one-word markdown edits', async () => {
  for (const f of ['CLAUDE.md', 'packages/x/CLAUDE.md', 'SECURITY_TIERS.md', 'advisors/PROTOCOL.md',
    'security/collections.json', '.github/workflows/tests.yml', 'scripts/ci/pr_lanes.js', '.claude/settings.json']) {
    const c = await lane([modified('plans/x.md'), modified(f)]);
    assert.equal(c.lane, 'review', f);
    assert.match(c.reason, /guarded/, f);
  }
  // A rename out of a guarded path is guarded too.
  const c = await lane([{ filename: 'plans/old-claude.md', previous_filename: 'CLAUDE.md', status: 'renamed' }]);
  assert.equal(c.lane, 'review');
});

test('advisor code changes are the review lane', async () => {
  assert.equal((await lane([modified('functions/payments.js')])).lane, 'review');
  assert.equal((await lane([{ filename: 'lib/new_screen.dart', status: 'added' }])).lane, 'review');
});

test('a copy-only Dart change is the copy lane; any code change is review', async () => {
  const p = 'packages/about/lib/hero.dart';
  const base = { [p]: "Text('Software built for the way you work', style: s); // hero" };
  assert.equal((await lane([modified(p)], { base, head: { [p]: "Text('Software that fits how your team works', style: s); // tagline" } })).lane, 'copy');
  const changedCode = await lane([modified(p)], { base, head: { [p]: "Text('Software built for the way you work', style: t);" } });
  assert.equal(changedCode.lane, 'review');
  assert.match(changedCode.reason, /code changed/);
  assert.equal((await lane([modified(p)], { base: {}, head: {} })).lane, 'review', 'unreadable files need review');
});

test('Dart: identifiers, keys and short strings cannot change through the copy lane', () => {
  const ok = (a, b) => copyOnlyChange('a.dart', a, b).copyOnly;
  assert.equal(ok("db.collection('executive_rounds')", "db.collection('executive_round')"), false);
  assert.equal(ok("status == 'in progress'", "status == 'in review'"), false);
  assert.equal(ok("route: '/about'", "route: '/about-us'"), false);
  assert.equal(ok("label: 'Save'", "label: 'Done'"), false);
  assert.equal(ok('final a = 1;', 'final a = 2;'), false);
  assert.equal(ok("'Hello \\$name, welcome back to Bluejay'", "'Hello \\$name, welcome back to Bluejay'"), true);
});

test('Dart: prose strings, comments and rewrapping may change', () => {
  const ok = (a, b) => copyOnlyChange('a.dart', a, b).copyOnly;
  assert.equal(ok("Text('Your team is set up and ready')", 'Text("Your team is all set up")'), true);
  assert.equal(ok("Text('One long sentence about the product here')",
    "Text('One long sentence '\n    'about the product, rewrapped')"), true);
  assert.equal(ok('/* old */ x(); // a\n/// doc', '/* new /* nested */ */ x(); // b\n/// docs'), true);
  assert.equal(ok("r'raw text with three words'", "r'raw words, now changed a bit'"), true);
  assert.equal(ok("'''\nA multi-line\nblock of copy\n'''", "'''\nA multi-line block\nof better copy\n'''"), true);
});

test('Dart: interpolations must stay identical', () => {
  const ok = (a, b) => copyOnlyChange('a.dart', a, b).copyOnly;
  assert.equal(ok("'You have $count new requests waiting'", "'There are $count requests waiting for you'"), true);
  assert.equal(ok("'You have $count new requests waiting'", "'You have $total new requests waiting'"), false);
  assert.equal(ok("'Signed in as ${user.name} on this device'", "'Signed in as ${user.email} on this device'"), false);
  assert.equal(ok("'Seats: ${seats.where((s) => s.used).length} in use today'", "'Seats in use today: ${seats.where((s) => s.used).length} total'"), true);
});

test('unterminated or unsupported files are not copy-only', () => {
  assert.equal(copyOnlyChange('a.dart', "'one two three", "'one two four").copyOnly, false);
  assert.equal(copyOnlyChange('a.js', 'x', 'y').copyOnly, false);
  assert.equal(copyOnlyChange('a.json', '{', '{}').copyOnly, false);
});

test('HTML: text and comments may change; tags, scripts and functional attributes may not', () => {
  const ok = (a, b) => copyOnlyChange('web/about/index.html', a, b).copyOnly;
  assert.equal(ok('<h1 class="hero">Old headline</h1><!-- x -->', '<h1 class="hero">\n  A new headline\n</h1>'), true);
  assert.equal(ok('<h1 class="hero">Old</h1>', '<h1 class="hero big">Old</h1>'), false);
  assert.equal(ok('<p>One</p>', '<p>One <strong>two</strong></p>'), false);
  assert.equal(ok('<a href="/a">Go</a>', '<a href="/b">Go</a>'), false);
  assert.equal(ok('<img alt="A team working together at a desk" src="x.png">', '<img alt="Three people planning their week" src="x.png">'), true);
  assert.equal(ok('<meta name="description" content="Software for small teams that grow">', '<meta name="description" content="Custom software for every kind of team">'), true);
  assert.equal(ok('<meta http-equiv="Content-Security-Policy" content="default-src \'self\' https://a.example">',
    '<meta http-equiv="Content-Security-Policy" content="default-src \'self\' https://b.example">'), false);
  assert.equal(ok('<script>const a = "one two three";</script>', '<script>const a = "one two four";</script>'), false);
  assert.equal(ok('<style>.a{color:red}</style>', '<style>.a{color:blue}</style>'), false);
});

test('JSON: only prose string values may change', () => {
  const ok = (a, b) => copyOnlyChange('packages/x/bluejay_app.json', JSON.stringify(a), JSON.stringify(b)).copyOnly;
  assert.equal(ok({ appId: 'notes', description: 'Keep notes for your team' }, { appId: 'notes', description: 'Shared notes for the whole team' }), true);
  assert.equal(ok({ appId: 'notes', description: 'x y z' }, { appId: 'notes2', description: 'x y z' }), false);
  assert.equal(ok({ installInGroups: ['admin'] }, { installInGroups: ['admin', 'bluejay'] }), false);
  assert.equal(ok({ a: 1, b: 2 }, { b: 2, a: 1 }), false);
});

test('prose means at least three words with letters', () => {
  assert.equal(isProse('in progress'), false);
  assert.equal(isProse('Save your changes'), true);
  assert.equal(isProse('1 2 3'), false);
});

test('public page content is the pages lane for any author, once checks pass', async () => {
  const page = 'web/about/compare/index.html';
  const html = (body) => `<!DOCTYPE html><html><head><link rel="stylesheet" href="/about/assets/about.css"></head><body>${body}<script src="/about/assets/about.js"></script></body></html>`;
  const base = { [page]: html('<h1>Old</h1><a href="/about">About</a>') };
  const head = { [page]: html('<section class="hero"><h1>New <em>headline</em></h1><a class="btn" href="/about/sred">More</a></section>'),
    'web/about/new/index.html': html('<h1>A new page</h1>') };
  const c = await lane([modified(page), { filename: 'web/about/new/index.html', status: 'added' },
    modified('web/about/assets/about.css'), { filename: 'web/about/new/og.png', status: 'added' },
    modified('.claude/skills/business-messaging/aligned-with.txt')], { branch: 'claude/about-x', base, head });
  assert.deepEqual(c, { lane: 'pages', requireChecks: true, reason: 'public page content only' });
});

test('the landing page is the pages lane while its boot script is unchanged', async () => {
  const p = 'web/index.html';
  const boot = '<script>\n  // Chooses between the landing page and the app.\n  start();\n</script>';
  const base = { [p]: `<base href="$FLUTTER_BASE_HREF"><template><h1>Old</h1></template>${boot}` };
  const ok = { [p]: `<base href="$FLUTTER_BASE_HREF"><template><h1>New</h1><p class="section-more"><a href="/about/compare">Compare</a></p></template>\n${boot.replace(/\n  /g, '\n    ')}` };
  assert.equal((await lane([modified(p)], { branch: 'claude/x', base, head: ok })).lane, 'pages');
  const changed = { [p]: base[p].replace('start();', 'start(); fetch("https://x.example");') };
  const c = await lane([modified(p)], { branch: 'claude/x', base, head: changed });
  assert.equal(c.lane, 'review');
  assert.match(c.reason, /scripts, event handlers or embeds changed/);
});

test('anything that runs code on a public page needs review', async () => {
  const p = 'web/about/index.html';
  const base = { [p]: '<a href="/a">Go</a><script src="/about/assets/about.js"></script>' };
  for (const after of [
    '<a href="/a" onclick="steal()">Go</a><script src="/about/assets/about.js"></script>',
    '<a href="javascript:steal()">Go</a><script src="/about/assets/about.js"></script>',
    '<a href="/a">Go</a><script src="/about/assets/about.js"></script><script>steal()</script>',
    '<a href="/a">Go</a><script src="https://cdn.example/x.js"></script>',
    '<a href="/a">Go</a><iframe src="https://x.example"></iframe><script src="/about/assets/about.js"></script>',
    '<a href="/a">Go</a><meta http-equiv="refresh" content="0;url=https://x.example"><script src="/about/assets/about.js"></script>',
    '<a href="/a">Go</a><script src="/about/assets/about.js">',
  ]) {
    assert.equal((await lane([modified(p)], { branch: 'claude/x', base, head: { [p]: after } })).lane, 'review', after);
  }
  // A new page may include only the shared tab script.
  const added = { filename: 'web/about/x/index.html', status: 'added' };
  assert.equal((await lane([added], { branch: 'claude/x', head: { [added.filename]: '<p>Hi</p><script>x()</script>' } })).lane, 'review');
  // An SVG can run script when opened directly on the origin.
  const svg = 'web/about/assets/icons.svg';
  assert.equal((await lane([modified(svg)], { branch: 'claude/x', base: { [svg]: '<svg><symbol id="a"/></svg>' },
    head: { [svg]: '<svg onload="x()"><symbol id="a"/></svg>' } })).lane, 'review');
  assert.equal((await lane([modified(svg)], { branch: 'claude/x', base: { [svg]: '<svg><symbol id="a"/></svg>' },
    head: { [svg]: '<svg><symbol id="a"/><symbol id="b"><path d="M0 0h2"/></symbol></svg>' } })).lane, 'pages');
});

test('scripts, the legal pages and anything outside the public pages need review', async () => {
  for (const f of ['web/about/assets/about.js', 'web/privacy/index.html', 'web/terms/index.html', 'web/manifest.json',
    'firebase.json', 'lib/main.dart', 'web/about/x.html.bak']) {
    const c = await lane([modified('web/about/assets/about.css'), modified(f)], { branch: 'claude/x' });
    assert.equal(c.lane, 'review', f);
  }
  // A rename that moves a page out of web/about/ is not page content.
  const c = await lane([{ filename: 'web/privacy/index.html', previous_filename: 'web/about/x/index.html', status: 'renamed' }], { branch: 'claude/x' });
  assert.equal(c.lane, 'review');
  assert.equal((await lane([modified('web/about/index.html')], { branch: 'claude/x', base: {}, head: {} })).lane, 'review', 'unreadable files need review');
});
