#!/usr/bin/env node
/**
 * Fails CI when an app could ship without being registered as `apps/{appId}`.
 *
 * An app is reachable only when `apps/{appId}` exists and some group has the
 * id in `installedApps`; its documents are only reachable by group members
 * when the id matches the scoped entitlement (`{groupId}:{appId}`) the rules
 * check. So every app id the code uses must be registered:
 *
 *   - each package's `APP_ID` constant (`packages/<pkg>/lib/constants.dart`),
 *   - each route key in lib/routing/app_router.dart (the launcher opens an
 *     app by its `apps/{appId}` id through this table),
 *   - each `const <NAME>_APP_ID = '<id>'` in functions/*.js (a server
 *     function that stamps or filters on an unregistered id silently matches
 *     nothing the client wrote: budgieTingGenerateRecurringInvoices looked for
 *     'budgie_ting' while invoices carry 'budgieting'). Ids starting with `~`
 *     are usage-ledger sentinels and are skipped.
 *
 * An id counts as registered when it is in the committed snapshot of
 * production's `apps` collection (registered_app_ids.json) or declared by a
 * `packages/<pkg>/bluejay_app.json` manifest, which the app manifest sync
 * registers when the code goes live (.github/workflows/register-apps.yml;
 * scripts/firestore_admin/README.md). The few ids that are deliberately not
 * registered are listed in KNOWN_UNREGISTERED with the reason.
 *
 * Also fails on an invalid manifest (bad field, appId that differs from the
 * package's APP_ID, two manifests claiming one id).
 *
 * Static on purpose: CI needs no production credentials. Refresh the
 * snapshot with `node scripts/firestore_admin/refresh_registered_app_ids.js`
 * after an app is registered or renamed outside a manifest (App Manager).
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { loadRegisteredAppIds } = require('./registered_app_ids');
const { PACKAGES_DIR, packageAppId } = require('./firestore_admin/lib/app_manifests');

const REPO_ROOT = path.resolve(__dirname, '..');
const ROUTER_FILE = path.join(REPO_ROOT, 'lib', 'routing', 'app_router.dart');
const FUNCTIONS_DIR = path.join(REPO_ROOT, 'functions');

/**
 * App ids the code uses that are deliberately not registered, keyed by app
 * id. Remove an entry once the app is registered (or add a manifest), or
 * once the id is gone from the code.
 */
const KNOWN_UNREGISTERED = Object.freeze({
  // Package APP_IDs
  insurance_admin: 'apps/{docId} never created; runs on ownership/platform-role checks only',
  shop_chat: 'apps/{docId} never created; runs on ownership/platform-role checks only',
  payments: 'apps/{docId} never created; runs on ownership/platform-role checks only',
  thesisly: 'App Maker build whose apps/{docId} was never created; add a bluejay_app.json manifest to register it',
  'dev-queue': 'the launcher\'s queue chip, not an app; the id addresses queue notifications',
  // Router aliases and routes with no launcher entry of their own
  'app-users': 'legacy route alias of users',
  'invite-users': 'legacy route alias of users',
  'app-scripts': 'legacy route alias of scripts',
  app_access: 'legacy underscore route alias of app-access',
  'poker-quiz': 'legacy route alias of poker-preflop',
  wallet: 'route into the Billing dashboard; billing is the registered app',
  me: 'the signed-in user\'s profile, opened from the account menu',
  // Cloud Function APP_ID constants
  continuing_education: 'legacy id on CE reminder notifications; shared_services app_doc_mapping maps it to continuing-education',
  rented_dwelling: 'legacy id on rented_dwelling_config docs; rented_dwelling.js accepts both it and rented-dwelling',
  naic_sight: 'storage path segment for NAIC Sight job files (naic_sight/{uid}/{jobId}/), not a Firestore appId filter',
  insurance_coc: 'legacy id still accepted on old certificate-of-coverage docs',
});

/** `[{file, name, appId}]` for each `const <NAME>_APP_ID = '<id>'` in [sources] (`{file: source}`). */
function functionAppIds(sources) {
  const found = [];
  for (const [file, source] of Object.entries(sources)) {
    for (const m of source.matchAll(/^const\s+([A-Z0-9_]*APP_ID)\s*=\s*'([^']+)'/gm)) {
      if (!m[2].startsWith('~')) found.push({ file, name: m[1], appId: m[2] });
    }
  }
  return found;
}

/** Route keys of AppRouter._routes plus the special cases in _resolveScreen. */
function routerAppIds(source) {
  const start = source.indexOf('_routes = {');
  const end = source.indexOf('\n  };', start);
  if (start === -1 || end === -1) throw new Error(`Could not find the _routes table in ${ROUTER_FILE}`);
  const keys = [...source.slice(start, end).matchAll(/^\s*'([^']+)'\s*:/gm)].map((m) => m[1]);
  const special = [...source.matchAll(/appId == '([^']+)'/g)].map((m) => m[1]);
  return [...new Set([...keys, ...special])];
}

function main() {
  const { ids: registered, manifestIds, manifestErrors } = loadRegisteredAppIds();
  const covered = (appId) => registered.has(appId) || appId in KNOWN_UNREGISTERED;
  const problems = manifestErrors.map(({ file, message }) => `${file}: ${message}`);

  const packages = fs.readdirSync(PACKAGES_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
  let packagesChecked = 0;
  for (const pkg of packages) {
    const appId = packageAppId(path.join(PACKAGES_DIR, pkg));
    if (!appId) continue;
    packagesChecked += 1;
    if (!covered(appId)) problems.push(`packages/${pkg}/lib/constants.dart: APP_ID '${appId}' is not registered`);
  }

  const routes = routerAppIds(fs.readFileSync(ROUTER_FILE, 'utf8'));
  for (const appId of routes) {
    if (!covered(appId)) problems.push(`lib/routing/app_router.dart: route '${appId}' is not a registered app id`);
  }

  const functionSources = Object.fromEntries(
    fs.readdirSync(FUNCTIONS_DIR)
      .filter((f) => f.endsWith('.js') && !f.endsWith('.test.js'))
      .map((f) => [f, fs.readFileSync(path.join(FUNCTIONS_DIR, f), 'utf8')]),
  );
  const functionIds = functionAppIds(functionSources);
  for (const { file, name, appId } of functionIds) {
    if (!covered(appId)) problems.push(`functions/${file}: ${name} '${appId}' is not a registered app id`);
  }

  for (const appId of Object.keys(KNOWN_UNREGISTERED)) {
    if (registered.has(appId)) {
      problems.push(`KNOWN_UNREGISTERED lists '${appId}', which is now registered; remove the entry`);
    }
  }

  if (problems.length > 0) {
    console.error(`App registration check failed (${problems.length}):\n`);
    for (const problem of problems) console.error(`  ${problem}`);
    console.error(
      '\nA new app registers itself on deploy when its package has a bluejay_app.json manifest ' +
        '(see the create-bluejay-app skill and scripts/firestore_admin/README.md). If the id is ' +
        'wrong, fix the APP_ID constant, route key or functions/*_APP_ID constant to match the registered apps/{docId}. If the ' +
        'app was registered or renamed in App Manager, run ' +
        'node scripts/firestore_admin/refresh_registered_app_ids.js and commit ' +
        'scripts/registered_app_ids.json. If the id is deliberately unregistered, add it to ' +
        'KNOWN_UNREGISTERED in scripts/check_app_ids.js with the reason.',
    );
    process.exit(1);
  }

  console.log(
    `OK: ${packagesChecked} package APP_IDs, ${routes.length} routes and ${functionIds.length} function ` +
      `APP_ID constants are registered ` +
      `(${manifestIds.size} by manifest) or listed in KNOWN_UNREGISTERED.`,
  );
}

if (require.main === module) main();

module.exports = { KNOWN_UNREGISTERED, functionAppIds, routerAppIds };
