const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { findMisspellings } = require('./check_brand_name');

test('findMisspellings flags BlueJay, Blue Jay and BlueJ', () => {
  const text = 'Open BlueJay\nthe Blue Jay launcher\nBlueJ Launcher\nBlueJayTheme';
  assert.deepEqual(findMisspellings(text).map((f) => [f.line, f.match]), [
    [1, 'BlueJay'], [2, 'Blue Jay'], [3, 'BlueJ'], [4, 'BlueJay'],
  ]);
});

test('findMisspellings accepts Bluejay, bluejay and bluejay.gg', () => {
  assert.deepEqual(findMisspellings('Bluejay · bluejay.gg · BLUEJAY · bluejay_app.json'), []);
});

test('the repository passes the check', () => {
  execFileSync(process.execPath, [path.join(__dirname, 'check_brand_name.js')], { stdio: 'pipe' });
});
