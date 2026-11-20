'use strict';

/**
 * Fails when a FloatingActionButton (plain, .small or .large) has no
 * tooltip. These are icon-only, so without one a screen reader can't name
 * the button and a store screenshot scene has nothing to tap.
 *
 * FloatingActionButton.extended is named by its visible `label:`, so it
 * passes with a label or a tooltip. Requiring a tooltip there too would
 * repeat the button's text in a hover popup and in what a screen reader
 * says.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ROOT, appDartFiles, blankCommentsAndStrings, lineAt, findCalls, hasNamedArgument } = require('./dart_source');

/** FloatingActionButton calls in [source] with no tooltip: {line, name}. */
function untooltippedFabs(source) {
  const code = blankCommentsAndStrings(source);
  return findCalls(code, 'FloatingActionButton(?:\\.(?:extended|small|large))?')
    .filter((call) => !hasNamedArgument(call.args, 'tooltip'))
    .filter((call) => !(call.name === 'FloatingActionButton.extended' && hasNamedArgument(call.args, 'label')))
    .map((call) => ({ line: lineAt(code, call.offset), name: call.name }));
}

test('flags only the buttons with no top-level tooltip', () => {
  const source = [
    'final a = FloatingActionButton(onPressed: f, child: Icon(Icons.add));',
    "final b = FloatingActionButton(onPressed: f, tooltip: 'New', child: Icon(Icons.add));",
    "final c = FloatingActionButton.extended(onPressed: f, icon: Icon(Icons.add));",
    "final c2 = FloatingActionButton.extended(onPressed: f, label: Text('Go'), icon: Icon(Icons.add));",
    "final d = FloatingActionButton.small(\n  onPressed: () => g(x(1)),\n  tooltip: t(lang, 'add'),\n  child: Icon(Icons.add),\n);",
    "final e = FloatingActionButton.large(onPressed: f, child: Tooltip(message: 'x', child: Icon(Icons.add)));",
    "// FloatingActionButton(onPressed: f)",
    "final f = MyFloatingActionButton(onPressed: f);",
    "final g = FloatingActionButtonLocation.endFloat;",
  ].join('\n');
  assert.deepEqual(untooltippedFabs(source), [
    { line: 1, name: 'FloatingActionButton' },
    { line: 3, name: 'FloatingActionButton.extended' },
    { line: 10, name: 'FloatingActionButton.large' },
  ]);
});

test('every FloatingActionButton has a tooltip', () => {
  const problems = [];
  for (const file of appDartFiles()) {
    for (const fab of untooltippedFabs(fs.readFileSync(path.join(ROOT, file), 'utf8'))) {
      problems.push(`${file}:${fab.line}: ${fab.name}`);
    }
  }
  assert.deepEqual(
    problems,
    [],
    `Give each FloatingActionButton a tooltip: (an extended one a label:) so screen readers can name it:\n  ${problems.join('\n  ')}`,
  );
});
