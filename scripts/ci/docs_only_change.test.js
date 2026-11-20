'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { docsOnly } = require('./docs_only_change');

const PUBSPEC_NEW_DOCS_DIR = [
  'diff --git a/pubspec.yaml b/pubspec.yaml',
  'index 1111111..2222222 100644',
  '--- a/pubspec.yaml',
  '+++ b/pubspec.yaml',
  '@@ -380,6 +380,7 @@ flutter:',
  '     - documentation/language_learner/',
  '+    - documentation/usage_meter/',
  '     - documentation/notes/',
].join('\n');

test('documentation/ files only are docs-only', () => {
  assert.equal(docsOnly([{ filename: 'documentation/notes/user.md' }]).docsOnly, true);
});

test('a git-diff pubspec.yaml patch that only adds a docs asset dir is docs-only', () => {
  assert.equal(docsOnly([
    { filename: 'documentation/usage_meter/user.md' },
    { filename: 'pubspec.yaml', patch: PUBSPEC_NEW_DOCS_DIR },
  ]).docsOnly, true);
});

test('any code file, or an empty change, is not docs-only', () => {
  assert.equal(docsOnly([{ filename: 'documentation/a.md' }, { filename: 'lib/main.dart' }]).docsOnly, false);
  assert.equal(docsOnly([{ filename: 'README.md' }]).docsOnly, false);
  assert.equal(docsOnly([]).docsOnly, false);
});

test('a rename out of code into documentation/ is not docs-only', () => {
  assert.equal(docsOnly([{ filename: 'documentation/x.dart', previous_filename: 'lib/x.dart' }]).docsOnly, false);
  assert.equal(docsOnly([{ filename: 'documentation/b.md', previous_filename: 'documentation/a.md' }]).docsOnly, true);
});
