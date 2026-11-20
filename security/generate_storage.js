#!/usr/bin/env node
/**
 * Generates storage.rules' table-driven section from security/storage_paths.json
 * (plans/firestore-rules §3.2, §4.11, T16): which object paths any signed-in
 * user may read (the families declaring `read: "signedIn"`). Every other
 * family grants nothing generically: `none` means nothing at all, `block`
 * means the family's own hand-written match blocks decide.
 *
 *   node security/generate_storage.js          rewrite the generated section in place
 *   node security/generate_storage.js --check  exit 1 if storage.rules is out of date (CI)
 *
 * security/generate.js runs this too (and its --check), so one command
 * regenerates both rules files.
 *
 * Path patterns a family may declare (validated):
 *   groups/{groupId}/apps/{appId}/**   the tenant family (exactly one)
 *   groups/{groupId}/<file>            one object directly under a group
 *   groups/{groupId}/<folder>/**       everything under a folder of a group (not apps)
 *   <root>/**                          everything under a top-level prefix
 * plus exactly one `default: true` family with no paths (everything else).
 *
 * `read` / `write`: `signedIn` and `none` are applied by the generated
 * blocks; `block` means the family's own `matchBlocks` decide (approved by
 * security/check_rules_exceptions.js).
 *
 * `writeOnce: true` (a `write: "none"` family) records that its only writer,
 * a server function, never overwrites or deletes an object there: each write
 * goes to a new path, refused by Storage if the object exists. The security
 * tier audit counts a callable's Storage writes to such a family as kept for
 * the record (scripts/security_tier_audit/audited_callables.js).
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TABLE_PATH = path.join(__dirname, 'storage_paths.json');
const RULES_PATH = path.join(ROOT, 'storage.rules');

const TENANT_PATTERN = 'groups/{groupId}/apps/{appId}/**';
const READS = ['signedIn', 'none', 'block'];
const WRITES = ['none', 'block'];
const FAMILY_KEYS = ['paths', 'read', 'write', 'matchBlocks', 'exception', 'migrate', 'default', 'guestWritableFolders', 'guestUploadLimits', 'retainedFolders', 'writeOnce', 'what', 'why', 'reviewed'];
const NAME = /^[a-z][a-z0-9_]*$/;
const SEGMENT = /^[A-Za-z0-9_.-]+$/;
const BEGIN = '    // BEGIN GENERATED storage families: edit security/storage_paths.json, then run `node security/generate.js`.';
const END = '    // END GENERATED storage families';

function loadStorageTable(file = TABLE_PATH) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function isRealDate(s) {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/** What a path pattern declares: { kind: 'tenant' | 'groupFile' | 'root', key } or null. */
function parsePattern(p) {
  if (p === TENANT_PATTERN) return { kind: 'tenant', key: null };
  let m = /^groups\/\{groupId\}\/([^/{}*]+)$/.exec(p);
  if (m && SEGMENT.test(m[1]) && m[1] !== 'apps') return { kind: 'groupFile', key: m[1] };
  m = /^groups\/\{groupId\}\/([^/{}*]+)\/\*\*$/.exec(p);
  if (m && SEGMENT.test(m[1]) && m[1] !== 'apps') return { kind: 'groupFolder', key: m[1] };
  m = /^([^/{}*]+)\/\*\*$/.exec(p);
  if (m && SEGMENT.test(m[1]) && m[1] !== 'groups') return { kind: 'root', key: m[1] };
  return null;
}

/** Every problem with [table] ([] = valid). */
function validateStorageTable(table) {
  const problems = [];
  const families = table && table.families;
  if (!families || typeof families !== 'object') return ['storage_paths.json needs a "families" object'];
  const claimed = new Map();
  let tenant = 0;
  const defaults = [];
  for (const [name, f] of Object.entries(families)) {
    const where = `families.${name}`;
    if (!NAME.test(name)) problems.push(`${where}: family names are lower_snake_case`);
    for (const key of Object.keys(f)) if (!FAMILY_KEYS.includes(key)) problems.push(`${where}: unknown key "${key}"`);
    if (!READS.includes(f.read)) problems.push(`${where}.read must be one of ${READS.join(', ')}`);
    if (!WRITES.includes(f.write)) problems.push(`${where}.write must be one of ${WRITES.join(', ')}`);
    for (const key of ['what', 'why']) {
      if (typeof f[key] !== 'string' || f[key].trim().length < 10) problems.push(`${where}.${key} must say it in a sentence`);
    }
    if (!isRealDate(f.reviewed)) problems.push(`${where}.reviewed must be a real YYYY-MM-DD date`);
    const needsBlock = f.read === 'block' || f.write === 'block';
    const blocks = f.matchBlocks || [];
    if (needsBlock && !blocks.length) problems.push(`${where}: read/write "block" needs matchBlocks`);
    if (!needsBlock && blocks.length) problems.push(`${where}: matchBlocks without a "block" read or write`);
    if ('exception' in f && !/^EX-[A-Z0-9]+(-[A-Z0-9]+)*-[0-9]+$/.test(f.exception)) problems.push(`${where}.exception must look like EX-NAME-1`);
    if ('migrate' in f) {
      // Where M8 moves the prefix: `<prefix>/<rest>` → groups/{g}/apps/{appId}/{folder}/<rest>.
      const m = f.migrate;
      const ok = m && typeof m === 'object' && !Array.isArray(m)
        && Object.keys(m).every((k) => k === 'appId' || k === 'folder')
        && typeof m.appId === 'string' && /^[a-z0-9][a-z0-9_-]*$/.test(m.appId)
        && typeof m.folder === 'string' && m.folder.split('/').every((s) => SEGMENT.test(s) && s !== '.' && s !== '..');
      if (!ok) problems.push(`${where}.migrate is { appId, folder } (the app and ScopedStorage folder the prefix moves into) or absent`);
    }
    if ('writeOnce' in f && (f.writeOnce !== true || f.write !== 'none')) {
      problems.push(`${where}.writeOnce is true on a family no client writes (write "none"), or absent`);
    }
    if (f.migrate && (f.read !== 'none' || f.write !== 'none')) problems.push(`${where}: a migrated legacy prefix grants nothing`);
    // { appId: [folder, ...] } maps of top-level folders under groups/{g}/apps/{appId}/:
    // guestWritableFolders, where that app's admitted guests may upload and read their own
    // files; retainedFolders, whose files no client deletes, overwrites or changes.
    for (const key of ['guestWritableFolders', 'retainedFolders']) {
      if (!(key in f)) continue;
      const g = f[key];
      const ok = name === 'group_apps' && g && typeof g === 'object' && !Array.isArray(g)
        && Object.entries(g).every(([app, folders]) => /^[a-z0-9][a-z0-9-]{0,62}$/.test(app)
          && Array.isArray(folders) && folders.length > 0
          && folders.every((s) => typeof s === 'string' && SEGMENT.test(s) && s !== '.' && s !== '..'));
      if (!ok) problems.push(`${where}.${key} is { appId: [folder, ...] } on the group_apps family only`);
    }
    // { appId: { maxBytes, contentTypes } }: what that app's guests may upload
    // into its guestWritableFolders (size in bytes; a content-type regex).
    if ('guestUploadLimits' in f) {
      const g = f.guestUploadLimits;
      const ok = name === 'group_apps' && g && typeof g === 'object' && !Array.isArray(g)
        && Object.entries(g).every(([app, l]) => /^[a-z0-9][a-z0-9-]{0,62}$/.test(app)
          && (f.guestWritableFolders || {})[app]
          && l && Number.isInteger(l.maxBytes) && l.maxBytes > 0
          && typeof l.contentTypes === 'string' && l.contentTypes && !/['\\]/.test(l.contentTypes)
          && (() => { try { new RegExp(l.contentTypes); return true; } catch (e) { return false; } })());
      if (!ok) problems.push(`${where}.guestUploadLimits is { appId: { maxBytes, contentTypes } } for apps with guestWritableFolders, on group_apps only`);
    }
    if (!Array.isArray(f.paths)) {
      problems.push(`${where}.paths must be a list`);
      continue;
    }
    if (f.default === true) {
      defaults.push(name);
      if (f.paths.length) problems.push(`${where}: the default family has no paths`);
      if (f.read !== 'none' || f.write !== 'none') problems.push(`${where}: the default family grants nothing`);
    } else if ('default' in f) {
      problems.push(`${where}.default is true or absent`);
    } else if (!f.paths.length) {
      problems.push(`${where}.paths is empty`);
    }
    for (const p of f.paths) {
      const parsed = parsePattern(p);
      if (!parsed) {
        problems.push(`${where}: unsupported path pattern "${p}" (use ${TENANT_PATTERN}, groups/{groupId}/<file>, groups/{groupId}/<folder>/** or <root>/**)`);
        continue;
      }
      if (parsed.kind === 'tenant') {
        tenant += 1;
        if (name !== 'group_apps') problems.push(`${where}: the tenant family must be named group_apps (storage.rules' tenant block gates on it)`);
      }
      const key = `${parsed.kind}:${parsed.key}`;
      if (claimed.has(key)) problems.push(`${where}: "${p}" is already claimed by ${claimed.get(key)}`);
      else claimed.set(key, name);
    }
  }
  if (tenant !== 1) problems.push(`exactly one family must declare ${TENANT_PATTERN}`);
  if (defaults.length !== 1) problems.push(`exactly one family must be the default (found ${defaults.length})`);
  return problems;
}

/** The lookup tables the generated rules and the JS mirror share. */
function classify(table) {
  const roots = {};
  const groupFiles = {};
  const groupFolders = {};
  let tenantFamily = null;
  let defaultFamily = null;
  for (const [name, f] of Object.entries(table.families)) {
    if (f.default) defaultFamily = name;
    for (const p of f.paths || []) {
      const parsed = parsePattern(p);
      if (!parsed) continue;
      if (parsed.kind === 'tenant') tenantFamily = name;
      else if (parsed.kind === 'groupFile') groupFiles[parsed.key] = name;
      else if (parsed.kind === 'groupFolder') groupFolders[parsed.key] = name;
      else roots[parsed.key] = name;
    }
  }
  return { roots, groupFiles, groupFolders, tenantFamily, defaultFamily };
}

/**
 * The family of an object path (no leading slash), exactly as the generated
 * storageFamily() decides it.
 */
function familyOfPath(table, objectPath) {
  const { roots, groupFiles, groupFolders, tenantFamily, defaultFamily } = classify(table);
  const s = String(objectPath).replace(/^\//, '');
  const seg = s.split('/');
  if (/^groups\/[^/]+\/apps\/[^/]+(\/.*)?$/.test(s)) return tenantFamily;
  if (/^groups\/[^/]+\/[^/]+$/.test(s)) return groupFiles[seg[2]] || defaultFamily;
  if (/^groups\/[^/]+\/[^/]+\/.+$/.test(s)) return groupFolders[seg[2]] || defaultFamily;
  if (seg[0] === 'groups') return defaultFamily;
  return roots[seg[0]] || defaultFamily;
}

const q = (s) => `'${s}'`;

/** The generated blocks (paths relative to /b/{bucket}/o). */
const GATE_BLOCKS = ['/{root}/{rest=**}', '/groups/{groupId}/{file}', '/groups/{groupId}/{folder}/{rest=**}'];

/**
 * { roots, groupFiles, groupFolders }: the top-level prefixes,
 * groups/{groupId}/<file> names and groups/{groupId}/<folder> names of every
 * family whose read is "signedIn", sorted.
 */
function signedInReads(table) {
  const roots = [];
  const groupFiles = [];
  const groupFolders = [];
  for (const f of Object.values(table.families)) {
    if (f.read !== 'signedIn') continue;
    for (const p of f.paths || []) {
      const parsed = parsePattern(p);
      if (parsed && parsed.kind === 'root') roots.push(parsed.key);
      else if (parsed && parsed.kind === 'groupFile') groupFiles.push(parsed.key);
      else if (parsed && parsed.kind === 'groupFolder') groupFolders.push(parsed.key);
    }
  }
  return { roots: roots.sort(), groupFiles: groupFiles.sort(), groupFolders: groupFolders.sort() };
}

/**
 * The generated section (between and including the markers): the generic
 * signedIn reads. A list request can bind the wildcard after the listed
 * prefix to null, hence the `is string` guards (listing a prefix or a
 * group's top level grants nothing).
 */
/** A rules map literal body for an { appId: [folder, ...] } table key, sorted. */
function folderMap(map) {
  return Object.entries(map || {})
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([app, folders]) => `${q(app)}: [${[...folders].sort().map(q).join(', ')}]`)
    .join(', ');
}

function limitMap(map) {
  return Object.entries(map || {})
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([app, l]) => `${q(app)}: {'maxBytes': ${l.maxBytes}, 'contentTypes': ${q(l.contentTypes)}}`)
    .join(', ');
}

function renderGenerated(table) {
  const { roots, groupFiles, groupFolders } = signedInReads(table);
  const groupApps = table.families.group_apps || {};
  return [
    BEGIN,
    '    // Families whose read is "any signed-in user": top-level prefixes,',
    '    // single objects directly under groups/{groupId}/, and folders under it',
    '    // (never apps/). Every other path gets nothing here (only the family',
    '    // blocks below grant more).',
    '    match /{root}/{rest=**} {',
    `      allow read: if signedIn() && root is string && root in [${roots.map(q).join(', ')}];`,
    '    }',
    '    match /groups/{groupId}/{file} {',
    `      allow read: if signedIn() && file is string && file in [${groupFiles.map(q).join(', ')}];`,
    '    }',
    '    match /groups/{groupId}/{folder}/{rest=**} {',
    `      allow read: if signedIn() && folder is string && folder in [${groupFolders.map(q).join(', ')}];`,
    '    }',
    '    // The folders under groups/{g}/apps/{appId}/ where that app\'s admitted',
    '    // guests (:guest) may upload and read their own files (guestWritableFolders).',
    `    function guestWritableFolders() { return {${folderMap(groupApps.guestWritableFolders)}}; }`,
    '    // What an app\'s guests may upload to its guestWritableFolders',
    '    // (guestUploadLimits): the most bytes, and a content-type regex.',
    `    function guestUploadLimits() { return {${limitMap(groupApps.guestUploadLimits)}}; }`,
    '    // The folders under groups/{g}/apps/{appId}/ whose files are kept for the',
    '    // record (retainedFolders): no client deletes, overwrites or changes one.',
    `    function retainedFolders() { return {${folderMap(groupApps.retainedFolders)}}; }`,
    END,
  ].join('\n');
}

/** [current] storage.rules with its generated section rendered from [table]. */
function generateStorageRules(current, table) {
  const start = current.indexOf(BEGIN);
  const end = current.indexOf(END);
  if (start < 0 || end < start) throw new Error('storage.rules has no BEGIN/END GENERATED storage families section');
  return current.slice(0, start) + renderGenerated(table) + current.slice(end + END.length);
}

/** [{ block, family }] for every match block the table declares. */
function declaredMatchBlocks(table) {
  return Object.entries(table.families).flatMap(([family, f]) => (f.matchBlocks || []).map((block) => ({ block, family })));
}

function main(argv = process.argv.slice(2)) {
  const table = loadStorageTable();
  const problems = validateStorageTable(table);
  if (problems.length) {
    console.error(`security/storage_paths.json is invalid:\n  - ${problems.join('\n  - ')}`);
    process.exitCode = 1;
    return;
  }
  const current = fs.readFileSync(RULES_PATH, 'utf8');
  const next = generateStorageRules(current, table);
  if (argv.includes('--check')) {
    if (next !== current) {
      console.error('storage.rules is out of date with security/storage_paths.json. Run `node security/generate.js` and commit the result.');
      process.exitCode = 1;
    } else {
      console.log('storage.rules matches security/storage_paths.json.');
    }
    return;
  }
  if (next !== current) fs.writeFileSync(RULES_PATH, next);
  console.log(next !== current ? 'storage.rules regenerated.' : 'storage.rules already up to date.');
}

if (require.main === module) main();

module.exports = {
  TABLE_PATH, RULES_PATH, TENANT_PATTERN, BEGIN, END, GATE_BLOCKS,
  loadStorageTable, validateStorageTable, parsePattern, classify, familyOfPath, signedInReads,
  renderGenerated, generateStorageRules, declaredMatchBlocks, main,
};
