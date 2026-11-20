'use strict';

/**
 * Keeps raw exception text out of what users read. A caught exception's
 * toString() is developer text: `[firebase_functions/failed-precondition]
 * This signature request is already completed.`, `PlatformException(...)`,
 * a Dart stack-ish dump. Put into a snack bar, a Text or an error state, it
 * reads as a crash. shared_services' userFacingError
 * (packages/shared_services/lib/user_facing_error.dart) turns any error into
 * a plain sentence instead: the server's own message for a callable's
 * deliberate refusal, a plain line per Firebase error code, and a fallback
 * the caller words for everything else.
 *
 * What counts: inside a `catch (e)` block (or a `catchError((e) ...)` /
 * `onError: (e) ...` handler), `$e`, `${e}` or `${e.toString()}` in a string,
 * or `e.toString()`, when it sits in something the user sees:
 *   - the arguments of BjSnack.*, SnackBar or any other call whose name
 *     says snack (an app's own `_showSnackBar`), Text, Text.rich, TextSpan,
 *     ReadableSelectableText, BjStateView.*, BjInlineNote, AlertDialog,
 *     showBjConfirm or InputDecoration;
 *   - a named `message:`, `errorMessage:` or `errorText:` argument;
 *   - the value assigned to a field or local whose name says error, message,
 *     status, notice or feedback (`_error = 'Failed: $e'`), which a build
 *     method then shows.
 * Anywhere in a file, `${snapshot.error}` (any name containing `snap`) in
 * one of those places counts too. Passing the error object itself to
 * BjStateView.error(error: ...) is fine: the design system describes it.
 * Logging (`debugPrint('... $e')`) and rethrowing are fine.
 *
 * A use that is genuinely right, such as an admin-only diagnostics screen
 * whose readers want the raw text, says so with
 * `// error-text-ok: <reason>` on the same line or the line above. The
 * reason is required.
 *
 * Most apps predate the helper, so this is a ratchet:
 * user_facing_errors_baseline.json records, per file, how many findings
 * existed when it was taken. A file over its count (a file missing from it
 * allows none) fails, so new code can't add any. A file under its count
 * also fails until the baseline is lowered with
 *   UPDATE_BASELINE=1 node --test scripts/ci/user_facing_errors.test.js
 * which only ever lowers counts.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ROOT, appDartFiles, blankCommentsAndStrings, lineAt, findCalls } = require('./dart_source');

const BASELINE_PATH = path.join(__dirname, 'user_facing_errors_baseline.json');
const ESCAPE = /\/\/\s*error-text-ok:\s*\S/;

const SINKS = [
  'BjSnack\\.\\w+',
  '_?[A-Za-z]*[Ss]nack\\w*',
  'Text(?:\\.rich)?',
  'TextSpan',
  'ReadableSelectableText',
  'BjStateView(?:\\.\\w+)?',
  'BjInlineNote',
  'AlertDialog',
  'showBjConfirm',
  'InputDecoration',
].join('|');

const NAMED_ARGS = /(?<![\w$])(?:message|errorMessage|errorText)\s*:/g;
const ASSIGNED = /(?<![\w$.])(_?[A-Za-z]\w*)\s*=(?![=>])/g;
const MESSAGE_NAME = /error|message|status|notice|feedback/i;
const SNAPSHOT_ERROR = '[A-Za-z_]\\w*\\.error!?';

/** End of the expression starting at [from] in [code]: the first `,` `;` or unbalanced closer at depth 0. */
function expressionEnd(code, from) {
  let depth = 0;
  for (let k = from; k < code.length; k += 1) {
    const ch = code[k];
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') {
      if (depth === 0) return k;
      depth -= 1;
    } else if ((ch === ',' || ch === ';') && depth === 0) return k;
  }
  return code.length;
}

/** Index of the brace closing the one at [open]. */
function closingBrace(code, open) {
  let depth = 0;
  for (let k = open; k < code.length; k += 1) {
    if (code[k] === '{') depth += 1;
    else if (code[k] === '}') {
      depth -= 1;
      if (depth === 0) return k;
    }
  }
  return code.length;
}

/** Error handlers in [code]: {name, start, end} — the caught variable and its body's span. */
function handlers(code) {
  const out = [];
  const add = (name, bodyAt) => {
    let i = bodyAt;
    while (code[i] === ' ' || code[i] === '\n' || code[i] === '\t' || code[i] === '\r') i += 1;
    if (code[i] === '{') out.push({ name, start: i, end: closingBrace(code, i) });
    else if (code.startsWith('=>', i)) out.push({ name, start: i, end: expressionEnd(code, i + 2) });
  };
  const catchRe = /(?<![\w$])catch\s*\(\s*([A-Za-z_]\w*)\s*(?:,\s*[A-Za-z_]\w*\s*)?\)/g;
  let m;
  while ((m = catchRe.exec(code)) !== null) add(m[1], m.index + m[0].length);
  const closureRe = /(?:(?<![\w$])catchError\s*\(\s*|(?<![\w$])onError\s*:\s*)\(\s*(?:Object\??\s+|dynamic\s+)?([A-Za-z_]\w*)[^)]*\)\s*(?:async\s*)?/g;
  while ((m = closureRe.exec(code)) !== null) add(m[1], m.index + m[0].length);
  return out;
}

/** Spans of [code] the user reads: sink-call arguments, message-like named arguments and assignments. */
function visibleSpans(code) {
  const spans = [];
  for (const call of findCalls(code, SINKS)) {
    const open = code.indexOf('(', call.offset);
    spans.push([open, open + 1 + call.args.length]);
  }
  let m;
  NAMED_ARGS.lastIndex = 0;
  while ((m = NAMED_ARGS.exec(code)) !== null) {
    const from = m.index + m[0].length;
    spans.push([from, expressionEnd(code, from)]);
  }
  ASSIGNED.lastIndex = 0;
  while ((m = ASSIGNED.exec(code)) !== null) {
    if (!MESSAGE_NAME.test(m[1])) continue;
    const from = m.index + m[0].length;
    spans.push([from, expressionEnd(code, from)]);
  }
  return spans;
}

/** String literals in [code] (blanked) with their raw text from [source]: {start, end, raw, content}. */
function stringLiterals(source, code) {
  const out = [];
  let i = 0;
  while (i < code.length) {
    const c = code[i];
    if (c !== "'" && c !== '"') { i += 1; continue; }
    const triple = code.startsWith(c.repeat(3), i);
    const quote = triple ? c.repeat(3) : c;
    const close = code.indexOf(quote, i + quote.length);
    const end = close === -1 ? code.length : close;
    out.push({ start: i, end, raw: i > 0 && code[i - 1] === 'r', content: source.slice(i + quote.length, end), contentAt: i + quote.length });
    i = end + quote.length;
  }
  return out;
}

/** Offsets of interpolations in [literal] whose expression is exactly [exprPattern] (optionally `.toString()`). */
function interpolationsOf(literal, exprPattern) {
  if (literal.raw) return [];
  const whole = new RegExp(`^(?:${exprPattern})(?:\\??\\.toString\\(\\))?$`);
  const hits = [];
  const re = /\$(?:\{([^}]*)\}|([A-Za-z_]\w*))/g;
  let m;
  while ((m = re.exec(literal.content)) !== null) {
    let slashes = 0;
    for (let k = m.index - 1; k >= 0 && literal.content[k] === '\\'; k -= 1) slashes += 1;
    if (slashes % 2 === 1) continue;
    const expr = (m[1] ?? m[2]).trim();
    if (whole.test(expr)) hits.push(literal.contentAt + m.index);
  }
  return hits;
}

/** Raw-exception text shown to the user in [source]: [{line}], escapes dropped. */
function rawErrorTexts(source) {
  const code = blankCommentsAndStrings(source);
  const spans = visibleSpans(code);
  const visible = (at) => spans.some(([from, to]) => at >= from && at < to);
  const literals = stringLiterals(source, code);
  const offsets = new Set();
  const collect = (exprPattern, from, to) => {
    for (const literal of literals) {
      if (literal.start < from || literal.start >= to) continue;
      for (const at of interpolationsOf(literal, exprPattern)) if (visible(at)) offsets.add(at);
    }
    const toString = new RegExp(`(?<![\\w$.])(?:${exprPattern})\\s*\\??\\.toString\\s*\\(\\s*\\)`, 'g');
    toString.lastIndex = from;
    let m;
    while ((m = toString.exec(code)) !== null && m.index < to) if (visible(m.index)) offsets.add(m.index);
  };
  for (const h of handlers(code)) collect(h.name, h.start, h.end);
  collect(SNAPSHOT_ERROR.replace('[A-Za-z_]\\w*', '\\w*[sS]nap\\w*'), 0, code.length);
  const lines = source.split('\n');
  return [...offsets]
    .sort((a, b) => a - b)
    .map((at) => lineAt(source, at))
    .filter((line) => !ESCAPE.test(lines[line - 1] ?? '') && !ESCAPE.test(lines[line - 2] ?? ''))
    .map((line) => ({ line }));
}

function findingsByFile() {
  const counts = {};
  const detail = {};
  for (const file of appDartFiles()) {
    const found = rawErrorTexts(fs.readFileSync(path.join(ROOT, file), 'utf8'));
    if (found.length === 0) continue;
    counts[file] = found.length;
    detail[file] = found.map((f) => f.line);
  }
  return { counts, detail };
}

test('flags caught exceptions interpolated into what the user sees', () => {
  const source = [
    'Future<void> f() async {',
    '  try {',
    '    await g();',
    '  } catch (e) {',
    "    BjSnack.error(context, 'Failed: $e');", // 5
    "    BjSnack.error(context, 'Failed: ${e.toString()}');", // 6
    '    BjSnack.error(context, e.toString());', // 7
    "    setState(() => _error = 'Could not load: ${e}');", // 8
    "    debugPrint('load failed: $e');",
    "    BjSnack.error(context, userFacingError(e, fallback: 'Could not load.'));",
    "    // error-text-ok: admin diagnostics",
    "    Text('Raw: $e');",
    "    BjSnack.error(context, 'Costs \\$e each');",
    "    BjSnack.error(context, r'$e');",
    "    throw StateError('wrapped $e');",
    '  }',
    "  BjSnack.error(context, 'outside $e');",
    '}',
    "Widget b(AsyncSnapshot s, snapshot) => Text('Error: ${snapshot.error}');", // 19
    "final x = load().catchError((err) => setState(() => _status = 'Failed $err'));", // 20
    "final y = _ErrorCard(message: 'Oops $e');",
    "void z() { try {} on FirebaseException catch (error, st) { _ErrorCard(message: 'Oops $error'); } }", // 22
  ].join('\n');
  assert.deepEqual(rawErrorTexts(source).map((f) => f.line), [5, 6, 7, 8, 19, 20, 22]);
});

test("counts an app's own snack helpers and leaves wrapped messages alone", () => {
  const source = [
    'void f() {',
    '  try {} catch (e) {',
    "    _showSnackBar('Upload failed: $e', isError: true);", // 3
    "    showAppManagerSnack(context, 'Error: $e');", // 4
    "    _showSnackBar(WarehouseCallableError.from(e).message);",
    "    BjStateView.error(title: 'Failed', error: e);",
    '  }',
    '}',
  ].join('\n');
  assert.deepEqual(rawErrorTexts(source).map((f) => f.line), [3, 4]);
});

test('no new raw exception text in what users read', () => {
  const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
  const { counts, detail } = findingsByFile();
  if (process.env.UPDATE_BASELINE === '1') {
    const lowered = {};
    for (const [file, allowed] of Object.entries(baseline)) {
      const now = Math.min(allowed, counts[file] ?? 0);
      if (now > 0) lowered[file] = now;
    }
    fs.writeFileSync(BASELINE_PATH, `${JSON.stringify(lowered, null, 2)}\n`);
    return;
  }
  const over = [];
  const under = [];
  for (const file of new Set([...Object.keys(counts), ...Object.keys(baseline)])) {
    const now = counts[file] ?? 0;
    const allowed = baseline[file] ?? 0;
    if (now > allowed) over.push(`${file}: ${now} (baseline ${allowed}) at lines ${detail[file].join(', ')}`);
    else if (now < allowed) under.push(`${file}: ${now} (baseline ${allowed})`);
  }
  assert.deepEqual(
    over,
    [],
    'Raw exception text in a user-visible message. Use userFacingError(e, fallback: ...) from '
      + 'package:shared_services/user_facing_error.dart, or mark a genuine case with '
      + '`// error-text-ok: <reason>`:\n  ' + over.join('\n  '),
  );
  assert.deepEqual(
    under,
    [],
    'Fewer raw-exception findings than the baseline allows. Lock the improvement in with\n'
      + '  UPDATE_BASELINE=1 node --test scripts/ci/user_facing_errors.test.js\n  ' + under.join('\n  '),
  );
});

module.exports = { rawErrorTexts };
