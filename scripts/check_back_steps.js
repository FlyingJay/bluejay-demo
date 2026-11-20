#!/usr/bin/env node
/**
 * Fails CI when an in-app back arrow closes a sub-view held in widget state
 * but the browser's back button would leave the app instead.
 *
 * Every app is one route pushed from the launcher, so the browser's back
 * button (and Android back) pops the whole app unless something holds the
 * pop. A sub-view opened with Navigator.push closes on back by itself. One
 * held in state (`setState(() => _selected = null)` behind a back arrow)
 * needs BjBackStep (packages/bluejay_design/lib/src/components/back_step.dart)
 * so back closes it too.
 *
 * The check finds back-arrow icons (Icons.arrow_back*) and the
 * onPressed/onTap closest to each. It passes when that handler pops a route,
 * forwards a callback the parent supplies (`onBack`, `widget.onClose`), or
 * the file uses BjBackStep or PopScope. Anything else fails. An arrow that
 * isn't a back button (a "move left" control, say) is marked with a comment
 * on the same line or one of the three above: `back-step-ok: <reason>`.
 *
 *   node scripts/check_back_steps.js
 */

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BACK_ICON = /Icons\.arrow_back/;
const HANDLER = /\bon(?:Pressed|Tap)\s*:\s*(.*)$/;
/** Handlers that pop a route, or hand the decision to the parent widget. */
const POPS = /Navigator|maybePop|\.pop\(|\bclose\(context/;
/** `onBack`, `widget.onClose`, `a.onMoveBack`, optionally behind `busy ? null :`. */
const FORWARDS = /^(?:[^?]*\?\s*null\s*:\s*)?(?:\w+\.)?on[A-Z]\w*\s*,?\s*$/;
const HOLDS_BACK = /\bBjBackStep\s*\(|\bPopScope\s*[<(]/;
const EXEMPT = /back-step-ok:\s*\S/;
/** How far from the icon its button's handler can be. */
const WINDOW = 6;

/** Back arrows in [source] whose handler doesn't make browser back work. */
function checkSource(source) {
  if (!BACK_ICON.test(source) || HOLDS_BACK.test(source)) return [];
  const lines = source.split('\n');
  const found = [];
  lines.forEach((line, i) => {
    if (!BACK_ICON.test(line)) return;
    if (lines.slice(Math.max(0, i - 3), i + 1).some((l) => EXEMPT.test(l))) return;
    const handler = nearestHandler(lines, i);
    if (handler == null || POPS.test(handler) || FORWARDS.test(handler)) return;
    found.push({ line: i + 1, handler });
  });
  return found;
}

/** The onPressed/onTap value nearest line [i], within WINDOW lines. */
function nearestHandler(lines, i) {
  for (let d = 0; d <= WINDOW; d++) {
    for (const j of d === 0 ? [i] : [i + d, i - d]) {
      const m = j >= 0 && j < lines.length ? HANDLER.exec(lines[j]) : null;
      if (m) return m[1].trim();
    }
  }
  return null;
}

function dartFiles() {
  return execFileSync('git', ['ls-files', '-z', 'lib', 'packages'], { cwd: ROOT, encoding: 'utf8' })
    .split('\0')
    .filter((f) => f.endsWith('.dart') && !/(^|\/)(test|test_driver|integration_test)\//.test(f));
}

function main() {
  const problems = [];
  for (const file of dartFiles()) {
    const source = fs.readFileSync(path.join(ROOT, file), 'utf8');
    for (const { line, handler } of checkSource(source)) {
      problems.push(`${file}:${line}: back arrow runs \`${handler}\``);
    }
  }
  if (problems.length) {
    console.error(
      'These back arrows close an in-app view without a route pop, so the browser\'s back button ' +
        'skips them and leaves the app. Wrap the view in BjBackStep(active:, onBack:), open it with ' +
        'Navigator.push, or mark an arrow that isn\'t a back button with `// back-step-ok: <reason>`:\n' +
        problems.join('\n'),
    );
    process.exit(1);
  }
  console.log('In-app back arrows all work with browser back.');
}

if (require.main === module) main();

module.exports = { checkSource };
