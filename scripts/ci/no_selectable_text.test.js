'use strict';

/**
 * Fails when app Dart code uses SelectableText. On the web a SelectableText
 * never reaches the semantics tree, so screen readers (and the store
 * screenshot runner) can't read it. shared_ui's ReadableSelectableText is
 * the drop-in replacement; see packages/shared_ui/lib/readable_selectable_text.dart.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ROOT, appDartFiles, blankCommentsAndStrings, lineAt, findCalls } = require('./dart_source');

const ALLOWED = new Set(['packages/shared_ui/lib/readable_selectable_text.dart']);

/** SelectableText uses in [source]: {line, name}. */
function selectableTextUses(source) {
  const code = blankCommentsAndStrings(source);
  return findCalls(code, 'SelectableText(?:\\.rich)?').map((call) => ({ line: lineAt(code, call.offset), name: call.name }));
}

test('finds SelectableText and SelectableText.rich, but not comments, strings or other names', () => {
  const source = [
    "// SelectableText('a comment')",
    "final a = SelectableText('x');",
    'final b = const SelectableText.rich(TextSpan());',
    "final c = Text('SelectableText(no)');",
    "final d = ReadableSelectableText('fine');",
    '/* SelectableText( */',
  ].join('\n');
  assert.deepEqual(selectableTextUses(source), [
    { line: 2, name: 'SelectableText' },
    { line: 3, name: 'SelectableText.rich' },
  ]);
});

test('app code uses ReadableSelectableText, never SelectableText', () => {
  const problems = [];
  for (const file of appDartFiles()) {
    if (ALLOWED.has(file)) continue;
    for (const use of selectableTextUses(fs.readFileSync(path.join(ROOT, file), 'utf8'))) {
      problems.push(`${file}:${use.line}: ${use.name}`);
    }
  }
  assert.deepEqual(
    problems,
    [],
    `SelectableText never reaches the semantics tree on the web, so screen readers can't read it.\n`
      + `Use ReadableSelectableText (package:shared_ui/readable_selectable_text.dart) instead:\n  ${problems.join('\n  ')}`,
  );
});
