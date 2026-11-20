const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { checkSource } = require('./check_back_steps');

const lines = (source) => checkSource(source.join('\n')).map((v) => v.line);

test('a back arrow that only changes state is flagged', () => {
  assert.deepEqual(lines([
    'IconButton(',
    '  icon: const Icon(Icons.arrow_back_rounded),',
    '  onPressed: () => setState(() => _selected = null),',
    ')',
  ]), [2]);
  assert.deepEqual(lines([
    'TextButton.icon(',
    '  onPressed: _showList,',
    '  icon: const Icon(Icons.arrow_back),',
    '  label: const Text("All items"),',
    ')',
  ]), [3]);
});

test('popping, forwarding and holding back all pass', () => {
  const arrow = (handler) => [
    'IconButton(',
    '  icon: const Icon(Icons.arrow_back_rounded),',
    `  onPressed: ${handler},`,
    ')',
  ];
  assert.deepEqual(lines(arrow('() => Navigator.of(context).pop()')), []);
  assert.deepEqual(lines(arrow('() => Navigator.of(context).maybePop()')), []);
  assert.deepEqual(lines(arrow('() => close(context, null)')), []);
  assert.deepEqual(lines(arrow('onBack')), []);
  assert.deepEqual(lines(arrow('widget.onClose')), []);
  assert.deepEqual(lines(arrow('busy ? null : onBack')), []);
  assert.deepEqual(lines([...arrow('_showList'), 'BjBackStep(active: a, onBack: b, child: c)']), []);
});

test('an exempt arrow passes', () => {
  assert.deepEqual(lines([
    'InvadersControlButton(',
    '  // back-step-ok: moves the ship left',
    '  icon: Icons.arrow_back_rounded,',
    '  onTap: _moveLeft,',
    ')',
  ]), []);
});

test('the repo passes', () => {
  execFileSync('node', [path.join(__dirname, 'check_back_steps.js')], { stdio: 'pipe' });
});
