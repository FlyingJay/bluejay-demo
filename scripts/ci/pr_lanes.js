#!/usr/bin/env node
/**
 * Which merge lane a pull request is in, from one table of path rules. The
 * auto-merge (docs_pr_automerge.js) merges the first four lanes on its own;
 * the last is for the owner.
 *
 *   docs    Every file is under documentation/ (plus documentation asset
 *           lines in pubspec.yaml). Any author. Merges at once.
 *   pages   Every file is a public page's content: under web/about/, or the
 *           signed-out landing page in web/index.html (PAGE_FILES). Any
 *           author. Markup may change freely except for anything that runs
 *           code on the bluejay.gg origin (scriptSurface), which must stay
 *           exactly as it was. Merges once checks pass.
 *   prose   An advisor branch (claude/advisor-*) whose files are all
 *           markdown, none of them guarded. Merges once checks pass.
 *   copy    An advisor branch whose files are markdown or COPY_FILES, where
 *           every code file's change is copy-only (copy_only_diff.js), none
 *           guarded. Merges once checks pass.
 *   review  Everything else. The owner reviews and merges it.
 *
 * GUARDED files always need the owner, whatever changed in them: the files
 * that steer every agent (CLAUDE.md, the advisor PROTOCOL.md), the security
 * model, and CI itself (which holds these rules).
 *
 * The advisor round protocol (advisors/PROTOCOL.md in the business
 * repository) splits a round's work so prose and copy changes go in their
 * own PR and code changes in another.
 */

'use strict';

const { isDocsAssetOnlyPubspecChange } = require('../../functions/_docs_assets');
const { copyOnlyChange } = require('./copy_only_diff');

const ADVISOR_BRANCH = /^claude\/advisor-/;

const GUARDED = [
  '**/CLAUDE.md',
  '**/PROTOCOL.md',
  'SECURITY_TIERS.md',
  'FIRESTORE_PERMISSIONS.md',
  'security/**',
  '.github/**',
  'scripts/ci/**',
  '.claude/**/*.json',
  'firestore.rules',
  'storage.rules',
];

const PROSE_FILES = ['**/*.md'];

/** Files whose copy may change in the copy lane (user-facing app code, the public pages, app manifests). */
const COPY_FILES = [
  'lib/**/*.dart',
  'test/**/*.dart',
  'packages/*/lib/**/*.dart',
  'packages/*/test/**/*.dart',
  'web/**/*.html',
  'packages/*/bluejay_app.json',
];

const DOCS_PREFIX = 'documentation/';

/**
 * The public pages (README, "Public pages"): static content with no review
 * needed, as long as no code that runs on the bluejay.gg origin changes.
 * Markup files are checked by scriptSurface; asset files can't run code.
 * JavaScript files aren't listed, so a change to one needs review. The legal
 * pages (web/privacy, web/terms) aren't listed either: their wording is
 * reviewed. aligned-with.txt is the business-messaging skill's record of the
 * plan commit a sweep checked, updated in the same PR.
 */
const PAGE_MARKUP_FILES = ['web/about/**/*.html', 'web/about/**/*.svg', 'web/index.html'];
const PAGE_ASSET_FILES = [
  'web/about/**/*.css',
  'web/about/**/*.{png,jpg,jpeg,webp,gif,ico,woff,woff2,txt,json}',
  '.claude/skills/business-messaging/aligned-with.txt',
];
const PAGE_FILES = [...PAGE_MARKUP_FILES, ...PAGE_ASSET_FILES];
/** The one script a new page may include: the shared audience-tab script. */
const PAGE_SCRIPT_INCLUDES = ['<script src="/about/assets/about.js"></script>'];

/** GitHub `paths`-style glob: `**` crosses segments, `*` and `?` stay within one. */
function globToRegExp(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i += 1) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      i += 1;
      if (glob[i + 1] === '/') {
        i += 1;
        re += '(?:.*/)?';
      } else {
        re += '.*';
      }
    } else if (c === '{') {
      const end = glob.indexOf('}', i);
      re += `(?:${glob.slice(i + 1, end).split(',').map((a) => a.replace(/[.+^$()|[\]\\]/g, '\\$&')).join('|')})`;
      i = end;
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

const compile = (globs) => globs.map(globToRegExp);
const GUARDED_RE = compile(GUARDED);
const PROSE_RE = compile(PROSE_FILES);
const COPY_RE = compile(COPY_FILES);
const PAGE_MARKUP_RE = compile(PAGE_MARKUP_FILES);
const PAGE_RE = compile(PAGE_FILES);
const matches = (res, file) => res.some((re) => re.test(file));

/** Every path a changed file touches (both sides of a rename). */
function pathsOf(f) {
  return f.previous_filename && f.previous_filename !== f.filename ? [f.previous_filename, f.filename] : [f.filename];
}

/**
 * { eligible, touchesPubspec, reason } for the documentation-only rule
 * (GitHub `pulls.listFiles` shape: filename, previous_filename, patch).
 * Also what tests.yml uses to skip its suites on a docs-only PR
 * (scripts/ci/docs_only_change.js), so the two never disagree.
 */
function classifyFiles(files) {
  if (!files.length) return { eligible: false, touchesPubspec: false, reason: 'no changed files' };
  let touchesPubspec = false;
  for (const f of files) {
    // A rename's old path changed too: moving lib/x.dart into documentation/
    // deletes code, so it isn't a documentation-only change.
    if (f.previous_filename && !f.previous_filename.startsWith(DOCS_PREFIX)) {
      return { eligible: false, touchesPubspec, reason: `non-documentation change: ${f.previous_filename}` };
    }
    if (f.filename.startsWith(DOCS_PREFIX)) continue;
    if (isDocsAssetOnlyPubspecChange(f)) {
      touchesPubspec = true;
      continue;
    }
    return { eligible: false, touchesPubspec, reason: `non-documentation change: ${f.filename}` };
  }
  return { eligible: true, touchesPubspec, reason: 'documentation-only' };
}

/**
 * Everything in an HTML or SVG file that can run code or change where the
 * page's code comes from: script elements, inline event handlers,
 * javascript:/vbscript:/data:text/html URLs, frames and embeds, <base>,
 * <meta http-equiv> (refresh, CSP), and SVG animation that can rewrite a
 * link. Whitespace inside each item is normalized and the list sorted, so
 * reindenting or moving a section doesn't count as a change. An unclosed
 * <script> returns a marker that never matches.
 */
function scriptSurface(text) {
  const out = [];
  const add = (re) => { for (const m of text.matchAll(re)) out.push(m[0].replace(/\s+/g, ' ').trim()); };
  const blocks = text.match(/<script\b[\s\S]*?<\/script\s*>/gi) || [];
  const opens = text.match(/<script\b/gi) || [];
  if (opens.length !== blocks.length) return ['<unclosed script>'];
  out.push(...blocks.map((b) => b.replace(/\s+/g, ' ').trim()));
  add(/<(?:iframe|frame|frameset|object|embed|base|portal|foreignObject|set|animate|animateMotion|animateTransform|handler|listener)\b[^>]*>/gi);
  add(/<meta\b[^>]*http-equiv[^>]*>/gi);
  add(/\son[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi);
  add(/(?:javascript|vbscript|livescript)\s*:|data\s*:\s*text\/html/gi);
  return out.sort();
}

/**
 * { pages, pageFiles, reason } for the public pages lane: every changed path is a
 * page file, and every markup file's script surface is unchanged (a new
 * file may only include PAGE_SCRIPT_INCLUDES).
 */
async function classifyPages(files, readFile) {
  for (const f of files) {
    for (const p of pathsOf(f)) {
      if (!matches(PAGE_RE, p)) return { pages: false, pageFiles: false, reason: `not a public page file: ${p}` };
    }
  }
  for (const f of files) {
    if (f.status === 'removed' || !matches(PAGE_MARKUP_RE, f.filename)) continue;
    // eslint-disable-next-line no-await-in-loop
    const after = await readFile(f.filename, 'head');
    if (typeof after !== 'string') return { pages: false, pageFiles: true, reason: `${f.filename}: could not read it` };
    const now = scriptSurface(after);
    if (f.status === 'added' || (f.status === 'renamed' && !matches(PAGE_MARKUP_RE, f.previous_filename))) {
      const extra = now.filter((s) => !PAGE_SCRIPT_INCLUDES.includes(s));
      if (extra.length) return { pages: false, pageFiles: true, reason: `${f.filename}: new page runs code (${extra[0].slice(0, 80)})` };
      continue;
    }
    // eslint-disable-next-line no-await-in-loop
    const before = await readFile(f.previous_filename || f.filename, 'base');
    if (typeof before !== 'string') return { pages: false, pageFiles: true, reason: `${f.filename}: could not read the base version` };
    if (JSON.stringify(scriptSurface(before)) !== JSON.stringify(now)) {
      return { pages: false, pageFiles: true, reason: `${f.filename}: scripts, event handlers or embeds changed` };
    }
  }
  return { pages: true, pageFiles: true, reason: 'public page content only' };
}

/**
 * The lane for a PR: { lane, requireChecks, reason }.
 *   files     `pulls.listFiles` entries (filename, previous_filename, status, patch)
 *   branch    the PR's head branch
 *   readFile  async (path, side: 'base'|'head') => contents, for copy checks
 */
async function classifyPr({ files, branch, readFile }) {
  const docs = classifyFiles(files);
  if (docs.eligible) return { lane: 'docs', requireChecks: docs.touchesPubspec, reason: docs.reason };
  const pages = await classifyPages(files, readFile);
  if (pages.pages) return { lane: 'pages', requireChecks: true, reason: pages.reason };
  if (!ADVISOR_BRANCH.test(branch || '')) return { lane: 'review', requireChecks: false, reason: pages.pageFiles ? pages.reason : docs.reason };

  const toCheck = [];
  for (const f of files) {
    for (const p of pathsOf(f)) {
      if (matches(GUARDED_RE, p)) return { lane: 'review', requireChecks: false, reason: `guarded file: ${p}` };
    }
    if (f.filename.startsWith(DOCS_PREFIX) && !f.previous_filename) continue;
    if (isDocsAssetOnlyPubspecChange(f)) continue;
    if (pathsOf(f).every((p) => matches(PROSE_RE, p))) continue;
    if (matches(COPY_RE, f.filename) && f.status === 'modified') {
      toCheck.push(f.filename);
      continue;
    }
    const why = matches(COPY_RE, f.filename) ? `${f.status} code file` : 'code change';
    return { lane: 'review', requireChecks: false, reason: `${why}: ${f.filename}` };
  }
  if (!toCheck.length) return { lane: 'prose', requireChecks: true, reason: 'advisor prose change' };

  for (const p of toCheck) {
    // eslint-disable-next-line no-await-in-loop
    const [before, after] = await Promise.all([readFile(p, 'base'), readFile(p, 'head')]);
    if (typeof before !== 'string' || typeof after !== 'string') {
      return { lane: 'review', requireChecks: false, reason: `${p}: could not read both versions` };
    }
    const c = copyOnlyChange(p, before, after);
    if (!c.copyOnly) return { lane: 'review', requireChecks: false, reason: c.reason };
  }
  return { lane: 'copy', requireChecks: true, reason: `advisor copy-only change (${toCheck.length} code file${toCheck.length === 1 ? '' : 's'})` };
}

module.exports = {
  ADVISOR_BRANCH, GUARDED, PROSE_FILES, COPY_FILES, PAGE_FILES, globToRegExp, classifyFiles, classifyPages, classifyPr, scriptSurface,
};
