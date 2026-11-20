#!/usr/bin/env node
/**
 * The exception guard (plans/firestore-rules/IMPLEMENTATION_PLAN.md §6.5, T3).
 *
 *   node security/check_rules_exceptions.js   exit 1 on any problem (CI runs it
 *                                             through check_rules_exceptions.test.js)
 *
 * Every grant in firestore.rules and storage.rules must come from the generic
 * tenant rule or from a reviewed exception recorded in security/collections.json
 * (`exceptions`, each with `what`, `why` and a `reviewed` date). Storage path
 * families declare their own match blocks, with the same what/why/reviewed,
 * in security/storage_paths.json (T16). An exception
 * is never a new `match` block or `||` someone slips in unreviewed. This fails
 * when:
 *   1. a `match` block (at any depth) is neither a generic block nor listed in
 *      an exception's firestoreMatchBlocks / storageMatchBlocks;
 *   2. an exception lists a block that no longer exists, or two exceptions
 *      list the same block (so the list can't silently rot);
 *   3. the table itself is invalid, including an exception without `why` or a
 *      real `reviewed` date (security/generate.js's validator);
 *   4. a `grant*` rule function in firestore.rules doesn't call inTenant()
 *      (directly or through another function) and no exception lists it in
 *      ruleFunctions; or a listed function no longer exists; or the rules
 *      read `visibility` or name the removed `auditor` role (plan D2, D4a).
 *      See checkInTenantGrants() below.
 *
 * Both files and the table are CODEOWNERS-protected (.github/CODEOWNERS), so
 * adding an exception needs the code owner's review.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { parseAllMatchBlocks } = require('./rules_match_blocks');
const { loadTable, validateTable, SCHEMA_PATH } = require('./generate');

const ROOT = path.resolve(__dirname, '..');

/**
 * The rules files the guard covers. `generic` blocks are the tenant rule
 * itself (paths relative to `root`); everything else needs an exception.
 */
const RULES_FILES = [
  {
    file: 'firestore.rules',
    root: '/databases/{database}/documents',
    tableKey: 'firestoreMatchBlocks',
    generic: [
      '/{collection}/{id}',
      '/{collection}/{id}/{subcollection}/{subId}',
      // Collection-group queries over the declared collection groups.
      '/{path=**}/{group}/{id}',
    ],
  },
  {
    file: 'storage.rules',
    root: '/b/{bucket}/o',
    tableKey: 'storageMatchBlocks',
    generic: [
      '/groups/{groupId}/apps/{appId}/{allPaths=**}',
    ],
    // With security/storage_paths.json (T16): the generated signedIn read
    // blocks, plus every family block the table declares (reviewed there).
    declaredBy: 'security/storage_paths.json',
  },
];

/** { matchBlock: family } for the Storage blocks security/storage_paths.json declares. */
function storageDeclaredBlocks(storageTable) {
  const { declaredMatchBlocks } = require('./generate_storage');
  return new Map(declaredMatchBlocks(storageTable).map(({ block, family }) => [block, family]));
}

/** Match blocks below the service root: [{ path (relative to root), line }]. */
function matchBlocksUnderRoot(rulesText, root) {
  return parseAllMatchBlocks(rulesText)
    .filter((b) => b.fullPath !== root)
    .map((b) => ({
      path: b.fullPath.startsWith(`${root}/`) ? b.fullPath.slice(root.length) : b.fullPath,
      outsideRoot: !b.fullPath.startsWith(`${root}/`),
      line: b.line,
    }));
}

/** { name: body } for every `function name(...) { body }` in a rules file (comments blanked). */
function ruleFunctions(rulesText) {
  const text = blankComments(rulesText);
  const out = {};
  const re = /function\s+([A-Za-z0-9_]+)\s*\([^)]*\)\s*\{/g;
  let m;
  while ((m = re.exec(text))) {
    let depth = 1;
    let i = re.lastIndex;
    while (depth > 0 && i < text.length) {
      if (text[i] === '{') depth += 1;
      else if (text[i] === '}') depth -= 1;
      i += 1;
    }
    out[m[1]] = text.slice(re.lastIndex, i - 1);
  }
  return out;
}

/** The rules text with // comments replaced by spaces (strings kept). */
function blankComments(text) {
  return text.split('\n').map((line) => {
    let inStr = null;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (inStr) {
        if (ch === '\\') i += 1;
        else if (ch === inStr) inStr = null;
      } else if (ch === '"' || ch === "'") inStr = ch;
      else if (ch === '/' && line[i + 1] === '/') return line.slice(0, i);
    }
    return line;
  }).join('\n');
}

/**
 * Pillar 2's guard (plan 2.1, 4.1): every grant goes through inTenant()
 * unless it is a reviewed exception. Convention: functions that grant
 * access are named `grant*`. Each must call inTenant() (directly, or
 * through functions it calls), or be listed in an exception's
 * ruleFunctions. Also fails on a listed function that doesn't exist, and on
 * any `visibility` read or `auditor` role in the rules (D2, D4a). A read is
 * the field used as an identifier (`d.visibility`), a subscript
 * (`d['visibility']`) or a `.get('visibility', …)`. The name quoted in a
 * field list (the generated serverFields() locks) blocks client writes to
 * the field, which D2 doesn't forbid.
 */
function checkInTenantGrants(rulesText, table) {
  const problems = [];
  const fns = ruleFunctions(rulesText);
  const approved = new Map();
  for (const [id, ex] of Object.entries(table.exceptions || {})) {
    for (const fn of ex.ruleFunctions || []) approved.set(fn, id);
  }
  const callsInTenant = (name, seen = new Set()) => {
    if (seen.has(name) || !(name in fns)) return false;
    seen.add(name);
    const body = fns[name];
    if (/\binTenant\s*\(/.test(body)) return true;
    return [...body.matchAll(/\b([A-Za-z0-9_]+)\s*\(/g)].some(([, callee]) => callee !== name && callsInTenant(callee, seen));
  };
  for (const name of Object.keys(fns)) {
    if (!name.startsWith('grant')) continue;
    if (!approved.has(name) && !callsInTenant(name)) {
      problems.push(`firestore.rules: ${name}() grants without inTenant() and no exception lists it in ruleFunctions`);
    }
  }
  for (const [fn, id] of approved) {
    if (!(fn in fns)) problems.push(`${id} lists rule function ${fn}(), but firestore.rules has no such function; remove it`);
  }
  const code = blankComments(rulesText);
  const unquoted = code.replace(/'[^'\n]*'|"[^"\n]*"/g, "''");
  const readsVisibility = /\bvisibility\b/.test(unquoted) ||
    /[\w)\]]\s*\[\s*['"]visibility['"]\s*\]|\.get\(\s*['"]visibility['"]/.test(code);
  if (readsVisibility) problems.push('firestore.rules reads `visibility`: public content lives in the public namespace (D2), never in the tenant rule');
  if (/\bauditor\b/.test(code)) problems.push('firestore.rules names the `auditor` role, which was removed (D4a)');
  return problems;
}

/**
 * Every problem with the rules files against the table's exceptions ([] = pass).
 * `rules` maps a RULES_FILES file name to its text; a missing file is skipped.
 */
function checkRulesExceptions(rules, table, { schema, tableText, storageTable } = {}) {
  const problems = [];
  if (schema) problems.push(...validateTable(table, schema, tableText));
  if (storageTable) {
    const { validateStorageTable } = require('./generate_storage');
    problems.push(...validateStorageTable(storageTable).map((p) => `security/storage_paths.json: ${p}`));
  }
  const exceptions = table.exceptions || {};

  for (const cfg of RULES_FILES) {
    const text = rules[cfg.file];
    if (text === undefined) continue;

    const approvedBy = new Map();
    for (const [id, ex] of Object.entries(exceptions)) {
      for (const p of ex[cfg.tableKey] || []) {
        if (approvedBy.has(p)) {
          problems.push(`${cfg.file} ${p} is listed by both ${approvedBy.get(p)} and ${id}; keep one`);
        } else {
          approvedBy.set(p, id);
        }
      }
    }

    // Storage: blocks a path family declares in the storage table are
    // reviewed there (what/why/reviewed), like a collections.json policy entry.
    const declared = cfg.declaredBy && storageTable ? storageDeclaredBlocks(storageTable) : new Map();
    const generic = [...cfg.generic, ...(cfg.declaredBy && storageTable ? require('./generate_storage').GATE_BLOCKS : [])];
    for (const [p, family] of declared) {
      if (approvedBy.has(p)) problems.push(`${cfg.file} ${p} is declared by ${cfg.declaredBy} (${family}) and listed by ${approvedBy.get(p)}; keep one`);
    }

    const seen = new Set();
    for (const block of matchBlocksUnderRoot(text, cfg.root)) {
      seen.add(block.path);
      if (block.outsideRoot) {
        problems.push(`${cfg.file}:${block.line}: match ${block.path} is outside ${cfg.root}`);
      } else if (!generic.includes(block.path) && !approvedBy.has(block.path) && !declared.has(block.path)) {
        problems.push(
          `${cfg.file}:${block.line}: match ${block.path} is not the generic rule and no reviewed ` +
          `exception lists it. Fold it into the generic rule (a collections.json policy entry), or add ` +
          `an "exceptions" entry with what/why/reviewed and ${cfg.tableKey}: ["${block.path}"] ` +
          `to security/collections.json (code-owner review required).`);
      }
    }
    for (const [p, id] of approvedBy) {
      if (!seen.has(p)) problems.push(`${id} lists ${cfg.file} ${p}, but there is no such match block; remove it`);
    }
    for (const [p, family] of declared) {
      if (!seen.has(p)) problems.push(`${cfg.declaredBy} families.${family} declares ${cfg.file} ${p}, but there is no such match block; remove it`);
    }
    if (cfg.file === 'firestore.rules') problems.push(...checkInTenantGrants(text, table));
  }
  return problems;
}

/** The guard against the repo's own files. */
function checkRepo(root = ROOT) {
  const tablePath = path.join(root, 'security', 'collections.json');
  const tableText = fs.readFileSync(tablePath, 'utf8');
  const table = JSON.parse(tableText);
  const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
  const rules = {};
  for (const cfg of RULES_FILES) {
    const p = path.join(root, cfg.file);
    if (fs.existsSync(p)) rules[cfg.file] = fs.readFileSync(p, 'utf8');
  }
  const storageTablePath = path.join(root, 'security', 'storage_paths.json');
  const storageTable = fs.existsSync(storageTablePath) ? JSON.parse(fs.readFileSync(storageTablePath, 'utf8')) : undefined;
  return checkRulesExceptions(rules, table, { schema, tableText, storageTable });
}

function main() {
  const problems = checkRepo();
  if (problems.length) {
    console.error(`Rules exception guard failed:\n  - ${problems.join('\n  - ')}`);
    process.exitCode = 1;
    return;
  }
  const count = Object.keys(loadTable().exceptions || {}).length;
  console.log(`Every match block is generic or one of ${count} reviewed exceptions.`);
}

if (require.main === module) main();

module.exports = { RULES_FILES, matchBlocksUnderRoot, ruleFunctions, checkInTenantGrants, checkRulesExceptions, checkRepo };
