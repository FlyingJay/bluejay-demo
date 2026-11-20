'use strict';

/**
 * Small, dependency-free helpers for CI checks over the app's Dart source
 * (lib/ and packages/<pkg>/lib/). They read the code with comments and
 * string contents blanked out, so a mention in a comment or a string never
 * counts as a use, and find constructor calls by a balanced-paren scan.
 */

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');

/** Every .dart file under [dir], recursively, as absolute paths. */
function dartFilesUnder(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartFilesUnder(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

/** The app's Dart source files: lib/ and packages/<pkg>/lib/, repo-relative. */
function appDartFiles(root = ROOT) {
  const dirs = [path.join(root, 'lib')];
  const packages = path.join(root, 'packages');
  if (fs.existsSync(packages)) {
    for (const pkg of fs.readdirSync(packages, { withFileTypes: true })) {
      if (pkg.isDirectory()) dirs.push(path.join(packages, pkg.name, 'lib'));
    }
  }
  return dirs.flatMap((dir) => dartFilesUnder(dir)).map((file) => path.relative(root, file)).sort();
}

/**
 * [source] with comments and the contents of string literals replaced by
 * spaces (newlines kept, so offsets and line numbers still match). Handles
 * // and nested block comments, single, double and triple quotes, and raw
 * strings. Interpolations are blanked with the rest of the string, which is
 * fine for these checks.
 */
function blankCommentsAndStrings(source) {
  const out = source.split('');
  const blank = (from, to) => {
    for (let k = from; k < to; k += 1) if (out[k] !== '\n') out[k] = ' ';
  };
  let i = 0;
  const n = source.length;
  while (i < n) {
    const c = source[i];
    const next = source[i + 1];
    if (c === '/' && next === '/') {
      const end = source.indexOf('\n', i);
      const stop = end === -1 ? n : end;
      blank(i, stop);
      i = stop;
    } else if (c === '/' && next === '*') {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (source[j] === '/' && source[j + 1] === '*') { depth += 1; j += 2; } else if (source[j] === '*' && source[j + 1] === '/') { depth -= 1; j += 2; } else j += 1;
      }
      blank(i, j);
      i = j;
    } else if (c === "'" || c === '"') {
      const raw = i > 0 && source[i - 1] === 'r';
      const triple = source.startsWith(c.repeat(3), i);
      const quote = triple ? c.repeat(3) : c;
      let j = i + quote.length;
      while (j < n) {
        if (!raw && source[j] === '\\') { j += 2; continue; }
        if (source.startsWith(quote, j)) break;
        if (!triple && source[j] === '\n') break;
        j += 1;
      }
      blank(i + quote.length, j);
      i = Math.min(n, j + quote.length);
    } else {
      i += 1;
    }
  }
  return out.join('');
}

/** 1-based line number of [offset] in [source]. */
function lineAt(source, offset) {
  let line = 1;
  for (let k = 0; k < offset; k += 1) if (source[k] === '\n') line += 1;
  return line;
}

/**
 * Calls in [code] (already blanked) whose name matches [nameRegex], a
 * regex source matching up to the opening paren, e.g. `FloatingActionButton(?:\.\w+)?`.
 * Returns {name, offset, args}: args is the text between the balanced
 * parens. Identifiers that merely end in the name (MyFloatingActionButton)
 * don't count.
 */
function findCalls(code, nameRegex) {
  const re = new RegExp(`(?<![\\w$])(${nameRegex})\\s*\\(`, 'g');
  const calls = [];
  let m;
  while ((m = re.exec(code)) !== null) {
    const open = m.index + m[0].length - 1;
    let depth = 0;
    let close = -1;
    for (let k = open; k < code.length; k += 1) {
      if (code[k] === '(') depth += 1;
      else if (code[k] === ')') {
        depth -= 1;
        if (depth === 0) { close = k; break; }
      }
    }
    calls.push({ name: m[1], offset: m.index, args: close === -1 ? code.slice(open + 1) : code.slice(open + 1, close) });
  }
  return calls;
}

/** Whether [args] (a call's blanked argument text) passes the named argument [name] at its top level. */
function hasNamedArgument(args, name) {
  let depth = 0;
  const re = new RegExp(`^\\s*${name}\\s*:`);
  let start = 0;
  for (let k = 0; k <= args.length; k += 1) {
    const ch = args[k];
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
    else if ((ch === ',' && depth === 0) || k === args.length) {
      if (re.test(args.slice(start, k))) return true;
      start = k + 1;
    }
  }
  return false;
}

module.exports = { ROOT, appDartFiles, blankCommentsAndStrings, lineAt, findCalls, hasNamedArgument };
