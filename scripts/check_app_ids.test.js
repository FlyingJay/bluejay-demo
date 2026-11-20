const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { KNOWN_UNREGISTERED, functionAppIds, routerAppIds } = require('./check_app_ids');

test('routerAppIds reads the _routes keys and the special cases', () => {
  const source = `
  static final Map<String, Widget Function(fire_auth.User?)> _routes = {
    'notes': (user) => NotesScreen(currentUser: user),
    'ai-chat': (user) => AiChatScreen(currentUser: user!),
  };
  static Widget? _resolveScreen(String appId) {
    if (appId == 'wiki') return null;
  }`;
  assert.deepEqual(routerAppIds(source), ['notes', 'ai-chat', 'wiki']);
});

test('functionAppIds reads top-level *_APP_ID constants and skips ~sentinels', () => {
  const sources = {
    'budgie_ting.js': "const BUDGIE_TING_APP_ID = 'budgieting';\nconst OTHER = 'x';",
    '_usage.js': "const PLATFORM_APP_ID = '~platform';\n  const INNER_APP_ID = 'nested';",
  };
  assert.deepEqual(functionAppIds(sources), [
    { file: 'budgie_ting.js', name: 'BUDGIE_TING_APP_ID', appId: 'budgieting' },
  ]);
});

test('every KNOWN_UNREGISTERED entry gives a reason', () => {
  for (const [appId, reason] of Object.entries(KNOWN_UNREGISTERED)) {
    assert.ok(typeof reason === 'string' && reason.length > 10, appId);
  }
});

test('the repository passes the check', () => {
  execFileSync(process.execPath, [path.join(__dirname, 'check_app_ids.js')], { stdio: 'pipe' });
});
