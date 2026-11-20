#!/usr/bin/env node
/**
 * Keeps bluejay's Flutter code moving onto the bluejay_design system and
 * stops it drifting back to hard-coded styling.
 *
 * Scope: `lib/**.dart` in every `packages/<pkg>` (the design system itself
 * excluded) and in the launcher's own `lib/`. It looks for:
 *
 *   raw-color      `Colors.<name>` other than white, black and transparent
 *   color-literal  `Color(0x...)`, or `Color.fromARGB`/`fromRGBO` with
 *                  literal channels
 *   font-size      a `TextStyle(...)` that sets `fontSize:` (package:pdf's `pw.TextStyle` excepted)
 *   theme-file     a file named `*_theme.dart` (an app-local token class)
 *   drag-devices   a `dragDevices:` override, the per-list fix for lists a
 *                  mouse couldn't drag; BjScrollBehavior handles every
 *                  horizontal list app-wide
 *   scroll-behavior a `MaterialApp(...)` without
 *                  `scrollBehavior: const BjScrollBehavior()`, which would
 *                  leave its horizontal lists stuck for mouse users
 *
 * Each finding points at the token or component to use instead (see
 * packages/bluejay_design/README.md). A use that is genuinely right, such as
 * a colour the user picked and the app stores, or a fixed brand or game
 * colour like a chess board, says so with `// design-ok: <reason>` on the
 * same line or the line above. A theme file takes the comment in its first
 * five lines. The reason is required, so the exception stays visible in
 * review.
 *
 * Most apps predate the design system, so the check is a ratchet:
 * scripts/check_design_tokens_baseline.json records, per file and rule, how
 * many findings existed when the baseline was taken. The check fails when a
 * file has more findings than its baseline (a file missing from it allows
 * none), so new code can't add hard-coded styling anywhere. It also fails
 * when a file has fewer, until `--update-baseline` locks the improvement
 * in. That update only ever lowers counts: it can't be used to allow new
 * findings.
 *
 * Usage:
 *   node scripts/check_design_tokens.js                    # the ratchet check (CI)
 *   node scripts/check_design_tokens.js --update-baseline  # lock in fixes (lowers counts only)
 *   node scripts/check_design_tokens.js --list <pkg>...    # every finding in these packages,
 *                                                          # ignoring the baseline (for migrations)
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DESIGN_PACKAGE = 'bluejay_design';
const ALLOWED_COLORS = new Set(['white', 'black', 'transparent']);
const ESCAPE = /\/\/\s*design-ok:\s*\S/;
const THEME_ESCAPE_LINES = 5;

/**
 * [source] with comments and string contents replaced by spaces, keeping
 * every newline and column, so matches only find code. String delimiters
 * stay, so `Text('Colors.red')` reads as `Text('          ')`. Interpolated
 * expressions are blanked with their string.
 */
function codeOnly(source) {
  const out = source.split('');
  const blank = (from, to) => {
    for (let k = from; k < to; k++) if (out[k] !== '\n') out[k] = ' ';
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
      // Dart block comments nest.
      let depth = 0;
      let j = i;
      while (j < n) {
        if (source[j] === '/' && source[j + 1] === '*') {
          depth += 1;
          j += 2;
        } else if (source[j] === '*' && source[j + 1] === '/') {
          depth -= 1;
          j += 2;
          if (depth === 0) break;
        } else {
          j += 1;
        }
      }
      blank(i, j);
      i = j;
    } else if (c === '\'' || c === '"') {
      const raw = i > 0 && source[i - 1] === 'r' && !/[A-Za-z0-9_]/.test(source[i - 2] || '');
      const triple = source.slice(i, i + 3) === c.repeat(3);
      const quote = triple ? c.repeat(3) : c;
      let j = i + quote.length;
      while (j < n) {
        if (!raw && source[j] === '\\') {
          j += 2;
          continue;
        }
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

/** Index of the `)` closing the `(` at [open] in [code], or -1. */
function closingParen(code, open) {
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '(') depth += 1;
    else if (code[i] === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

const NEUTRAL_HINT = 'BjNeutral.ink / inkMuted / inkSubtle for text, BjNeutral.border / surfaceMuted for lines and fills';

/** The token to suggest for `Colors.<name>`. */
function colorSuggestion(name) {
  const base = name.replace(/(Accent)?\d*$/, '');
  if (/^(grey|blueGrey|black|white)$/.test(base)) return NEUTRAL_HINT;
  if (/^(red|pink)$/.test(base)) return 'context.bj.tone(BjTone.danger)';
  if (/^(green|lightGreen|teal|lime)$/.test(base)) return 'context.bj.tone(BjTone.success)';
  if (/^(orange|deepOrange|amber|yellow|brown)$/.test(base)) return 'context.bj.tone(BjTone.warning)';
  if (/^(blue|lightBlue|cyan)$/.test(base)) return 'context.bj.tone(BjTone.info), or context.bj.accent for a selected/primary state';
  if (/^(indigo|purple|deepPurple)$/.test(base)) return 'context.bj.accent / accentSoft, or context.bj.tone(BjTone.accent)';
  return `${NEUTRAL_HINT}, context.bj.accent, or context.bj.tone(BjTone.x) for a status`;
}

/** The text style to suggest for a literal font size. */
function textStyleSuggestion(size) {
  const theme = 'Theme.of(context).textTheme';
  if (!Number.isFinite(size)) return `a ${theme} style, with .copyWith() for weight or colour`;
  let style;
  if (size >= 30) style = 'displaySmall';
  else if (size >= 26) style = 'headlineLarge';
  else if (size >= 23) style = 'headlineMedium';
  else if (size >= 21) style = 'headlineSmall';
  else if (size >= 18) style = 'titleLarge';
  else if (size >= 16) style = 'titleMedium';
  else if (size >= 15) style = 'bodyLarge';
  else if (size >= 14) style = 'bodyMedium (labelLarge / titleSmall for emphasis)';
  else if (size >= 12.5) style = 'bodySmall (labelMedium for labels)';
  else style = 'labelSmall';
  return `${theme}.${style}, with .copyWith() for weight or colour`;
}

/** The violations in one Dart file's [source]; [rel] is its repo path. */
function checkSource(rel, source) {
  const lines = source.split('\n');
  const code = codeOnly(source);
  const lineStarts = [0];
  for (let i = 0; i < source.length; i++) if (source[i] === '\n') lineStarts.push(i + 1);
  const lineOf = (index) => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= index) lo = mid;
      else hi = mid - 1;
    }
    return lo; // 0-based
  };
  const escaped = (line) => ESCAPE.test(lines[line] || '') || (line > 0 && ESCAPE.test(lines[line - 1]));
  const found = [];
  const add = (rule, index, snippet, suggestion) => {
    const line = lineOf(index);
    if (escaped(line)) return;
    found.push({ rule, file: rel, line: line + 1, snippet, suggestion });
  };

  if (/_theme\.dart$/.test(rel) && !lines.slice(0, THEME_ESCAPE_LINES).some((l) => ESCAPE.test(l))) {
    found.push({
      rule: 'theme-file',
      file: rel,
      line: 1,
      snippet: path.basename(rel),
      suggestion: 'read tokens from bluejay_design (BjSpace, BjRadius, BjNeutral, context.bj, textTheme) and delete this file',
    });
  }

  for (const m of code.matchAll(/(?<![\w$])Colors\.([A-Za-z]\w*)/g)) {
    if (ALLOWED_COLORS.has(m[1])) continue;
    add('raw-color', m.index, m[0], colorSuggestion(m[1]));
  }

  for (const m of code.matchAll(/(?<![\w$])Color(?:\(\s*0[xX][0-9a-fA-F]+\s*\)|\.from(?:ARGB|RGBO)\(\s*[\d.]+\s*,[^)]*\))/g)) {
    add('color-literal', m.index, m[0].replace(/\s+/g, ' '),
      'BjNeutral.*, context.bj (accent, accentSoft, tone(BjTone.x)); a stored user colour or fixed brand colour gets // design-ok: <reason>');
  }

  for (const m of code.matchAll(/(?<![\w$])TextStyle\s*\(/g)) {
    // package:pdf styles (imported as `pw`) size printed pages in points;
    // the app's theme doesn't reach them.
    if (/\bpw\.\s*$/.test(code.slice(Math.max(0, m.index - 8), m.index))) continue;
    const open = m.index + m[0].length - 1;
    const close = closingParen(code, open);
    const args = code.slice(open, close === -1 ? code.length : close + 1);
    const size = /\bfontSize\s*:\s*([^,)\n]+)/.exec(args);
    if (!size) continue;
    const snippet = source.slice(m.index, (close === -1 ? m.index + 80 : Math.min(close + 1, m.index + 80)))
      .replace(/\s+/g, ' ');
    add('font-size', m.index, snippet + (close !== -1 && close + 1 - m.index > 80 ? '...' : ''),
      textStyleSuggestion(Number(size[1].trim())));
  }

  for (const m of code.matchAll(/(?<![\w$])dragDevices\s*:/g)) {
    add('drag-devices', m.index, 'dragDevices:',
      'remove it: BjScrollBehavior (set on the app) already lets a mouse drag and wheel horizontal lists; for a vertical list that must drag with a mouse, add // design-ok: <reason>');
  }

  for (const m of code.matchAll(/(?<![\w$])MaterialApp(?:\.router)?\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    const close = closingParen(code, open);
    const args = code.slice(open, close === -1 ? code.length : close + 1);
    if (/\bscrollBehavior\s*:\s*(const\s+)?BjScrollBehavior\s*\(/.test(args)) continue;
    add('scroll-behavior', m.index, m[0].replace(/\s+/g, ''),
      'pass scrollBehavior: const BjScrollBehavior(), so its horizontal lists scroll with a mouse');
  }

  return found.sort((a, b) => a.line - b.line);
}

function dartFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...dartFiles(full));
    else if (entry.name.endsWith('.dart') && !/\.(g|freezed)\.dart$/.test(entry.name)) files.push(full);
  }
  return files.sort();
}

const BASELINE = path.join(ROOT, 'scripts', 'check_design_tokens_baseline.json');

/** Package names under [root]/packages with a lib/ directory, the design system excluded. */
function allPackages(root = ROOT) {
  const dir = path.join(root, 'packages');
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== DESIGN_PACKAGE)
    .map((entry) => entry.name)
    .filter((pkg) => fs.existsSync(path.join(dir, pkg, 'lib')))
    .sort();
}

/**
 * Findings across [packages] (default: every package) and, unless
 * [includeRoot] is false, the launcher's lib/.
 */
function checkRepo(root = ROOT, packages = allPackages(root), { includeRoot = true } = {}) {
  const dirs = packages.map((pkg) => path.join(root, 'packages', pkg, 'lib'));
  if (includeRoot) dirs.push(path.join(root, 'lib'));
  const violations = [];
  let files = 0;
  for (const dir of dirs) {
    for (const file of dartFiles(dir)) {
      files += 1;
      const rel = path.relative(root, file).split(path.sep).join('/');
      violations.push(...checkSource(rel, fs.readFileSync(file, 'utf8')));
    }
  }
  return { packages, files, violations };
}

/** `{ file: { rule: count } }` for [violations]. */
function countFindings(violations) {
  const counts = {};
  for (const v of violations) {
    counts[v.file] = counts[v.file] || {};
    counts[v.file][v.rule] = (counts[v.file][v.rule] || 0) + 1;
  }
  return counts;
}

/**
 * Compares [counts] against [baseline]. `over` lists file/rule pairs with
 * more findings than allowed; `under` lists pairs that improved (including
 * baseline entries whose file or findings are gone).
 */
function compareToBaseline(counts, baseline) {
  const over = [];
  const under = [];
  for (const [file, rules] of Object.entries(counts)) {
    for (const [rule, count] of Object.entries(rules)) {
      const allowed = (baseline[file] && baseline[file][rule]) || 0;
      if (count > allowed) over.push({ file, rule, count, allowed });
      else if (count < allowed) under.push({ file, rule, count, allowed });
    }
  }
  for (const [file, rules] of Object.entries(baseline)) {
    for (const [rule, allowed] of Object.entries(rules)) {
      if (!(counts[file] && counts[file][rule])) under.push({ file, rule, count: 0, allowed });
    }
  }
  const order = (a, b) => a.file.localeCompare(b.file) || a.rule.localeCompare(b.rule);
  return { over: over.sort(order), under: under.sort(order) };
}

/**
 * The baseline after locking in improvements: each count lowered to the
 * current one, zero entries dropped, nothing raised or added.
 */
function tightenBaseline(baseline, counts) {
  const next = {};
  for (const file of Object.keys(baseline).sort()) {
    for (const rule of Object.keys(baseline[file]).sort()) {
      const count = Math.min(baseline[file][rule], (counts[file] && counts[file][rule]) || 0);
      if (count > 0) {
        next[file] = next[file] || {};
        next[file][rule] = count;
      }
    }
  }
  return next;
}

function readBaseline(file = BASELINE) {
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
}

function writeBaseline(baseline, file = BASELINE) {
  fs.writeFileSync(file, `${JSON.stringify(baseline, null, 2)}\n`);
}

function printFindings(violations) {
  for (const v of violations) {
    console.error(`  ${v.file}:${v.line}  [${v.rule}]  ${v.snippet}`);
    console.error(`      use: ${v.suggestion}`);
  }
}

const ESCAPE_HINT =
  'Styling comes from bluejay_design tokens and components (packages/bluejay_design/README.md). ' +
  'If a use is genuinely right (a colour the user picked, a fixed brand or game colour), add ' +
  '`// design-ok: <reason>` on the same line or the line above.';

function main(argv) {
  const flags = new Set(argv.filter((a) => a.startsWith('-')));
  const names = argv.filter((a) => !a.startsWith('-'));

  if (flags.has('--list')) {
    const known = allPackages();
    for (const pkg of names) {
      if (!known.includes(pkg)) {
        console.error(`packages/${pkg} has no lib/ to check.`);
        process.exit(2);
      }
    }
    const { files, violations } = checkRepo(ROOT, names.length ? names : known, { includeRoot: !names.length });
    printFindings(violations);
    console.error(`\n${violations.length} finding(s) in ${files} file(s).`);
    process.exit(violations.length ? 1 : 0);
  }

  const { files, violations } = checkRepo();
  const counts = countFindings(violations);
  const baseline = readBaseline();

  if (flags.has('--update-baseline')) {
    const next = tightenBaseline(baseline, counts);
    writeBaseline(next);
    const total = (b) => Object.values(b).reduce((n, r) => n + Object.values(r).reduce((m, c) => m + c, 0), 0);
    console.log(`Baseline: ${total(baseline)} -> ${total(next)} allowed finding(s).`);
    const { over } = compareToBaseline(counts, next);
    if (over.length) console.error(`${over.length} file/rule pair(s) are still over the baseline; fix them, the update can't allow them.`);
    return;
  }

  const { over, under } = compareToBaseline(counts, baseline);
  if (over.length) {
    console.error(`Design token check failed: ${over.length} file/rule pair(s) gained hard-coded styling.\n`);
    for (const o of over) {
      console.error(`${o.file}  [${o.rule}]  ${o.count} found, ${o.allowed} allowed by the baseline:`);
      printFindings(violations.filter((v) => v.file === o.file && v.rule === o.rule));
    }
    console.error(`\n${ESCAPE_HINT}`);
    process.exit(1);
  }
  if (under.length) {
    console.error(`Design token check: ${under.length} file/rule pair(s) now have fewer findings than the baseline.`);
    for (const u of under.slice(0, 20)) console.error(`  ${u.file}  [${u.rule}]  ${u.allowed} -> ${u.count}`);
    if (under.length > 20) console.error(`  ... and ${under.length - 20} more`);
    console.error('\nLock the improvement in: node scripts/check_design_tokens.js --update-baseline');
    process.exit(1);
  }
  console.log(`OK: ${files} Dart file(s) checked; ${violations.length} finding(s), all within the baseline.`);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  allPackages,
  checkRepo,
  compareToBaseline,
  countFindings,
  tightenBaseline,
  checkSource,
  codeOnly,
  colorSuggestion,
  textStyleSuggestion,
};
