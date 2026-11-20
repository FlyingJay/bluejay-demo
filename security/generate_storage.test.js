'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const gs = require('./generate_storage');
const { checkRulesExceptions } = require('./check_rules_exceptions');

const TABLE = gs.loadStorageTable();
const RULES = fs.readFileSync(gs.RULES_PATH, 'utf8');
const clone = (x) => JSON.parse(JSON.stringify(x));

test('the repo table is valid and storage.rules is generated from it', () => {
  assert.deepEqual(gs.validateStorageTable(TABLE), []);
  assert.equal(gs.generateStorageRules(RULES, TABLE), RULES, 'run `node security/generate.js`');
});

test('stage 7: no rollout state left; the generated blocks grant only the signedIn reads', () => {
  for (const [name, f] of Object.entries(TABLE.families)) assert.equal(f.enforce, undefined, name);
  assert.doesNotMatch(RULES, /isOpen|isEnforced|storageEnforcement|'enforced'/);
  assert.deepEqual(gs.signedInReads(TABLE), {
    roots: ['app_icons', 'app_icons_thumbs', 'app_screenshots', 'chat_images', 'published'],
    groupFiles: ['logo.jpg', 'logo_print.png', 'logo_thumb.png'],
    groupFolders: ['logos'],
  });
  // Only `allow read` in the generated section: no write, no open gate.
  const generated = RULES.slice(RULES.indexOf(gs.BEGIN), RULES.indexOf(gs.END));
  assert.deepEqual([...generated.matchAll(/allow (\w[\w, ]*):/g)].map((m) => m[1]), ['read', 'read', 'read']);
  const t = clone(TABLE);
  t.families.chat_images.enforce = 'enforced';
  assert.ok(gs.validateStorageTable(t).some((p) => p.includes('unknown key "enforce"')));
  // writeOnce only on a family no client writes; folders never name apps/.
  const w = clone(TABLE);
  w.families.app_icons.writeOnce = true;
  assert.ok(gs.validateStorageTable(w).some((p) => p.includes('app_icons.writeOnce')));
  w.families.app_icons.writeOnce = undefined;
  delete w.families.app_icons.writeOnce;
  w.families.group_logo_versions.paths = ['groups/{groupId}/apps/**'];
  assert.ok(gs.validateStorageTable(w).some((p) => p.includes('unsupported path pattern')));
});

test('familyOfPath classifies every path into its family', () => {
  const cases = {
    'groups/g1/apps/notes/f/x.txt': 'group_apps',
    'groups/g1/apps/notes': 'group_apps',
    'groups/g1/apps': 'unmatched',
    'groups/g1/logo.jpg': 'group_logo',
    'groups/temp_u1/logo.jpg': 'group_logo',
    'groups/g1/logo_thumb.png': 'group_logo_renditions',
    'groups/g1/logo_print.png': 'group_logo_renditions',
    'groups/g1/logos/v1/logo.jpg': 'group_logo_versions',
    'groups/g1/logos': 'unmatched',
    'groups/g1/misc/x': 'unmatched',
    'groups/g1': 'unmatched',
    groups: 'unmatched',
    'profile_pictures/u1/p.jpg': 'profile_pictures',
    'profile_pictures/p.jpg': 'profile_pictures',
    'published/g1/a/x': 'published',
    'app_icons/i.png': 'app_icons',
    'app_icons_thumbs/i.png': 'app_icons_thumbs',
    'app_screenshots/lists/list_phone_dark.png': 'app_screenshots',
    'warehouse_private/g1/x': 'server_only',
    'blue_ji_docs_corpus/x': 'server_only',
    'users/u1/x': 'legacy_users',
    'naic_sight/u1/j1/in.csv': 'legacy_naic_sight',
    'recorder_audio/u1/x': 'removed_apps',
    'chat_images/x.jpg': 'chat_images',
    'foo.txt': 'unmatched',
    'zz/x': 'unmatched',
  };
  for (const [p, family] of Object.entries(cases)) {
    assert.equal(gs.familyOfPath(TABLE, p), family, p);
    assert.equal(gs.familyOfPath(TABLE, `/${p}`), family, `/${p}`);
  }
});

test('the validator rejects malformed families', () => {
  const bad = (mutate) => {
    const t = clone(TABLE);
    mutate(t.families);
    return gs.validateStorageTable(t);
  };
  assert.ok(bad((f) => { f.chat_images.read = 'public'; }).length);
  assert.ok(bad((f) => { f.chat_images.paths = ['chat_images/*/x']; }).length, 'unsupported pattern');
  assert.ok(bad((f) => { f.chat_images.paths = ['app_icons/**']; }).length, 'a prefix claimed twice');
  assert.ok(bad((f) => { f.app_icons.matchBlocks = []; }).length, 'block family without blocks');
  assert.ok(bad((f) => { f.chat_images.matchBlocks = ['/chat_images/{x}']; }).length, 'blocks without a block grant');
  assert.ok(bad((f) => { f.legacy_users.read = 'signedIn'; }).length, 'a migrated prefix grants nothing');
  assert.ok(bad((f) => { f.legacy_users.migrate = true; }).length, 'migrate says where the prefix moves');
  assert.ok(bad((f) => { f.legacy_users.migrate = { appId: 'storage' }; }).length, 'migrate needs a folder');
  assert.ok(bad((f) => { f.legacy_users.migrate = { appId: 'storage', folder: '../x' }; }).length, 'folder is a plain path');
  assert.ok(bad((f) => { f.legacy_users.migrate = { appId: 'Storage App', folder: 'files' }; }).length, 'appId is an app id');
  assert.ok(bad((f) => { delete f.unmatched; }).length, 'needs a default');
  assert.ok(bad((f) => { f.renamed = f.group_apps; delete f.group_apps; }).length, 'the tenant family is group_apps');
  assert.ok(bad((f) => { f.chat_images.reviewed = '2026-02-30'; }).length);
  assert.ok(bad((f) => { f.chat_images.why = ''; }).length);
  assert.ok(bad((f) => { f.chat_images.extra = 1; }).length);
  assert.ok(bad((f) => { f.chat_images.guestWritableFolders = { 'naic-sight': ['x'] }; }).length, 'guest folders only on group_apps');
  assert.ok(bad((f) => { f.group_apps.guestWritableFolders = { 'naic-sight': [] }; }).length, 'a listed app names folders');
  assert.ok(bad((f) => { f.group_apps.guestWritableFolders = { 'naic-sight': ['a/b'] }; }).length, 'a folder is one segment');
  assert.ok(bad((f) => { f.group_apps.guestWritableFolders = { 'Naic Sight': ['x'] }; }).length, 'keys are app ids');
  assert.ok(bad((f) => { f.group_apps.guestWritableFolders = ['naic_sight']; }).length, 'a map, not a list');
});

test('guestWritableFolders renders as the guest folder map storage.rules reads', () => {
  const rules = fs.readFileSync(path.join(__dirname, '..', 'storage.rules'), 'utf8');
  const expected = Object.entries(TABLE.families.group_apps.guestWritableFolders)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([app, folders]) => `'${app}': [${[...folders].sort().map((x) => `'${x}'`).join(', ')}]`).join(', ');
  assert.ok(rules.includes(`function guestWritableFolders() { return {${expected}}; }`));
  assert.ok(rules.includes('guestWritableFolders().get(a, [])'), 'the tenant rule gates :guest on the folder map');
});

test('the exception guard approves exactly the declared Storage blocks', () => {
  const run = (storage, storageTable = TABLE) => checkRulesExceptions({ 'storage.rules': storage }, { collections: {}, exceptions: {} }, { storageTable });
  assert.deepEqual(run(RULES), []);
  const sneaky = RULES.replace('    match /app_icons/{allPaths=**} {', '    match /secrets/{allPaths=**} { allow read: if true; }\n    match /app_icons/{allPaths=**} {');
  assert.ok(run(sneaky).some((p) => p.includes('/secrets/{allPaths=**}')));
  const t = clone(TABLE);
  t.families.app_icons.matchBlocks = ['/app_icons/{allPaths=**}', '/app_icons/gone/{x}'];
  assert.ok(run(RULES, t).some((p) => p.includes('/app_icons/gone/{x}') && p.includes('no such match block')));
  const doubled = checkRulesExceptions({ 'storage.rules': RULES }, {
    collections: {},
    exceptions: { 'EX-X-1': { what: 'x', why: 'y', reviewed: '2026-11-05', storageMatchBlocks: ['/app_icons/{allPaths=**}'] } },
  }, { storageTable: TABLE });
  assert.ok(doubled.some((p) => p.includes('keep one')));
});

test('retainedFolders: validated like guestWritableFolders and generated into retainedFolders()', () => {
  const gs = require('./generate_storage');
  const table = gs.loadStorageTable();
  assert.deepEqual(gs.validateStorageTable(table), []);
  const rendered = gs.renderGenerated(table);
  assert.match(rendered, /function retainedFolders\(\) \{ return \{.*'improve-apps': \['bug_reports_media', 'feature_request_media'\].*'signatures': \['signature_documents'\]/);
  const bad = JSON.parse(JSON.stringify(table));
  bad.families.group_apps.retainedFolders = { 'improve-apps': [] };
  assert.ok(gs.validateStorageTable(bad).some((p) => /retainedFolders is \{ appId/.test(p)));
  const misplaced = JSON.parse(JSON.stringify(table));
  misplaced.families.published.retainedFolders = { notes: ['x'] };
  assert.ok(gs.validateStorageTable(misplaced).some((p) => /retainedFolders/.test(p)));
  // Every tenant write to a stored file checks it.
  const rules = require('fs').readFileSync(gs.RULES_PATH, 'utf8');
  const block = rules.slice(rules.indexOf('match /groups/{groupId}/apps/{appId}/{allPaths=**}'));
  for (const op of ['create', 'update', 'delete']) {
    assert.match(block.split('\n').find((l) => l.includes(`allow ${op}:`)), /retained\(appId\)/, op);
  }
});

test('guestUploadLimits: validated, generated into guestUploadLimits(), and checked on guest writes', () => {
  const table = gs.loadStorageTable();
  assert.deepEqual(gs.validateStorageTable(table), []);
  assert.match(gs.renderGenerated(table), /function guestUploadLimits\(\) \{ return \{'chat': \{'maxBytes': 10485760, 'contentTypes': '[^']+'\}, 'storage': \{'maxBytes': 26214400/);
  const bad = (edit) => {
    const t = JSON.parse(JSON.stringify(table));
    edit(t.families);
    return gs.validateStorageTable(t).some((p) => /guestUploadLimits/.test(p));
  };
  assert.ok(bad((f) => { f.group_apps.guestUploadLimits.notes = { maxBytes: 10, contentTypes: 'image/.*' }; }), 'only apps with guest folders');
  assert.ok(bad((f) => { f.group_apps.guestUploadLimits.chat = { maxBytes: 0, contentTypes: 'image/.*' }; }), 'a positive size');
  assert.ok(bad((f) => { f.group_apps.guestUploadLimits.chat = { maxBytes: 10, contentTypes: '(' }; }), 'a valid regex');
  assert.ok(bad((f) => { f.chat_images.guestUploadLimits = { chat: { maxBytes: 10, contentTypes: 'x' } }; }), 'group_apps only');
  const rules = fs.readFileSync(gs.RULES_PATH, 'utf8');
  assert.ok(rules.includes('return tenantMetaOk(g, a) && guestUploadOk(a) &&'), 'guest creates and updates check the limits');
});
