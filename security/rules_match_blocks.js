/**
 * Finds every `match` block in a rules file, for the exception guard
 * (security/check_rules_exceptions.js): a block nobody listed must not hide
 * inside another one. Structural, not a grammar parser: brace-depth tracking
 * over the text with comments and string literals blanked out. The rules'
 * actual decisions are tested in the emulator by security/rules-tests.
 *
 * Pure functions, no filesystem access. See rules_match_blocks.test.js.
 */
'use strict';

/**
 * The rules text with comments and string-literal contents replaced by spaces
 * (newlines kept), so offsets and line numbers still line up with the
 * original. Brace counting and `match` scanning then can't be fooled by a
 * comment like "// see match /users/{uid} {" or a string holding a brace.
 */
function blankCommentsAndStrings(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') { out += ' '; i++; }
    } else if (ch === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2);
      const stop = end === -1 ? text.length : end + 2;
      for (; i < stop; i++) out += text[i] === '\n' ? '\n' : ' ';
    } else if (ch === '"' || ch === "'") {
      out += ch;
      i++;
      while (i < text.length && text[i] !== ch && text[i] !== '\n') {
        if (text[i] === '\\') { out += ' '; i++; }
        if (i < text.length) { out += ' '; i++; }
      }
      if (i < text.length) { out += text[i]; i++; }
    } else {
      out += ch;
      i++;
    }
  }
  return out;
}

// A match path: one or more `/segment` where a segment is a literal
// (`users`, `logo.jpg`) or a wildcard (`{id}`, `{allPaths=**}`).
const MATCH_RE = /\bmatch\s+((?:\/(?:\{[^}\s]*\}|[^/\s{}]+))+)\s*\{/y;

/**
 * Every `match` block in a rules file, at any depth, in source order,
 * whatever its path shape or nesting.
 *
 * Returns: [{ path, fullPath, parents, line }]
 *   path     — the block's own path text, e.g. `/{subcollection}/{subId}`
 *   fullPath — the enclosing match paths joined with it, e.g.
 *              `/databases/{database}/documents/{collection}/{id}/{subcollection}/{subId}`
 *   parents  — the enclosing blocks' full paths, outermost first
 *   line     — 1-based line of the `match` keyword
 */
function parseAllMatchBlocks(rulesText) {
  const text = blankCommentsAndStrings(rulesText);
  const blocks = [];
  const stack = []; // one entry per open `{`: the match fullPath, or null
  let line = 1;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '\n') { line++; continue; }
    if (ch === 'm' && (i === 0 || !/[A-Za-z0-9_]/.test(text[i - 1]))) {
      MATCH_RE.lastIndex = i;
      const m = MATCH_RE.exec(text);
      if (m) {
        const parents = stack.filter(Boolean);
        const fullPath = (parents[parents.length - 1] || '') + m[1];
        blocks.push({ path: m[1], fullPath, parents, line });
        stack.push(fullPath);
        line += (m[0].match(/\n/g) || []).length;
        i += m[0].length - 1;
        continue;
      }
    }
    if (ch === '{') stack.push(null);
    else if (ch === '}') stack.pop();
  }
  return blocks;
}

module.exports = { blankCommentsAndStrings, parseAllMatchBlocks };
