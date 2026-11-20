#!/usr/bin/env node
/**
 * Checks text against the copy rules in COPY_RULES.md: wording and claim
 * decisions the owner made through the advisors, each written as a regex
 * with the files it applies to. The rules table is the single source; this
 * script only parses and applies it.
 *
 *   node scripts/ci/copy_lint.js --base <git-ref>
 *       Lints only the lines added in `git diff <ref>...HEAD`, so text that
 *       was already there never fails. This is the "Copy rules" PR check
 *       (tests.yml).
 *   node scripts/ci/copy_lint.js --base <git-ref> --worktree
 *       Also counts uncommitted edits and untracked files: lints the lines
 *       added between the merge base and the working tree. This is how
 *       scripts/ci/local_check.sh runs it before a PR exists.
 *   node scripts/ci/copy_lint.js --all [--root <dir>] [--rules <path>]
 *       Lints every git-tracked file under <dir> (default: this repo). With
 *       --root and --rules, advisors audit the business repo against this
 *       repo's rules.
 *
 * Prints `file:line: message (rule pattern)` per hit and exits 1 if there
 * are any. Binary files, files over 1 MB and the rules file itself are
 * skipped. A line containing `copy-lint: allow` is skipped.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DEFAULT_RULES = path.join(ROOT, 'COPY_RULES.md');
const MAX_BYTES = 1024 * 1024;
const ALLOW_MARKER = 'copy-lint: allow';
const BINARY = /\.(png|jpe?g|gif|webp|ico|icns|pdf|ttf|otf|woff2?|eot|zip|gz|tgz|jar|keystore|jks|p12|mp3|mp4|mov|wav|ogg|riv|lottie|bin|so|dylib|a|exe)$/i;
const COLUMNS = ['pattern', 'files', 'except', 'message', 'decision'];

function git(cwd, args) {
  return execFileSync('git', ['-c', 'core.quotePath=false', ...args], {
    cwd, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024,
  });
}

/** A table row's cells, split on unescaped `|`, with `\|` unescaped. */
function splitRow(line) {
  const body = line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '');
  return body.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
}

/** The text inside the outermost backticks of a cell, or the cell itself. */
function unquote(cell) {
  const s = cell.trim();
  const a = s.indexOf('`');
  const b = s.lastIndexOf('`');
  return a !== -1 && b > a ? s.slice(a + 1, b) : s;
}

/** Comma-separated backticked globs (`a`, `b`) as an array; empty cell → []. */
function globList(cell) {
  return cell.split(',').map((g) => unquote(g).trim()).filter(Boolean);
}

/** A pattern cell as a RegExp; a leading `(?i)` becomes the i flag. */
function compilePattern(source) {
  let src = source;
  let flags = '';
  if (src.startsWith('(?i)')) {
    src = src.slice(4);
    flags = 'i';
  }
  return new RegExp(src, flags);
}

/**
 * The rules in [markdown]: the first table whose header is Pattern | Files |
 * Except | Message | Decision. Throws on a bad regex or a row without
 * files, naming the line.
 */
function parseRules(markdown) {
  const lines = markdown.split('\n');
  const rules = [];
  let inTable = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!inTable) {
      if (!line.trim().startsWith('|')) continue;
      const header = splitRow(line).map((c) => c.toLowerCase());
      if (COLUMNS.every((c, j) => header[j] === c)) {
        inTable = true;
        i++; // the |---| separator row
      }
      continue;
    }
    if (!line.trim().startsWith('|')) break;
    const cells = splitRow(line);
    const at = `COPY_RULES line ${i + 1}`;
    if (cells.length < COLUMNS.length) throw new Error(`${at}: expected ${COLUMNS.length} columns, got ${cells.length}`);
    const [patternCell, filesCell, exceptCell, message, decision] = cells;
    const pattern = unquote(patternCell);
    let regex;
    try {
      regex = compilePattern(pattern);
    } catch (e) {
      throw new Error(`${at}: bad pattern ${pattern}: ${e.message}`);
    }
    const files = globList(filesCell);
    if (!files.length) throw new Error(`${at}: no Files globs`);
    rules.push({
      pattern, regex, files, except: globList(exceptCell), message, decision, line: i + 1,
      fileRes: files.map(globToRegExp), exceptRes: globList(exceptCell).map(globToRegExp),
    });
  }
  if (!inTable) throw new Error('no rules table (Pattern | Files | Except | Message | Decision) found');
  return rules;
}

/**
 * A glob matched against a whole repo-relative path: `**` spans
 * directories (followed by a slash it also matches no directory at all),
 * while `*` and `?` stay within one path segment.
 */
function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') {
        re += '(?:.*/)?';
        i += 2;
      } else {
        re += '.*';
        i += 1;
      }
    } else if (c === '*') {
      re += '[^/]*';
    } else if (c === '?') {
      re += '[^/]';
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${re}$`);
}

function ruleApplies(rule, file) {
  return rule.fileRes.some((r) => r.test(file)) && !rule.exceptRes.some((r) => r.test(file));
}

/** Hits for one line of [file], as `{file, line, rule, match}`. */
function lintLine(rules, file, lineNo, text) {
  if (text.includes(ALLOW_MARKER)) return [];
  const hits = [];
  for (const rule of rules) {
    if (!ruleApplies(rule, file)) continue;
    const m = text.match(rule.regex);
    if (m) hits.push({ file, line: lineNo, rule, match: m[0] });
  }
  return hits;
}

/**
 * Added lines in a unified diff, as Map<file, [{line, text}]>. Deleted
 * files and removed lines are ignored; line numbers are in the new file.
 */
function parseAddedLines(diff) {
  const added = new Map();
  let file = null;
  let next = 0;
  let inHunk = false;
  for (const raw of diff.split('\n')) {
    if (raw.startsWith('diff --git ')) {
      file = null;
      inHunk = false;
      continue;
    }
    if (!inHunk) {
      if (raw.startsWith('+++ ')) {
        const target = raw.slice(4);
        file = target === '/dev/null' ? null : target.replace(/^b\//, '');
      }
      if (!raw.startsWith('@@ ')) continue;
      inHunk = true;
    }
    const hunk = raw.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      next = Number(hunk[1]);
      continue;
    }
    if (!file) continue;
    if (raw.startsWith('+')) {
      if (!added.has(file)) added.set(file, []);
      added.get(file).push({ line: next, text: raw.slice(1) });
      next++;
    } else if (raw.startsWith(' ')) {
      next++;
    }
    // '-' lines and "\ No newline at end of file" don't advance the new file.
  }
  return added;
}

/** Whether [abs] should be skipped: missing, too big, binary or the rules file. */
function skipFile(abs, rulesPath) {
  if (path.resolve(abs) === path.resolve(rulesPath) || path.basename(abs) === 'COPY_RULES.md') return true;
  if (BINARY.test(abs)) return true;
  let stat;
  try {
    stat = fs.statSync(abs);
  } catch {
    return true;
  }
  if (!stat.isFile() || stat.size > MAX_BYTES) return true;
  const fd = fs.openSync(abs, 'r');
  const head = Buffer.alloc(Math.min(stat.size, 8000));
  fs.readSync(fd, head, 0, head.length, 0);
  fs.closeSync(fd);
  return head.includes(0);
}

function lintAll(root, rules, rulesPath) {
  const files = git(root, ['ls-files', '-z']).split('\0').filter(Boolean);
  const hits = [];
  for (const file of files) {
    if (!rules.some((r) => ruleApplies(r, file))) continue;
    const abs = path.join(root, file);
    if (skipFile(abs, rulesPath)) continue;
    fs.readFileSync(abs, 'utf8').split('\n').forEach((text, i) => {
      hits.push(...lintLine(rules, file, i + 1, text));
    });
  }
  return { hits, files: files.length };
}

/**
 * Lines added since [base]: in its commits (`base...HEAD`), or with
 * [worktree] in the working tree too, untracked files counting as all-new.
 */
function addedSince(root, base, worktree) {
  const flags = ['diff', '--no-renames', '--no-color', '--no-ext-diff', '-U0'];
  if (!worktree) return parseAddedLines(git(root, [...flags, `${base}...HEAD`]));
  const mergeBase = git(root, ['merge-base', base, 'HEAD']).trim();
  const added = parseAddedLines(git(root, [...flags, mergeBase]));
  const untracked = git(root, ['ls-files', '-z', '--others', '--exclude-standard']).split('\0').filter(Boolean);
  for (const file of untracked) {
    const abs = path.join(root, file);
    if (BINARY.test(file) || !fs.statSync(abs).isFile()) continue;
    added.set(file, fs.readFileSync(abs, 'utf8').split('\n').map((text, i) => ({ line: i + 1, text })));
  }
  return added;
}

function lintDiff(root, base, rules, rulesPath, worktree = false) {
  const added = addedSince(root, base, worktree);
  const hits = [];
  for (const [file, lines] of added) {
    if (!rules.some((r) => ruleApplies(r, file))) continue;
    if (skipFile(path.join(root, file), rulesPath)) continue;
    for (const { line, text } of lines) hits.push(...lintLine(rules, file, line, text));
  }
  return { hits, files: added.size };
}

function formatHit(hit) {
  return `${hit.file}:${hit.line}: ${hit.rule.message} (rule \`${hit.rule.pattern}\`)`;
}

function parseArgs(argv) {
  const opts = { root: ROOT, rules: DEFAULT_RULES };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') opts.all = true;
    else if (a === '--base') opts.base = argv[++i];
    else if (a === '--worktree') opts.worktree = true;
    else if (a === '--root') opts.root = path.resolve(argv[++i]);
    else if (a === '--rules') opts.rules = path.resolve(argv[++i]);
    else throw new Error(`unknown argument ${a}`);
  }
  if (!opts.all === !opts.base) throw new Error('pass exactly one of --all or --base <git-ref>');
  if (opts.worktree && !opts.base) throw new Error('--worktree goes with --base');
  return opts;
}

function main(argv) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (e) {
    console.error(`${e.message}\nusage: copy_lint.js --base <git-ref> [--worktree] | --all [--root <dir>] [--rules <path>]`);
    process.exit(2);
  }
  const rules = parseRules(fs.readFileSync(opts.rules, 'utf8'));
  const { hits, files } = opts.all
    ? lintAll(opts.root, rules, opts.rules)
    : lintDiff(opts.root, opts.base, rules, opts.rules, opts.worktree);
  for (const hit of hits) {
    console.log(formatHit(hit));
    if (process.env.GITHUB_ACTIONS === 'true') {
      console.log(`::error file=${hit.file},line=${hit.line}::${hit.rule.message.replace(/\n/g, ' ')}`);
    }
  }
  const scope = opts.all ? `${files} tracked files` : `lines added in ${files} files`;
  if (hits.length) {
    console.error(`\n${hits.length} copy rule hit(s) in ${scope}. Rewrite them as each message says, or end a ` +
      `line that must quote the wording with \`${ALLOW_MARKER}\`. Rules: COPY_RULES.md.`);
    process.exit(1);
  }
  console.error(`Copy rules: no hits in ${scope} (${rules.length} rules).`);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = { lintDiff, parseRules, globToRegExp, parseAddedLines, lintLine, ruleApplies, skipFile, ALLOW_MARKER };
