#!/usr/bin/env node
/**
 * Fails CI when the product name is misspelled in a tracked file.
 *
 * The name is "Bluejay": one word, one capital letter. "BlueJay",
 * "Blue Jay" and the old "BlueJ" had spread through user-facing strings,
 * emails and docs. Code identifiers are matched too, so name new classes
 * `Bluejay...` from the start.
 *
 *   node scripts/check_brand_name.js
 */

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..');
const MISSPELLING = /\bBlueJay|\bBlue Jay\b|\bBlueJ\b/g;
// This checker, its test and the copy rules table (whose name rule quotes
// them) spell out the misspellings on purpose.
const SELF = new Set(['scripts/check_brand_name.js', 'scripts/check_brand_name.test.js', 'COPY_RULES.md']);
const BINARY = /\.(png|jpe?g|gif|webp|ico|pdf|ttf|otf|woff2?|zip|gz|jar|keystore|mp3|mp4|wav)$/i;

/** Every misspelling in [text], as `{line, match}`. */
function findMisspellings(text) {
  const found = [];
  text.split('\n').forEach((line, i) => {
    for (const m of line.matchAll(MISSPELLING)) found.push({ line: i + 1, match: m[0] });
  });
  return found;
}

function trackedFiles() {
  return execFileSync('git', ['ls-files', '-z'], { cwd: REPO_ROOT, encoding: 'utf8' })
    .split('\0')
    .filter((f) => f && !BINARY.test(f) && !SELF.has(f));
}

function main() {
  const problems = [];
  for (const file of trackedFiles()) {
    let text;
    try {
      text = fs.readFileSync(path.join(REPO_ROOT, file), 'utf8');
    } catch {
      continue;
    }
    for (const { line, match } of findMisspellings(text)) problems.push(`${file}:${line}: "${match}"`);
  }
  if (problems.length) {
    console.error(`The product name is spelled "Bluejay". Fix these:\n${problems.join('\n')}`);
    process.exit(1);
  }
  console.log('Product name spelled consistently.');
}

if (require.main === module) main();

module.exports = { findMisspellings };
