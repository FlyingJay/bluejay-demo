'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');

const { blankCommentsAndStrings, parseAllMatchBlocks } = require('./rules_match_blocks');

test('parseAllMatchBlocks finds every block at any depth, with full paths and lines', () => {
  const rules = [
    'service cloud.firestore {',
    '  match /databases/{database}/documents {',
    '    // match /commented/{id} { is not a block',
    "    function f() { return {'match /x/{y} {': true}; }",
    '    match /a/{id} {',
    '      match /b/{bid} { allow read: if true; }',
    '    }',
    '    match /files/{groupId}/logo.jpg { allow read: if true; }',
    '    match /deep/{allPaths=**} { allow read: if true; }',
    '  }',
    '}',
  ].join('\n');
  assert.deepEqual(parseAllMatchBlocks(rules).map((b) => [b.fullPath, b.line]), [
    ['/databases/{database}/documents', 2],
    ['/databases/{database}/documents/a/{id}', 5],
    ['/databases/{database}/documents/a/{id}/b/{bid}', 6],
    ['/databases/{database}/documents/files/{groupId}/logo.jpg', 8],
    ['/databases/{database}/documents/deep/{allPaths=**}', 9],
  ]);
});

test('blankCommentsAndStrings keeps offsets and blanks braces in comments and strings', () => {
  const text = "a // c {\n'{'";
  assert.equal(blankCommentsAndStrings(text).length, text.length, 'offsets are kept');
  assert.ok(!blankCommentsAndStrings(text).includes('{'), 'braces in comments and strings are blanked');
});
