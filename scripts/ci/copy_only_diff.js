#!/usr/bin/env node
/**
 * Whether a file's change is copy-only: the code is token-for-token the same
 * and only comments and user-facing text changed. The PR auto-merge
 * (pr_lanes.js) uses it to merge an advisor's wording change to app copy or
 * the /about pages without the owner reviewing it.
 *
 * Supported files:
 *   .dart  Comments may change freely. A string literal may change when both
 *          its old and new text read as prose (PROSE_MIN_WORDS words or
 *          more), so identifiers, keys, ids, routes and short status values
 *          ('in progress') can never change through here. Interpolations
 *          inside a string must stay identical. Adjacent literals ('a' 'b')
 *          count as one string, so rewrapping a sentence is fine.
 *   .html  Comments and text between tags may change freely. Tags must stay
 *          identical except the prose attributes in PROSE_ATTRIBUTES (and a
 *          meta description/og/twitter `content`), which follow the Dart
 *          string rule. <script> and <style> bodies must stay identical.
 *   .json  The parsed values must be equal except string values that follow
 *          the Dart string rule (e.g. an app manifest's description).
 *
 * Anything that fails to tokenize or parse is not copy-only.
 */

'use strict';

const PROSE_MIN_WORDS = 3;
const PROSE_ATTRIBUTES = new Set(['alt', 'title', 'aria-label', 'aria-description', 'placeholder']);
const META_CONTENT_NAMES = /^(description|og:title|og:description|og:image:alt|twitter:title|twitter:description|twitter:image:alt)$/i;

/** Whether a piece of text reads as prose rather than a value. */
function isProse(text) {
  const words = String(text).trim().split(/\s+/).filter((w) => /\p{L}/u.test(w));
  return words.length >= PROSE_MIN_WORDS;
}

/** Old and new text may differ only when both are prose. */
function textChangeOk(a, b) {
  return a === b || (isProse(a) && isProse(b));
}

// ---------------------------------------------------------------------------
// Dart
// ---------------------------------------------------------------------------

const IDENT = /[A-Za-z0-9_$]/;

/**
 * Tokens for Dart source: { t: 'code', v } and { t: 'str', text, interps }.
 * `text` is the literal's source text with each interpolation replaced by
 * \u0000; `interps` holds each interpolation's tokens, serialized. Comments
 * and whitespace are dropped. Throws on unterminated strings or comments.
 */
function lexDart(src) {
  let i = 0;
  const n = src.length;

  function lexUntilClose() {
    // Inside ${ ... }: lex until the brace that closes it.
    const toks = [];
    let depth = 0;
    for (;;) {
      const tok = next();
      if (tok === null) throw new Error('unterminated interpolation');
      if (tok.t === 'code' && tok.v === '{') depth += 1;
      if (tok.t === 'code' && tok.v === '}') {
        if (depth === 0) return toks;
        depth -= 1;
      }
      toks.push(tok);
    }
  }

  function readString(raw) {
    const q = src[i];
    const triple = src.startsWith(q.repeat(3), i);
    const close = triple ? q.repeat(3) : q;
    i += close.length;
    let text = '';
    const interps = [];
    for (;;) {
      if (i >= n) throw new Error('unterminated string');
      if (src.startsWith(close, i)) {
        i += close.length;
        return { t: 'str', text, interps };
      }
      const c = src[i];
      if (!triple && c === '\n') throw new Error('newline in string');
      if (!raw && c === '\\') {
        text += src.slice(i, i + 2);
        i += 2;
        continue;
      }
      if (!raw && c === '$') {
        if (src[i + 1] === '{') {
          i += 2;
          interps.push(serialize(lexUntilClose()));
          text += '\u0000';
          continue;
        }
        const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(i + 1));
        if (m) {
          i += 1 + m[0].length;
          interps.push(m[0]);
          text += '\u0000';
          continue;
        }
      }
      text += c;
      i += 1;
    }
  }

  function next() {
    for (;;) {
      while (i < n && /\s/.test(src[i])) i += 1;
      if (i >= n) return null;
      if (src.startsWith('//', i)) {
        const end = src.indexOf('\n', i);
        i = end === -1 ? n : end + 1;
        continue;
      }
      if (src.startsWith('/*', i)) {
        let depth = 0;
        do {
          if (i >= n) throw new Error('unterminated comment');
          if (src.startsWith('/*', i)) { depth += 1; i += 2; } else if (src.startsWith('*/', i)) { depth -= 1; i += 2; } else i += 1;
        } while (depth > 0);
        continue;
      }
      break;
    }
    const c = src[i];
    if (c === "'" || c === '"') return readString(false);
    if (c === 'r' && (src[i + 1] === "'" || src[i + 1] === '"') && !(i > 0 && IDENT.test(src[i - 1]))) {
      i += 1;
      return readString(true);
    }
    if (IDENT.test(c)) {
      let j = i;
      while (j < n && IDENT.test(src[j])) j += 1;
      const v = src.slice(i, j);
      i = j;
      return { t: 'code', v };
    }
    i += 1;
    return { t: 'code', v: c };
  }

  const out = [];
  for (let tok = next(); tok !== null; tok = next()) {
    const prev = out[out.length - 1];
    if (tok.t === 'str' && prev && prev.t === 'str') {
      // Adjacent literals are one string in Dart.
      prev.text += tok.text;
      prev.interps.push(...tok.interps);
    } else {
      out.push(tok);
    }
  }
  return out;
}

function serialize(tokens) {
  return tokens.map((t) => (t.t === 'code' ? t.v : `"${t.text}"[${t.interps.join(',')}]`)).join(' ');
}

function compareStringTokens(a, b, where) {
  if (a.interps.join('\u0001') !== b.interps.join('\u0001')) return `${where}: a string's interpolations changed`;
  if (!textChangeOk(a.text.replace(/\u0000/g, ' '), b.text.replace(/\u0000/g, ' '))) {
    return `${where}: a short string changed (${JSON.stringify(a.text)} -> ${JSON.stringify(b.text)}); only prose of ${PROSE_MIN_WORDS}+ words may change`;
  }
  return null;
}

function compareTokens(oldToks, newToks) {
  if (oldToks.length !== newToks.length) return 'code tokens were added or removed';
  for (let k = 0; k < oldToks.length; k += 1) {
    const a = oldToks[k];
    const b = newToks[k];
    if (a.t !== b.t) return `token ${k}: code changed`;
    if (a.t === 'code') {
      if (a.v !== b.v) return `token ${k}: code changed (${a.v} -> ${b.v})`;
      continue;
    }
    const problem = compareStringTokens(a, b, `token ${k}`);
    if (problem) return problem;
  }
  return null;
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

/** Parses one tag's source (`<a href="x" title="y">`) into name + attributes. */
function parseTag(tag) {
  const m = /^<\s*(\/?)\s*([A-Za-z][A-Za-z0-9:-]*)([\s\S]*?)(\/?)\s*>$/.exec(tag);
  if (!m) return { raw: tag.replace(/\s+/g, ' ') };
  const attrs = [];
  const re = /([^\s=/>]+)(?:\s*=\s*("([^"]*)"|'([^']*)'|[^\s>]+))?/g;
  let a;
  while ((a = re.exec(m[3]))) {
    const value = a[3] !== undefined ? a[3] : (a[4] !== undefined ? a[4] : a[2]);
    attrs.push({ name: a[1].toLowerCase(), value: value === undefined ? null : value });
  }
  return { close: m[1], name: m[2].toLowerCase(), attrs, selfClose: m[4] };
}

/** Tokens for HTML: { t: 'tag', tag }, { t: 'text', v }, { t: 'raw', v } (script/style bodies). */
function lexHtml(src) {
  const out = [];
  let i = 0;
  const n = src.length;
  let text = '';
  const flushText = () => {
    const v = text.replace(/\s+/g, ' ').trim();
    if (v) out.push({ t: 'text', v });
    text = '';
  };
  while (i < n) {
    if (src.startsWith('<!--', i)) {
      const end = src.indexOf('-->', i + 4);
      if (end === -1) throw new Error('unterminated comment');
      i = end + 3;
      text += ' ';
      continue;
    }
    if (src[i] === '<' && /[A-Za-z/!]/.test(src[i + 1] || '')) {
      flushText();
      let j = i + 1;
      let quote = null;
      while (j < n && (quote || src[j] !== '>')) {
        if (quote) { if (src[j] === quote) quote = null; } else if (src[j] === '"' || src[j] === "'") quote = src[j];
        j += 1;
      }
      if (j >= n) throw new Error('unterminated tag');
      const tag = parseTag(src.slice(i, j + 1));
      out.push({ t: 'tag', tag });
      i = j + 1;
      if (!tag.close && (tag.name === 'script' || tag.name === 'style')) {
        const end = src.toLowerCase().indexOf(`</${tag.name}`, i);
        if (end === -1) throw new Error(`unterminated <${tag.name}>`);
        out.push({ t: 'raw', v: src.slice(i, end) });
        i = end;
      }
      continue;
    }
    text += src[i];
    i += 1;
  }
  flushText();
  return out;
}

function proseAttribute(tag, attr) {
  if (PROSE_ATTRIBUTES.has(attr.name)) return true;
  if (tag.name === 'meta' && attr.name === 'content') {
    const key = tag.attrs.find((x) => x.name === 'name' || x.name === 'property');
    return Boolean(key && key.value && META_CONTENT_NAMES.test(key.value));
  }
  return false;
}

function compareTags(a, b) {
  if (a.raw !== undefined || b.raw !== undefined) return a.raw === b.raw ? null : 'a tag changed';
  if (a.close !== b.close || a.name !== b.name || a.selfClose !== b.selfClose || a.attrs.length !== b.attrs.length) {
    return `<${a.name}> changed`;
  }
  for (let k = 0; k < a.attrs.length; k += 1) {
    const x = a.attrs[k];
    const y = b.attrs[k];
    if (x.name !== y.name) return `<${a.name}> attributes changed`;
    if (x.value === y.value) continue;
    if (!proseAttribute(a, x) || !textChangeOk(x.value || '', y.value || '')) {
      return `<${a.name}> attribute ${x.name} changed`;
    }
  }
  return null;
}

function compareHtml(oldToks, newToks) {
  if (oldToks.length !== newToks.length) return 'tags or text blocks were added or removed';
  for (let k = 0; k < oldToks.length; k += 1) {
    const a = oldToks[k];
    const b = newToks[k];
    if (a.t !== b.t) return 'page structure changed';
    if (a.t === 'raw' && a.v !== b.v) return 'a <script> or <style> body changed';
    if (a.t === 'tag') {
      const problem = compareTags(a.tag, b.tag);
      if (problem) return problem;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

function compareJson(a, b, where = '$') {
  if (typeof a === 'string' && typeof b === 'string') {
    return textChangeOk(a, b) ? null : `${where}: a short string changed`;
  }
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') {
    return a === b ? null : `${where}: a value changed`;
  }
  if (Array.isArray(a) !== Array.isArray(b)) return `${where}: structure changed`;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length || ka.some((k, idx) => k !== kb[idx])) return `${where}: keys changed`;
  for (const k of ka) {
    const problem = compareJson(a[k], b[k], `${where}.${k}`);
    if (problem) return problem;
  }
  return null;
}

// ---------------------------------------------------------------------------

/**
 * { copyOnly, reason } for a file's old and new contents. `filename` picks
 * the language; unsupported extensions are never copy-only.
 */
function copyOnlyChange(filename, oldText, newText) {
  const ext = (/\.([A-Za-z0-9]+)$/.exec(filename) || [])[1];
  try {
    let problem;
    if (ext === 'dart') problem = compareTokens(lexDart(oldText), lexDart(newText));
    else if (ext === 'html') problem = compareHtml(lexHtml(oldText), lexHtml(newText));
    else if (ext === 'json') problem = compareJson(JSON.parse(oldText), JSON.parse(newText));
    else return { copyOnly: false, reason: `${filename}: .${ext || '?'} files can't be checked for copy-only changes` };
    return problem ? { copyOnly: false, reason: `${filename}: ${problem}` } : { copyOnly: true, reason: 'copy-only' };
  } catch (error) {
    return { copyOnly: false, reason: `${filename}: could not be read as .${ext} (${error.message})` };
  }
}

module.exports = { copyOnlyChange, isProse, lexDart, lexHtml, PROSE_MIN_WORDS };
