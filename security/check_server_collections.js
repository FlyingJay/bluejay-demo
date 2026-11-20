#!/usr/bin/env node
/**
 * Server-ownership guard (plans/firestore-rules/IMPLEMENTATION_PLAN.md §4.4, T13).
 *
 * Every Firestore collection that Cloud Functions code touches must have a
 * declared owner:
 *   - server-owned in security/collections.json (`kind: "server"`, `"public"` or
 *     `serverWritten: true`; for a subcollection,
 *     `subcollections.<name>.serverWritten` on any parent), or
 *   - listed in security/client_written_collections.json, with the reason
 *     it isn't server-owned (almost always: clients still write it) and the
 *     client files that write it.
 * (`ownMatchBlock` doesn't count: those blocks let admins or members write.)
 *
 * A collection only the server writes but that nobody declared is exactly
 * the gap §4.4 found 27 times: once the repo rules deploy, any client could
 * forge or pre-claim its docs through the generic wildcard. This makes that
 * a CI failure the moment a function starts using a new collection.
 *
 * The scan counts every reference in deployed functions code (reads too).
 * Telling a read from a write statically is unreliable (refs are built in
 * one place and written through tx/batch in another), and a collection the
 * server only reads is still one somebody writes, so it needs an owner too.
 *
 * Extraction (functions/**\/*.js, minus tests, test fakes and scripts/):
 *   .collection('x') / .collectionGroup('x') / .doc('x/…') / .collection(`x/${id}/y`)
 *   identifiers bound to string literals (`const FOO_COLLECTION = 'x'`, also
 *   when imported from another module by the same name), object maps
 *   (`COLLECTIONS.orders`, `REGIONS_DOC.collection`) and arrays (`PATH[0]`).
 * A `.collection(` chained off a `.doc(…)` call or a `…Ref`/`.ref` value is a
 * subcollection; everything else is a root collection.
 *
 * Ratchet: an allowlist entry that functions no longer reference, or that
 * the table now declares server-owned, is stale and fails too, so the list
 * only shrinks as callables replace client writers.
 *
 * Usage: node security/check_server_collections.js [--list]
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { loadTable } = require('./generate');

const ROOT = path.resolve(__dirname, '..');
const ALLOWLIST_PATH = path.join(__dirname, 'client_written_collections.json');
const SKIP_DIRS = new Set(['node_modules', '.git', 'test', 'scripts']);
const EXCLUDE = /(\.test\.js$|^_test_fake_firestore\.js$|_test_fakes\.js$)/;

const NAME = /^[A-Za-z][A-Za-z0-9_]*$/;
const STRING = /^(['"`])([^'"`$]*?)\1$/;

/** Every deployed functions source file (relative to [root]), sorted. */
function functionsSources(root = ROOT) {
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        if (!SKIP_DIRS.has(entry.name)) walk(path.join(dir, entry.name));
      } else if (entry.name.endsWith('.js') && !EXCLUDE.test(entry.name)) {
        out.push(path.relative(root, path.join(dir, entry.name)).split(path.sep).join('/'));
      }
    }
  };
  walk(path.join(root, 'functions'));
  return out.sort();
}

/** [source] with comments blanked out (strings kept), so commented-out code isn't scanned. */
function stripComments(source) {
  let out = '';
  let quote = null;
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (quote) {
      out += c;
      if (c === '\\') out += source[++i] || '';
      else if (c === quote) quote = null;
      continue;
    }
    if (c === '/' && source[i + 1] === '/') {
      while (i < source.length && source[i] !== '\n') i++;
      out += '\n';
      continue;
    }
    if (c === '/' && source[i + 1] === '*') {
      const end = source.indexOf('*/', i + 2);
      const stop = end === -1 ? source.length : end + 2;
      out += source.slice(i, stop).replace(/[^\n]/g, ' ');
      i = stop - 1;
      continue;
    }
    if (c === "'" || c === '"' || c === '`') quote = c;
    out += c;
  }
  return out;
}

/**
 * String bindings in one file: `NAME = 'lit'`, `NAME = { key: 'lit' }`
 * (also Object.freeze({…})) and `NAME = ['a', 'b']`. Returns
 * { 'NAME': 'lit', 'NAME.key': 'lit', 'NAME[0]': 'a' }.
 */
function stringBindings(source) {
  const out = {};
  for (const m of source.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(['"])([A-Za-z0-9_/{}$.-]+)\2\s*[;,\n]/g)) {
    out[m[1]] = m[3];
  }
  for (const m of source.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:Object\.freeze\(\s*)?\{([^{}]*)\}/g)) {
    for (const p of m[2].matchAll(/([A-Za-z_$][\w$]*)\s*:\s*(['"])([A-Za-z0-9_]+)\2/g)) out[`${m[1]}.${p[1]}`] = p[3];
  }
  for (const m of source.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:Object\.freeze\(\s*)?\[([^\[\]]*)\]/g)) {
    const items = m[2].split(',').map((s) => s.trim()).filter(Boolean);
    items.forEach((item, i) => {
      const lit = STRING.exec(item);
      if (lit) out[`${m[1]}[${i}]`] = lit[2];
    });
  }
  return out;
}

/** Index just past the `)` matching the `(` at [open]. */
function closeParen(text, open) {
  let depth = 0;
  let quote = null;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === '\\') i++;
      else if (c === quote) quote = null;
    } else if (c === "'" || c === '"' || c === '`') quote = c;
    else if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return i + 1;
  }
  return text.length;
}

/** Index of the `(` matching the `)` at [close] (scanning backwards). */
function openParen(text, close) {
  let depth = 0;
  for (let i = close; i >= 0; i--) {
    if (text[i] === ')') depth++;
    else if (text[i] === '(' && --depth === 0) return i;
  }
  return -1;
}

/** Whether the receiver ending just before [dot] is a document (so `.collection(` there is a subcollection). */
function receiverIsDocument(text, dot) {
  let i = dot - 1;
  while (i >= 0 && /\s/.test(text[i])) i--;
  if (text[i] === ')') {
    const open = openParen(text, i);
    return /\.doc\s*$/.test(text.slice(Math.max(0, open - 20), open));
  }
  const ident = /[A-Za-z_$][\w$.]*$/.exec(text.slice(Math.max(0, i - 80), i + 1));
  return !!ident && /(^|\.)(ref|[A-Za-z_$][\w$]*Ref|doc|[A-Za-z_$][\w$]*Doc(Ref)?)$/.test(ident[0]);
}

/** The literal text of a call argument, or null if it isn't a resolvable string. */
function resolveArg(arg, bindings) {
  const a = arg.trim();
  const lit = /^(['"])([^'"]*)\1$/.exec(a);
  if (lit) return lit[2];
  const tpl = /^`([^`]*)`$/.exec(a);
  if (tpl) {
    // `x/${id}/y` -> 'x/*/y'; `${PREFIX}/…` resolves PREFIX when it can.
    return tpl[1].replace(/\$\{\s*([^}]*?)\s*\}/g, (_, expr) => (bindings[expr] !== undefined ? bindings[expr] : '*'));
  }
  if (bindings[a] !== undefined) return bindings[a];
  return null;
}

/**
 * Collection references in one file's [source]:
 * [{ name, sub, line, text }] for resolved ones and
 * [{ line, text }] in `unresolved` for dynamic ones.
 */
function extractReferences(source, globalBindings = {}) {
  const text = stripComments(source);
  const localBindings = stringBindings(text);
  const bindings = { ...globalBindings, ...localBindings };
  const subBindings = new Set();
  const refs = [];
  const unresolved = [];
  const lineOf = (i) => text.slice(0, i).split('\n').length;
  const push = (segments, isSub, index, call) => {
    segments.forEach((seg, i) => {
      if (i % 2 !== 0 || !NAME.test(seg)) return;
      refs.push({ name: seg, sub: isSub || i > 0, line: lineOf(index), text: call });
    });
  };
  for (const m of text.matchAll(/\.(collectionGroup|collection|doc)\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    const end = closeParen(text, open);
    const arg = text.slice(open + 1, end - 1);
    const call = text.slice(m.index, end).replace(/\s+/g, ' ');
    if (!arg.trim()) continue; // .doc() = new auto id
    const value = resolveArg(arg.split(',')[0], bindings);
    if (m[1] === 'doc') {
      // Only paths ('x/id'), and only off a Firestore instance; .doc(id) on a
      // collection ref is a document id, not a collection.
      if (value === null || !value.includes('/') || receiverIsDocument(text, m.index)) continue;
      push(value.split('/'), false, m.index, call);
      continue;
    }
    if (value === null) {
      unresolved.push({ line: lineOf(m.index), text: call });
      continue;
    }
    const isSub = m[1] === 'collectionGroup' || receiverIsDocument(text, m.index);
    push(value.split('/'), isSub, m.index, call);
    if (isSub) subBindings.add(arg.split(',')[0].trim());
  }
  // Collection names held for later use (passed to a helper such as
  // enforceRateLimits, exported to another module, or kept in a config
  // map): `FOO_COLLECTION = 'x'`, `COLLECTIONS = { a: 'x' }`, and
  // `collection: 'x'` / `fooCollection: 'x'` properties; a
  // `fooSubcollection: 'x'` property names a subcollection.
  for (const [key, value] of Object.entries(localBindings)) {
    if (!/collection/i.test(key) || !NAME.test(value) || subBindings.has(key)) continue;
    const decl = new RegExp(`\\b${key.split(/[.[]/)[0].replace(/\$/g, '\\$')}\\s*=`).exec(text);
    const index = decl ? decl.index : 0;
    push([value], /subcollection/i.test(key), index, `${key} = '${value}'`);
  }
  for (const m of text.matchAll(/\b([A-Za-z_$]*[cC]ollection)(Group)?\s*:\s*(['"])([A-Za-z][A-Za-z0-9_]*)\3/g)) {
    push([m[4]], !!m[2] || /subcollection$/i.test(m[1]), m.index, m[0]);
  }
  return { refs, unresolved };
}

/**
 * Bindings exported by name across all functions files: an identifier bound
 * to the same string everywhere it's bound (so `const { INVOICES } =
 * require('./_platform_invoicing')` resolves). Conflicting names are dropped.
 */
function globalBindings(sources) {
  const seen = {};
  for (const source of sources) {
    for (const [k, v] of Object.entries(stringBindings(stripComments(source)))) {
      if (!(k in seen)) seen[k] = v;
      else if (seen[k] !== v) seen[k] = null;
    }
  }
  return Object.fromEntries(Object.entries(seen).filter(([, v]) => v !== null));
}

/** { collections: Map<name, refs[]>, subcollections: Map<name, refs[]>, unresolved: [] } for the repo. */
function scanFunctions(root = ROOT) {
  const files = functionsSources(root);
  const sources = files.map((f) => fs.readFileSync(path.join(root, f), 'utf8'));
  const globals = globalBindings(sources);
  const collections = new Map();
  const subcollections = new Map();
  const unresolved = [];
  files.forEach((file, i) => {
    const found = extractReferences(sources[i], globals);
    for (const ref of found.refs) {
      const map = ref.sub ? subcollections : collections;
      if (!map.has(ref.name)) map.set(ref.name, []);
      map.get(ref.name).push({ file, line: ref.line, text: ref.text });
    }
    for (const u of found.unresolved) unresolved.push({ file, ...u });
  });
  return { collections, subcollections, unresolved };
}

/** Server-owned root collections and subcollection names, per the table. */
function serverOwned(table) {
  const collections = new Set();
  const subcollections = new Set();
  for (const [name, entry] of Object.entries(table.collections)) {
    // kind "public" (D2): written only by functions/public_namespace.js.
    if (entry.kind === 'server' || entry.kind === 'public' || entry.serverWritten) collections.add(name);
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg.serverWritten) subcollections.add(sub);
    }
  }
  return { collections, subcollections };
}

function loadAllowlist(allowlistPath = ALLOWLIST_PATH) {
  return JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
}

/** Every reason the repo fails the guard ([] = pass). */
function check({ scan, table, allowlist, root = ROOT }) {
  const owned = serverOwned(table);
  const problems = [];
  for (const key of Object.keys(allowlist)) {
    if (!['$comment', 'collections', 'subcollections'].includes(key)) {
      problems.push(`client_written_collections.json has unknown key "${key}"`);
    }
  }
  for (const kind of ['collections', 'subcollections']) {
    const found = scan[kind];
    const declared = owned[kind];
    const allowed = allowlist[kind] || {};
    const label = kind === 'collections' ? 'collection' : 'subcollection';
    for (const [name, refs] of [...found].sort(([a], [b]) => a.localeCompare(b))) {
      if (declared.has(name) || allowed[name]) continue;
      const where = refs.slice(0, 3).map((r) => `${r.file}:${r.line}`).join(', ');
      problems.push(
        `${label} "${name}" is used by Cloud Functions (${where}) but has no declared owner. ` +
        (kind === 'collections'
          ? 'If only the server writes it, declare it in security/collections.json (kind "server", or serverWritten: true if clients read it through the tenant rule) and run `node security/generate.js`. '
          : 'If only the server writes it, declare `subcollections.' + name + '.serverWritten: true` on its parent in security/collections.json and run `node security/generate.js`. ') +
        `If clients write it, add it to security/client_written_collections.json ("${kind}") with the client writers.`,
      );
    }
    for (const [name, entry] of Object.entries(allowed)) {
      const where = `client_written_collections.json: ${kind}.${name}`;
      if (!entry || typeof entry.reason !== 'string' || !entry.reason.trim()) {
        problems.push(`${where} needs a "reason"`);
      }
      // The client files that write it, so a reviewer can check the claim
      // and the entry goes stale with them. [] only when the reason says why
      // (e.g. writes go through the collection's own match block).
      const writers = entry && entry.clientWriters;
      if (!Array.isArray(writers) || writers.some((f) => typeof f !== 'string')) {
        problems.push(`${where} needs "clientWriters": the client files that write it ([] if none, explained in "reason")`);
      } else {
        for (const file of writers) {
          if (!fs.existsSync(path.join(root, file))) problems.push(`${where}: client writer ${file} doesn't exist`);
        }
      }
      if (declared.has(name)) {
        problems.push(`client_written_collections.json: ${kind}.${name} is declared server-owned in collections.json; remove it from the allowlist`);
      } else if (!found.has(name)) {
        problems.push(`client_written_collections.json: ${kind}.${name} is no longer used by Cloud Functions; remove the stale entry`);
      }
    }
  }
  return problems;
}

function main(argv = process.argv.slice(2)) {
  const scan = scanFunctions();
  if (argv.includes('--list')) {
    for (const kind of ['collections', 'subcollections']) {
      console.log(`${kind}:`);
      for (const [name, refs] of [...scan[kind]].sort(([a], [b]) => a.localeCompare(b))) {
        console.log(`  ${name}  (${refs.length} ref(s), e.g. ${refs[0].file}:${refs[0].line})`);
      }
    }
    console.log(`unresolved (dynamic) references: ${scan.unresolved.length}`);
    for (const u of scan.unresolved) console.log(`  ${u.file}:${u.line}  ${u.text}`);
    return 0;
  }
  const problems = check({ scan, table: loadTable(), allowlist: loadAllowlist() });
  if (problems.length) {
    for (const p of problems) console.error(`- ${p}`);
    console.error(`\n${problems.length} server-ownership problem(s). See security/check_server_collections.js.`);
    return 1;
  }
  console.log(`Server-ownership check passed (${scan.collections.size} collection(s), ${scan.subcollections.size} subcollection name(s)).`);
  return 0;
}

if (require.main === module) process.exit(main());

module.exports = {
  ALLOWLIST_PATH, functionsSources, stripComments, stringBindings, extractReferences,
  globalBindings, scanFunctions, serverOwned, loadAllowlist, check,
};
