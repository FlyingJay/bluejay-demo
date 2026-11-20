#!/usr/bin/env node
/**
 * Fails CI when code reaches a service directly instead of through its shared
 * gateway.
 *
 * Some cross-cutting behaviour only works if every call goes through one
 * place — Usage Meter (plans/usage-meter/IMPLEMENTATION_PLAN.md) records
 * billable usage inside gateways so apps never have to remember to. A call
 * that bypasses the gateway silently escapes that behaviour, and nothing
 * else would notice. This check makes the bypass a build failure instead.
 *
 * Each rule is data: what to look for, in which files, and the one place
 * it's allowed. Add a rule when you add a gateway. A line that genuinely
 * must bypass a gateway can say so with a comment on the same or previous
 * line — `gateway-exempt: <rule-id> <reason>` — which keeps the exception
 * visible in review.
 *
 * Ratchet: a rule introduced while existing code still bypasses the gateway
 * sets `ratchet: true`. Its pre-existing occurrences are recorded per file in
 * check_gateways_baseline.json, and each file must match its recorded count
 * exactly: a new bypass fails, and so does a migrated one until the baseline
 * is lowered with `--update-baseline`, so the slack is reclaimed in the same
 * change that removed it. That flag only ever lowers counts (it refuses to
 * record an increase), so the baseline only shrinks.
 * A new ratchet rule's baseline is seeded once with `--seed-baseline <id>`,
 * which refuses to overwrite an existing one.
 *
 * Usage:
 *   node scripts/check_gateways.js                       # exit 1 and list violations
 *   node scripts/check_gateways.js --update-baseline     # record decreases
 *   node scripts/check_gateways.js --seed-baseline <id>  # new ratchet rule only
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const BASELINE_PATH = path.join(__dirname, 'check_gateways_baseline.json');
const SKIP_DIRS = new Set(['build', '.dart_tool', 'node_modules', '.git', '.symlinks', 'Pods', 'ephemeral']);

/**
 * Deployed Cloud Functions code: everything under functions/ except tests,
 * test helpers and the developer scripts in functions/scripts (which run on
 * a laptop or in CI, never in a function).
 */
const FUNCTIONS_SOURCE = {
  roots: ['functions'],
  ext: '.js',
  exclude: /^functions\/(test\/|scripts\/|.*\.test\.js$|_test_fake_firestore\.js$|_warehouse_test_fakes\.js$|_payments_test_fakes\.js$)/,
};

/** The Dart Storage gateway: the only files that touch Firebase Storage directly. */
const STORAGE_GATEWAY_FILES = [
  'packages/shared_services/lib/scoped_storage.dart',
  'packages/shared_services/lib/platform_service_mobile.dart',
  'packages/shared_services/lib/platform_service_web.dart',
  // Delegates the platform interface's own put*/ref methods to report rules
  // denials (rules_denial_reporter.dart); it creates no uploads itself.
  'packages/shared_services/lib/storage_denial_reporting.dart',
];

/**
 * The only client files that name the root `invoices` / `billing_events`
 * collections — read-only (rules platform-billing-collections / -read-only).
 */
const PLATFORM_BILLING_READERS = [
  'packages/payments/lib/services/invoice_service.dart',
  'packages/payments/lib/services/billing_service.dart',
  'packages/billing/lib/billing_events_reads.dart',
  'packages/scripts/lib/scripts/clear_group_billing_transactions_script.dart',
];

/** Code that ships to devices and browsers. */
const CLIENT_SOURCE = { roots: ['lib', 'packages', 'web'], ext: ['.dart', '.js', '.ts', '.html'] };

/**
 * Server-only Remote Config parameters (secrets and server config): one
 * table, shared with functions/_server_config.js.
 */
const { SERVER_CONFIG_PARAMETERS } = require('../functions/_server_config_parameters');

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * The raw-collection rule (plans/firestore-rules §6.5): a raw
 * `.collection('<name>')` in client code is allowed only when <name> is a
 * pass-through kind in security/collections.json (every kind but `tenant`,
 * the same table that generates the shim's collection_policies.g.dart and
 * MeteredFirestore's debug-mode check). Tenant data goes through
 * ScopedCollection (`sub()` for subcollections, `docForKey()` for natural
 * keys), which stamps and filters the tenant fields the rules prove.
 */
/**
 * ScopedStorage's escape hatches to fixed paths (`ScopedStorage.platform(root:
 * …)` for uploads, `ScopedStorage.refForPath(…)` for reads and deletes) must
 * not name a prefix whose Storage family grants clients nothing
 * (security/storage_paths.json): the legacy prefixes M8 moved into
 * groups/{g}/apps/{a}/, removed apps' data and server-only folders. A
 * platform root needs a family clients may write; a refForPath literal one
 * they may read. Built from the table, so a newly closed prefix is covered.
 */
function storageClosedPrefixRule(table = require('../security/storage_paths.json')) {
  const roots = (pred) => Object.values(table.families).filter(pred)
    .flatMap((f) => f.paths)
    .map((p) => /^([^/{}*]+)\/\*\*$/.exec(p))
    .filter(Boolean)
    .map((m) => m[1].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const noWrite = roots((f) => f.write === 'none').join('|');
  const noRead = roots((f) => f.read === 'none').join('|');
  return {
    id: 'storage-closed-prefix',
    pattern: new RegExp(
      `ScopedStorage\\s*\\.\\s*platform\\s*\\([^)]*?\\broot\\s*:\\s*['"](?:${noWrite})(?:/|['"])` +
      `|ScopedStorage\\s*\\.\\s*refForPath\\s*\\(\\s*['"](?:${noRead})/`,
    ),
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: [],
    message:
      'That Storage prefix grants clients nothing once storage.rules are enforced (security/storage_paths.json): ' +
      'legacy prefixes were moved into groups/{groupId}/apps/{appId}/ by M8. Use ScopedStorage(folder:, appId:), ' +
      'which writes the tenant path, or the stored storagePath/download URL of an existing object.',
  };
}

function rawCollectionRule(table = require('../security/collections.json')) {
  const { shimPolicies, isPassThrough } = require('../security/generate_dart');
  const policies = shimPolicies(table);
  const passThrough = Object.keys(policies).filter((n) => isPassThrough(policies, n)).sort();
  const allowedNames = passThrough.length ? `(?!(?:${passThrough.map(escapeRegExp).join('|')})['"])` : '';
  // A subcollection the table declares under a pass-through parent
  // (`users.subcollections.prefs`) is pass-through too, when the call
  // visibly chains off that parent: `.collection('users').doc(…)
  // .collection('prefs')`. The same name under any other parent (or via a
  // variable) is still checked.
  const quoted = (names) => names.map(escapeRegExp).join('|');
  const docCall = String.raw`\.doc\((?:[^()]|\([^()]*\))*\)`;
  const passThroughSubs = passThrough
    .map((parent) => [parent, Object.keys(table.collections[parent].subcollections || {}).sort()])
    .filter(([, subs]) => subs.length)
    .map(([parent, subs]) =>
      `(?!(?<=\\.collection\\(\\s*['"]${escapeRegExp(parent)}['"]\\s*\\)\\s*${docCall}\\s*` +
      `\\.collection\\(\\s*['"])(?:${quoted(subs)})['"])`)
    .join('');
  return {
    id: 'raw-collection',
    pattern: new RegExp(`\\.collection\\(\\s*['"]${allowedNames}${passThroughSubs}[A-Za-z0-9_]+['"]\\s*\\)`),
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /(^|\/)(test|test_driver|integration_test)\// },
    allowed: [],
    ratchet: true,
    message:
      'Reach tenant data through a ScopedCollection (shared_services/scoped_collection.dart): ' +
      'ScopedCollection(collection:, appId:), .sub(parentId, name) for a subcollection, ' +
      '.docForKey(key) for a natural-key id, .queryInGroup(groupId) for a group other than the ' +
      'active one. Platform registries have shared read helpers in shared_services: ' +
      'AccessIndex (access_index.dart) for users/{uid}/metadata/access_index (or ' +
      'UserAppEntitlements for a typed view), GroupDocs and MembershipDocs (group_docs.dart) for ' +
      'groups and memberships. Raw .collection() is only for pass-through kinds (server, ' +
      'personal, platform, platform_admin, public) and the subcollections security/collections.json ' +
      'declares under them, chained off the parent (.collection(\'users\').doc(uid).collection(\'prefs\')). ' +
      'If this read genuinely must be raw, add `// gateway-exempt: raw-collection <reason>`.',
  };
}

/**
 * Every ScopedCollection names a collection security/collections.json
 * declares (plan §7.1). An undeclared collection is still kind tenant in the
 * rules, but declaring it records which app owns it (`apps`), which the
 * rules use to scope list queries and to refuse docs tagged with another
 * app, and keeps the table a complete inventory (stage 7 found two live
 * collections that weren't). Built from the table, so a new entry is
 * picked up with no edit here.
 */
function undeclaredCollectionRule(table = require('../security/collections.json')) {
  const names = Object.keys(table.collections).sort().map(escapeRegExp).join('|');
  return {
    id: 'undeclared-collection',
    pattern: new RegExp(`\\bScopedCollection\\s*\\(\\s*collection\\s*:\\s*['"](?!(?:${names})['"])[A-Za-z0-9_]+['"]` +
      `|^\\s*collection\\s*:\\s*['"](?!(?:${names})['"])[A-Za-z0-9_]+['"]`),
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /(^|\/)(test|test_driver|integration_test)\// },
    allowed: [],
    message:
      'Declare the collection in security/collections.json (`"<name>": { "apps": ["<appId>"] }` for an ' +
      "app's own tenant data; see the change-firestore-permissions skill) and run `node security/generate.js`. " +
      'If the collection must stay undeclared, add `// gateway-exempt: undeclared-collection <reason>`.',
  };
}

/**
 * One rule per server-only parameter: no client code may name it, with no
 * exceptions.
 */
function serverConfigClientRules(parameters = SERVER_CONFIG_PARAMETERS) {
  return Object.entries(parameters).map(([name, spec]) => ({
    id: 'server-config-in-client',
    pattern: new RegExp(`['"\`]${escapeRegExp(name)}['"\`]`),
    files: CLIENT_SOURCE,
    allowed: [],
    message:
      `"${name}" is a server-only ${spec.kind} (functions/_server_config_parameters.js). ` +
      'Clients must never read it: anything a device can fetch, anyone can. Call a ' +
      'Cloud Function that uses it server-side instead.',
  }));
}

/**
 * Functions code may not ask the client template for a server-only
 * parameter (readClientConfigValue refuses it at runtime too; this fails
 * in CI instead of in production).
 */
function serverConfigAsClientValueRule(parameters = SERVER_CONFIG_PARAMETERS) {
  const names = Object.keys(parameters).map(escapeRegExp).join('|');
  return {
    id: 'server-config-as-client-value',
    pattern: new RegExp(`\\breadClientConfigValue\\s*\\(\\s*['"\`](?:${names})['"\`]`),
    files: FUNCTIONS_SOURCE,
    allowed: [],
    message:
      'Server-only parameters (functions/_server_config_parameters.js) come from Secret ' +
      'Manager through readServerSecret(), never from the client Remote Config template.',
  };
}

/**
 * The callable tenant check (plans/firestore-rules §4.9, T15): an onCall /
 * onRequest endpoint that reads a client-supplied groupId / appId (directly,
 * through an alias of the payload, or in a same-file helper it hands the
 * payload to) must reach a tenant check — a functions/_tenant_access.js
 * helper, or any functions/ function that itself calls one (so wrappers like
 * requireAppTier / assertCanSeeItem count). One finding per endpoint; see
 * scripts/callable_tenant_analysis.js. Ratchet: the endpoints that check
 * some other way (platform-admin-only, a hashed token, …) are in the
 * baseline until they adopt a shared helper or say so with a gateway-exempt.
 */
function callableTenantCheckRule() {
  const analysis = require('./callable_tenant_analysis');
  const isSource = (rel) => !FUNCTIONS_SOURCE.exclude.test(rel);
  return {
    id: 'callable-tenant-check',
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_tenant_access.js', 'functions/_metered_functions.js'],
    ratchet: true,
    analyze(rel, source, root = ROOT) {
      const checkNames = analysis.repoTenantCheckNames(root, isSource);
      return analysis.analyzeSource(source, { checkNames, ruleId: 'callable-tenant-check' });
    },
    message:
      'This endpoint reads a tenant id (groupId/appId) from the request but never checks the ' +
      'caller against it. The Admin SDK ignores firestore.rules, so call requireGroupEntitlement / ' +
      'requireGroupAdmin / assertBelongsToGroup (functions/_tenant_access.js) on the group it ' +
      "acts in, preferring the stored doc's own groupId (trustedGroupId()). If the endpoint is " +
      'covered another way (platform admins only, a hashed token…), say so on its onCall line: ' +
      '`// gateway-exempt: callable-tenant-check <the check that covers it>`.',
  };
}

/**
 * Automations registries: a module that calls register*() but isn't listed in
 * AUTOMATION_MODULES (functions/_automation_modules.js) registers only in the
 * function instances that happened to load it, so some instances would miss
 * its event types, actions or built-ins. The listed modules, plus the
 * registry that defines the functions, are the allowed files.
 */
function automationRegistrationRule() {
  const { AUTOMATION_MODULES } = require('../functions/_automation_modules');
  return {
    id: 'automation-registration',
    pattern: /\bregister(?:EventType|ConditionOperator|ActionType|NotifyTemplate|BuiltInAutomation)\s*\(/,
    files: FUNCTIONS_SOURCE,
    allowed: [
      'functions/_automation_registry.js',
      ...AUTOMATION_MODULES.map((modulePath) => `functions/${modulePath.replace(/^\.\//, '')}.js`),
    ],
    message:
      'Register Automations entries from a module listed in AUTOMATION_MODULES ' +
      '(functions/_automation_modules.js), so every function instance loads them.',
  };
}

const RULES = [
  {
    id: 'sign-out',
    pattern: /FirebaseAuth\s*\.\s*instance\s*\.\s*signOut\s*\(/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: ['packages/shared_services/lib/usage_meter.dart'],
    message:
      'Sign out with signOutWithUsageFlush() (shared_services/usage_meter.dart), which ' +
      "flushes the user's buffered usage while their credentials are still valid.",
  },
  {
    id: 'storage-instance',
    pattern: /FirebaseStorage\s*\.\s*(instance|instanceFor)\b/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: STORAGE_GATEWAY_FILES,
    message:
      'Reach Firebase Storage through ScopedStorage (shared_services/scoped_storage.dart): ' +
      'ScopedStorage(...) / ScopedStorage.platform(...) for uploads, ' +
      'ScopedStorage.refForPath / refFromURL for reads and deletes of existing objects.',
  },
  {
    id: 'storage-put',
    pattern: /\.put(Data|File|String|Blob)\s*\(/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: STORAGE_GATEWAY_FILES,
    message:
      'Upload with ScopedStorage.upload / putBytes or PlatformService.uploadImageFile / ' +
      'uploadGenericFile, which stamp the creatorId/groupId/appId metadata storage rules ' +
      'check and Usage Meter attributes stored bytes by (functions/usage_storage.js).',
  },
  storageClosedPrefixRule(),
  {
    id: 'functions-builders',
    // logger and params build no functions, so they may be required directly.
    pattern: /require\(\s*['"]firebase-functions(?!\/(?:logger|params)['"])[^'"]*['"]\s*\)/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_metered_functions.js'],
    message:
      "Get onCall/onRequest/triggers/HttpsError from require('./_metered_functions')(module), " +
      'which builds 2nd-gen functions in their policy region, meters every invocation and ' +
      'attributes its usage to the right group, user and app.',
  },
  {
    id: 'functions-region-literal',
    // A Google Cloud region id (us-central1, northamerica-northeast2, ...).
    // AWS-style hosts such as email-smtp.us-east-2.amazonaws.com don't match.
    pattern: /\b(?:us|northamerica|southamerica|europe|asia|australia|me|africa)-(?:central|north|south|east|west|northeast|northwest|southeast|southwest)[0-9]+\b/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_function_regions.js'],
    message:
      "Take regions from require('./_function_regions') (DATA_REGION, regionsFor, functionUrl, " +
      'taskQueuePath). _metered_functions.js already gives every builder call its policy region, ' +
      'so a function module never names one.',
  },
  {
    id: 'functions-service-account-literal',
    // A Google-managed default runtime account (App Engine or Compute Engine).
    pattern: /@appspot\.gserviceaccount\.com|-compute@developer\.gserviceaccount\.com/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_function_identity.js'],
    message:
      "Take runtime service accounts from require('./_function_identity') (appEngineIdentity, " +
      'APP_ENGINE_SERVICE_ACCOUNT), so every identity a function runs as is named in one place ' +
      'and recorded in functions/function_generations.json.',
  },
  {
    id: 'functions-http',
    // axios, or a bare fetch( call (not a method like client.fetch().
    pattern: /require\(\s*['"]axios['"]\s*\)|(?:^|[^.\w$])fetch\s*\(/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_external_http.js'],
    message:
      "Call external APIs through require('./_external_http') (axios-compatible get/post/request, " +
      'and fetch), which meters each call per host.',
  },
  {
    id: 'functions-stripe',
    pattern: /require\(\s*['"]stripe['"]\s*\)/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_stripe.js'],
    message:
      "Create Stripe clients with require('./_stripe').createStripeClient(key), which meters " +
      'every Stripe API call as ext:api.stripe.com.',
  },
  {
    id: 'functions-stripe-webhook',
    // Verifying (constructEvent / the SDK's webhook helpers) or reading the
    // signature header outside the shared verifier is how an endpoint ends
    // up skipping verification, or verifying with a fallback that doesn't.
    pattern: /\bconstructEvent(?:Async)?\s*\(|(?<!function\s+)\bstripeWebhooks\s*\(|['"`]stripe-signature['"`]/i,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_stripe_webhook.js'],
    message:
      "Accept Stripe webhooks only through stripeWebhookHandler() in functions/_stripe_webhook.js " +
      '(fails closed without a signing secret, verifies the raw body, dedupes event ids).',
  },
  {
    id: 'stripe-payment-intent-create',
    // A PaymentIntent created anywhere else has an amount the payments core
    // didn't price, fees it didn't compute and no order to settle against.
    // No exemptions: the platform's own billing (invoices, the monthly
    // auto-charge) goes through the core too (platform-account mode).
    pattern: /\bpaymentIntents\s*\.\s*create\s*\(/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_payments.js'],
    message:
      'Take payments through the payments core: register a kind with registerPaymentKind() ' +
      '(functions/_payments.js) and let paymentsCreateOrder create the PaymentIntent, so the ' +
      'price comes from server data and fulfillment runs only after a verified payment.',
  },
  {
    id: 'stripe-connected-account',
    // Acting on an organization's connected account (direct charges,
    // refunds) is the payments core's job; a stray `stripeAccount` option
    // moves money on someone's account with no ledger entry.
    pattern: /\bstripeAccount\s*:|['"`]stripe-account['"`]/i,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_payments.js'],
    message:
      'Only functions/_payments.js acts on a connected Stripe account (the stripeAccount option / ' +
      'Stripe-Account header). Go through the payments core (registerPaymentKind + paymentsCreateOrder).',
  },
  {
    id: 'stripe-client-confirm',
    // Confirming a payment (or pointing Stripe at a connected account) from
    // app code means the app decides what "paid" means. PaymentCheckout
    // confirms and then asks the server, which checks with Stripe.
    pattern: /\bStripe\s*\.\s*instance\s*\.\s*(?:confirmPayment|handleNextAction|presentPaymentSheet|confirmPaymentSheetPayment)\s*\(|\bStripe\s*\.\s*stripeAccountId\b/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: ['packages/shared_services/lib/payments/stripe_payment_checkout.dart'],
    message:
      'Take payments with PaymentCheckout (shared_services/payments/payment_checkout.dart), which ' +
      'creates a server-priced order, confirms it on the right connected account and has the ' +
      'server verify the payment before anything is marked paid.',
  },
  {
    id: 'platform-billing-collections',
    // Invoices and billing events are written only by Cloud Functions
    // (firestore.rules blocks client writes): a client that could would mark
    // its own invoice paid or rewrite its own charges. Client code reaches
    // the root `invoices` / `billing_events` collections only through these
    // read-only accessors (budgie_ting's own `budgie_ting/{uid}/invoices`
    // subcollection is a different collection and isn't matched).
    pattern: /\bcollection\s*:\s*['"](?:invoices|billing_events)['"]|(?:\bforApp\s*\([^)]*\)|\binstance)\s*\.\s*collection\s*\(\s*['"](?:invoices|billing_events)['"]/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: PLATFORM_BILLING_READERS,
    message:
      'Invoices and billing events are server-written only. Read them through the read-only ' +
      'accessors (packages/payments InvoiceService / BillingService, packages/billing ' +
      'billing_events_reads.dart) and change them through the payments callables ' +
      '(paymentsAdminCreateBillingEvent, paymentsBillingEventAction, paymentsAdminGenerateInvoice); ' +
      'pay an invoice with PaymentCheckoutView (kind platform.invoice).',
  },
  {
    id: 'platform-billing-read-only',
    // The read-only accessors above stay read-only: no Firestore writes.
    pattern: /\b(?:batch|tx|transaction|txn)\s*\.\s*(?:set|update|delete)\s*\(|\.doc\s*\([^)]*\)\s*\.\s*(?:set|update|delete)\s*\(|\.reference\s*\.\s*(?:set|update|delete)\s*\(|\.collection\s*\([^)]*\)\s*\.\s*add\s*\(|\.batch\s*\(\s*\)|\brunTransaction\s*\(/,
    files: { roots: PLATFORM_BILLING_READERS, ext: '.dart' },
    allowed: [],
    message:
      'This file is a read-only accessor of invoices / billing events (rule platform-billing-collections). ' +
      'Send changes to the payments callables instead; firestore.rules rejects client writes anyway.',
  },
  {
    id: 'functions-messaging-sdk',
    // Sends are metered (emails by recipient, SMS) by writeNotificationAuditLog,
    // which every send helper in _shared.js funnels through, so the SDKs are
    // only allowed where those helpers live.
    pattern: /require\(\s*['"](nodemailer|twilio)['"]\s*\)/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_shared.js'],
    message:
      'Send email/SMS through sendEmail/sendSms in functions/_shared.js, which audit and meter ' +
      'every send (writeNotificationAuditLog).',
  },
  {
    id: 'functions-bigquery',
    pattern: /require\(\s*['"]@google-cloud\/bigquery['"]\s*\)/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_warehouse_bigquery_client.js'],
    message:
      'Run BigQuery through functions/_warehouse_bigquery_client.js (runQuery/runStatement), ' +
      'which meters the bytes each job bills.',
  },
  {
    id: 'functions-firestore-instance',
    // Server Firestore ops are metered by hooks on the default app's shared
    // admin.firestore() instance; any other Firestore bypasses them. Banned:
    // importing @google-cloud/firestore; getFirestore()/initializeFirestore()/
    // new Firestore(); `.firestore(<anything>)` on any expression (another
    // app); `<x>.app(...).firestore(` (a named app's instance); and
    // initializeApp(<args>) (a second, named app). Value types (FieldValue,
    // Timestamp, AggregateField, ...) from 'firebase-admin/firestore' and
    // plain admin.firestore() / admin.initializeApp() are fine.
    pattern: new RegExp([
      /require\(\s*['"]@google-cloud\/firestore['"]\s*\)/.source,
      /\b(?:getFirestore|initializeFirestore)\s*\(/.source,
      /\bnew\s+Firestore\s*\(/.source,
      /[\w$\])]\s*\.\s*firestore\s*\(\s*[^)\s]/.source,
      /\.\s*app\s*\([^)]*\)\s*\.\s*firestore\s*\(/.source,
      /\binitializeApp\s*\(\s*[^)\s]/.source,
    ].join('|')),
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_firestore_metering.js'],
    message:
      'Use admin.firestore() on the default app (admin.initializeApp() with no arguments), which ' +
      'functions/_firestore_metering.js meters for Usage Meter; any other Firestore instance or app bypasses it.',
  },
  {
    id: 'firestore-instance',
    pattern: /\bFirebaseFirestore\s*\.\s*instance(?:For)?\b/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: [
      'packages/shared_services/lib/metered_firestore.dart',
      'packages/shared_services/lib/bluejay_firestore.dart',
      // Usage Meter's own usage_daily writes must not meter themselves.
      'packages/shared_services/lib/usage_meter.dart',
      // The install check probes the default instance.
      'packages/shared_services/lib/firestore_platform_metering.dart',
      // Clears the web cache on sign-out (terminate, clearPersistence): no reads or writes.
      'packages/shared_services/lib/firestore_web_cache.dart',
    ],
    ratchet: true,
    message:
      'Use BluejayFirestore.forApp(APP_ID) (shared_services/bluejay_firestore.dart) or a ' +
      'ScopedCollection, which meter Firestore reads/writes for Usage Meter.',
  },
  {
    id: 'raw-doc-write',
    // A ScopedCollection's own write methods keep a doc's identity fields
    // intact and, on an auditTrail collection, stamp lastModifiedBy and
    // lastModifiedAt, which the rules require there (auditStampOk). A raw
    // write chained off its .doc() skips both. ScopedCollection instances are
    // conventionally `_name` fields; existing raw writes are in the baseline.
    pattern: /\b_\w+\s*\.doc\((?:[^()]|\([^()]*\))*\)\s*\.(?:update|set)\(/,
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /(^|\/)(test|test_driver|integration_test)\// },
    allowed: [],
    ratchet: true,
    message:
      'Write through the collection: `_coll.update(_coll.doc(id), data)` (or batchUpdate / ' +
      'transactionUpdate / set). It keeps groupId/appId/creatorId intact and stamps the audit ' +
      'fields an auditTrail collection requires; a raw write to an audited collection is refused ' +
      'by the rules. If this write genuinely must be raw, add `// gateway-exempt: raw-doc-write <reason>`.',
  },
  {
    id: 'users-collection',
    // Rules plan T9 / stage 2: `users/{uid}` is personal (only its owner reads
    // it). Another user's name, email or picture comes from the group member
    // directory (shared_services/group_member_directory.dart). Reads of the
    // signed-in user's own doc (`.doc(currentUser.uid)`, `.doc(user.uid)`,
    // `.doc(uid)`, `.doc(userId)` — the names the codebase uses for the
    // caller) don't match; what's left are platform-admin tools (EX-ADMIN-1),
    // recorded in the baseline, so a new cross-user read fails CI.
    pattern: new RegExp(
      /\.collection\(\s*['"]users['"]\s*\)/.source +
      /(?!\s*\.doc\(\s*(?:widget\s*\.\s*)?(?:_?currentUser[!?]?\s*\.\s*uid|user[!?]?\s*\.\s*uid|uid|userId|currentUserUid)\s*\))/.source,
    ),
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /\/test\// },
    allowed: [],
    ratchet: true,
    message:
      "To show another user's name, email or picture, use GroupMemberDirectory " +
      '(shared_services/group_member_directory.dart), which reads group_members; ' +
      "other users' users/{uid} docs are owner-only. For the signed-in user's own doc or " +
      'access index (or a platform-admin tool), mark the line ' +
      '`// gateway-exempt: users-collection own doc` (or `... platform admin only`).',
  },
  {
    id: 'ai-sdk-dart',
    // The Gemini SDKs (google_generative_ai, firebase_ai, firebase_vertexai)
    // or their REST hosts — any direct client path to a generative model.
    pattern: /\bGenerativeModel\s*\(|package:(google_generative_ai|firebase_ai|firebase_vertexai)\/|generativelanguage\.googleapis\.com|aiplatform\.googleapis\.com/,
    files: { roots: ['lib', 'packages'], ext: '.dart' },
    allowed: ['packages/shared_services/lib/ai_service.dart'],
    message:
      'Call AI through AiModel (shared_services/ai_service.dart), which goes via the ' +
      'aiGenerate endpoints so usage is metered, entitlement-checked and rate-limited, ' +
      'and no API key ships to the device.',
  },
  {
    id: 'ai-sdk-server',
    pattern: /\bnew\s+GoogleGenerativeAI\b|require\(\s*['"]@google\/generative-ai['"]\s*\)/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_ai.js'],
    message:
      'Call Gemini through generate()/generateStream() in functions/_ai.js, which records ' +
      'aiCalls/aiInTokens/aiOutTokens per model for Usage Meter.',
  },
  {
    id: 'places-direct',
    // The Places web services (legacy and New) or the client-visible key
    // that would authenticate them. A device calling Google directly needs
    // a key with no application restriction (a raw HTTP call carries no
    // Android/iOS app identity), so every client goes through the proxy.
    pattern: /maps\.googleapis\.com\/maps\/api\/(?:place|geocode)\b|places\.googleapis\.com|['"`]google_places_api_key['"`]/,
    files: CLIENT_SOURCE,
    allowed: [],
    message:
      'Reach Google Places through GooglePlacesClient (or GooglePlacesClient.proxyUri) in ' +
      'shared_services/places/google_places_client.dart, which goes via the googlePlacesProxy ' +
      'Cloud Function so no Places API key ships to or is sent from a device.',
  },
  {
    id: 'cloud-functions-client',
    // The region clients call is stated once, in the Dart gateway
    // (plans/functions-region-ne2/MIGRATION_PLAN.md 5.2).
    pattern: /\bFirebaseFunctions\s*\.\s*instance(?:For)?\b|cloudfunctions\.net/,
    files: CLIENT_SOURCE,
    // The gateway's test proves it hands out what the raw calls did.
    allowed: ['packages/shared_services/lib/cloud_functions.dart', 'packages/shared_services/test/cloud_functions_test.dart'],
    message:
      "Reach Cloud Functions through package:shared_services/cloud_functions.dart: BluejayFunctions.instance " +
      '(callables; a constructor-injected FirebaseFunctions defaults to it), BluejayFunctions.functionUri(name) ' +
      'or kFunctionsBaseUrl (onRequest URLs), BluejayFunctions.publicUri(path) (links people keep). ' +
      'It names the region every client calls (kFunctionsRegion), so moving functions is a one-line change.',
  },
  {
    id: 'public-link-host',
    // Links people keep or share are built on publicLinkHost, which is the
    // preview's own host in a PR preview build, so a link copied from a
    // preview opens the preview (and its sandbox data), not production.
    pattern: /['"]https?:\/\/bluejay\.gg\b|Uri\.https\(\s*(?:['"]bluejay\.gg['"]|kPublicHost\b)/,
    files: { roots: ['lib', 'packages'], ext: ['.dart'], exclude: /(?:^|\/)test\// },
    allowed: ['packages/shared_services/lib/cloud_functions.dart', 'packages/shared_ui/lib/legal_links.dart'],
    message:
      "Build links on publicLinkHost (package:shared_services/cloud_functions.dart), e.g. " +
      "Uri.https(publicLinkHost, '/portal/$slug'), or BluejayFunctions.publicUri(path). It is bluejay.gg in " +
      'production and the preview\'s own host in a PR preview build, so links copied in a preview stay in the preview.',
  },
  {
    id: 'places-proxy-url',
    // googlePlacesProxy only serves signed-in callers (functions/_http_auth.js);
    // GooglePlacesClient.proxyGet attaches the ID token, a hand-built URL
    // fetched with plain http.get would get 401. Function URLs come from the
    // cloud-functions-client gateway, so its forms are the ones to catch.
    pattern: /cloudfunctions\.net\/googlePlacesProxy\b|kFunctionsBaseUrl\}?\/googlePlacesProxy\b|\bfunctionUr[il]\(\s*['"]googlePlacesProxy['"]/,
    files: CLIENT_SOURCE,
    allowed: ['packages/shared_services/lib/places/google_places_client.dart'],
    message:
      'Call the Places proxy with GooglePlacesClient.proxyGet (shared_services/places/' +
      'google_places_client.dart), which sends the Firebase ID token the proxy requires.',
  },
  {
    id: 'remote-config-template',
    // getTemplate() is the CLIENT template, which every app can download, so a
    // secret read from it is already leaked. Every Remote Config read goes
    // through _server_config.js (readServerSecret / readClientConfigValue).
    pattern: /\b(?:get|getServer|initServer)Template\s*\(|\.parameters\s*\[|\bdefaultValue\s*\??\.\s*value\b/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_server_config.js'],
    message:
      "Read secrets and server-only config with readServerSecret() (require('./_server_config')), " +
      'which reads Secret Manager, not the client Remote Config template every app can download. ' +
      'Read client-safe values with readClientConfigValue().',
  },
  {
    id: 'access-index-read',
    // Only the server writes the stored index (users/{uid}/metadata is
    // serverWritten), but its roles/status/clearance are derived copies:
    // getAccessIndex() overlays the Auth-claims values
    // (functions/_platform_access.js), so a stale or tampered index never
    // grants platform access.
    pattern: /\.doc\(\s*['"`]access_index['"`]\s*\)|\bdoc\(\s*[`'"][^`'"]*metadata\/access_index/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_shared.js'],
    message:
      "Read a user's access index with getAccessIndex(uid) (functions/_shared.js), which overlays " +
      'the trusted platform roles/status/clearance from Auth custom claims. The stored document ' +
      'is a derived copy that can lag the claims.',
  },
  {
    id: 'storage-object-path',
    // bucket.file(<expression>) acts on whatever path the expression holds,
    // bypassing storage.rules. Paths that came from client-written data must
    // go through _storage_paths.js (tenantStorageFile & co.); a path the
    // server built itself says so with a gateway-exempt comment.
    pattern: /\.file\(\s*(?!['"`][^'"`$]*['"`]\s*\))[^)\s]/,
    files: FUNCTIONS_SOURCE,
    allowed: ['functions/_storage_paths.js'],
    message:
      'Open Storage objects named by client-written data with tenantStorageFile() / ' +
      'groupLogoStorageFile() / appIconStorageFile() (functions/_storage_paths.js), which refuse ' +
      "paths outside the request's trusted group and app. If the path is built entirely by the " +
      'server, add `// gateway-exempt: storage-object-path <why>`.',
  },
  callableTenantCheckRule(),
  automationRegistrationRule(),
  {
    id: 'remote-config-server-template',
    // Server config has one source, Secret Manager (readServerSecret); the
    // server Remote Config template was a fallback and is gone, so a second
    // source can't creep back in, not even in _server_config.js.
    pattern: /\b(?:getServer|initServer)Template\s*\(/,
    files: FUNCTIONS_SOURCE,
    allowed: [],
    message:
      'Server-only configuration lives in Secret Manager only: add the parameter to ' +
      'functions/_server_config_parameters.js and read it with readServerSecret().',
  },
  serverConfigAsClientValueRule(),
  rawCollectionRule(),
  undeclaredCollectionRule(),
  {
    id: 'gateway-collection',
    // MeteredFirestore.scopedCollection skips the raw-collection debug check;
    // only ScopedCollection, which stamps and filters the tenant fields, may,
    // and the read-only GroupDocs/MembershipDocs gateway to the groups and
    // memberships registries (tenant kind, but no app's ScopedCollection).
    pattern: /\.scopedCollection\s*\(/,
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /(^|\/)test\// },
    allowed: ['packages/shared_services/lib/scoped_collection.dart', 'packages/shared_services/lib/group_docs.dart'],
    message:
      'MeteredFirestore.scopedCollection is ScopedCollection\'s own entry point. Use a ' +
      'ScopedCollection, or a raw .collection() for a pass-through kind.',
  },
  {
    id: 'entitlement-scope-literal-app-id',
    // A `{groupId}:{appId}` entitlement scope with the app id typed by hand
    // ('$groupId:rented_dwelling:admin'). computeEntitlements only ever keys
    // scopes by the registered apps/{docId}, so a hand-typed id that drifts
    // from it (underscore vs hyphen, a pre-rename name) silently grants
    // nothing, or keeps honouring an id nothing can grant (#1829).
    pattern: /\$\{?[A-Za-z_.]*[gG]roup[A-Za-z]*\}?:[a-z][a-z0-9_-]*/,
    files: { roots: ['lib', 'packages'], ext: '.dart', exclude: /(^|\/)test\// },
    allowed: [],
    message:
      'Check entitlements with UserAppEntitlements.hasAppTier(groupId, APP_ID, tier) ' +
      '(shared_services/user_app_entitlements.dart), keyed by the package\'s APP_ID, ' +
      'never a hand-typed app id that can drift from the registered apps/{docId}.',
  },
  ...serverConfigClientRules(),
];

function* walk(dir) {
  let entries;
  try {
    // A root may name a single file.
    if (fs.statSync(dir).isFile()) {
      yield dir;
      return;
    }
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) yield* walk(path.join(dir, entry.name));
    } else if (entry.isFile()) {
      yield path.join(dir, entry.name);
    }
  }
}

/**
 * Violations of [rule] in one file's [source] (relative path [rel]).
 *
 * The pattern is matched against the whole file, not line by line, so a
 * call dart-format split across lines (`FirebaseFirestore\n    .instance`)
 * is still caught; patterns should use `\s*` between tokens. Each match is
 * reported at the line it starts on, once per line. A match is skipped when
 * that line is a comment (or the match follows a `//` outside a string
 * literal on it), or when the match's lines or the line before carry
 * `gateway-exempt: <rule-id>`.
 */
function checkSource(rule, rel, source, root = ROOT) {
  if (rule.allowed.includes(rel)) return [];
  if (rule.files.exclude && rule.files.exclude.test(rel)) return [];
  // A rule that needs more than a pattern (callable-tenant-check) analyses
  // the file itself and handles its own gateway-exempt comments.
  if (rule.analyze) {
    return rule.analyze(rel, source, root).map((f) => ({
      rule: rule.id, file: rel, line: f.line, text: f.text, message: rule.message,
    }));
  }
  const lines = source.split('\n');
  const lineStarts = [];
  let offset = 0;
  for (const line of lines) {
    lineStarts.push(offset);
    offset += line.length + 1;
  }
  const lineAt = (index) => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= index) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  };
  // `g` to find every match; `m` so a `^`/`$` in a pattern still means
  // start/end of a line, as it did when patterns were tested line by line.
  let flags = rule.pattern.flags;
  for (const f of ['g', 'm']) if (!flags.includes(f)) flags += f;
  const pattern = new RegExp(rule.pattern.source, flags);
  const exempt = new RegExp(`gateway-exempt:\\s*${rule.id}\\b`);
  const out = [];
  const reported = new Set();
  for (const match of source.matchAll(pattern)) {
    // A pattern may consume the character before the call (e.g. a
    // `[^.\w$]` boundary), which can be the previous line's newline; report
    // the match where its first non-whitespace character is.
    const start = match.index + (match[0].length - match[0].trimStart().length);
    const first = lineAt(start);
    const last = lineAt(match.index + Math.max(match[0].length - 1, 0));
    const line = lines[first];
    const trimmed = line.trim();
    if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) continue;
    // A `//` comment opened earlier on the line (outside any string
    // literal, so a URL's `https://` doesn't count).
    if (opensLineComment(line.slice(0, start - lineStarts[first]))) continue;
    // One violation per line, as when patterns were tested line by line.
    if (reported.has(first)) continue;
    let exempted = first > 0 && exempt.test(lines[first - 1]);
    for (let i = first; i <= last && !exempted; i++) exempted = exempt.test(lines[i]);
    if (exempted) continue;
    reported.add(first);
    out.push({ rule: rule.id, file: rel, line: first + 1, text: trimmed, message: rule.message });
  }
  return out;
}

/** Whether [text] (the start of a line) opens a `//` comment outside a string. */
function opensLineComment(text) {
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === '\\') i++;
      else if (c === quote) quote = null;
    } else if (c === "'" || c === '"' || c === '`') {
      quote = c;
    } else if (c === '/' && text[i + 1] === '/') {
      return true;
    }
  }
  return false;
}

/** Every occurrence of [rule] in the repo, grouped by file. */
function scanRule(rule, root) {
  const byFile = new Map();
  for (const r of rule.files.roots) {
    for (const file of walk(path.join(root, r))) {
      if (![].concat(rule.files.ext).some((ext) => file.endsWith(ext))) continue;
      const rel = path.relative(root, file).split(path.sep).join('/');
      const found = checkSource(rule, rel, fs.readFileSync(file, 'utf8'), root);
      if (found.length) byFile.set(rel, found);
    }
  }
  return byFile;
}

/**
 * Applies a ratchet rule's [allowedCounts] (file → count) to its occurrences
 * [byFile]. A file over its count fails with each occurrence listed. A file
 * under it (including one with none left) also fails, as a stale baseline
 * that must be lowered; those are listed in `improved` too.
 */
function applyBaseline(rule, byFile, allowedCounts = {}) {
  const violations = [];
  const improved = [];
  const stale = (file, from, to) => {
    improved.push({ rule: rule.id, file, from, to });
    violations.push({
      rule: rule.id,
      file,
      line: 0,
      text: `baseline allows ${from}, found ${to}`,
      message:
        'Fewer bypasses than check_gateways_baseline.json records. Lock that in: ' +
        'node scripts/check_gateways.js --update-baseline',
    });
  };
  for (const [file, found] of byFile) {
    const allowed = allowedCounts[file] || 0;
    if (found.length > allowed) {
      const note = allowed
        ? ` (${file} may have at most ${allowed} — its baseline in check_gateways_baseline.json; found ${found.length})`
        : '';
      violations.push(...found.map((v) => ({ ...v, message: v.message + note })));
    } else if (found.length < allowed) {
      stale(file, allowed, found.length);
    }
  }
  for (const [file, allowed] of Object.entries(allowedCounts)) {
    if (!byFile.has(file) && allowed > 0) stale(file, allowed, 0);
  }
  return { violations, improved };
}

function loadBaseline(baselinePath = BASELINE_PATH) {
  return fs.existsSync(baselinePath) ? JSON.parse(fs.readFileSync(baselinePath, 'utf8')) : {};
}

/**
 * Checks every rule. Returns violations (fail), `improved` (ratchet files now
 * under their baseline), and `counts` (each ratchet rule's current per-file
 * counts, for --update-baseline).
 */
function checkRepoDetailed(root = ROOT, rules = RULES, baseline = loadBaseline()) {
  const violations = [];
  const improved = [];
  const counts = {};
  for (const rule of rules) {
    const byFile = scanRule(rule, root);
    if (!rule.ratchet) {
      for (const found of byFile.values()) violations.push(...found);
      continue;
    }
    const result = applyBaseline(rule, byFile, baseline[rule.id]);
    violations.push(...result.violations);
    improved.push(...result.improved);
    counts[rule.id] = Object.fromEntries([...byFile].map(([f, v]) => [f, v.length]).sort());
  }
  return { violations, improved, counts };
}

function checkRepo(root = ROOT, rules = RULES, baseline = loadBaseline()) {
  return checkRepoDetailed(root, rules, baseline).violations;
}

/**
 * The baseline after recording [counts], lowering only: a file's count can
 * fall (or the file drop out), never rise or appear. Returns the new
 * baseline plus any refused increases.
 */
function lowerBaseline(baseline, counts) {
  const next = {};
  const refused = [];
  for (const [ruleId, current] of Object.entries(counts)) {
    const before = baseline[ruleId] || {};
    const files = {};
    for (const [file, n] of Object.entries(current)) {
      const allowed = before[file] || 0;
      if (n > allowed) refused.push({ rule: ruleId, file, from: allowed, to: n });
      const kept = Math.min(n, allowed);
      if (kept > 0) files[file] = kept;
    }
    next[ruleId] = Object.fromEntries(Object.entries(files).sort());
  }
  return { baseline: next, refused };
}

function main(argv) {
  const baseline = loadBaseline();
  const { violations, improved, counts } = checkRepoDetailed(ROOT, RULES, baseline);

  const seedIndex = argv.indexOf('--seed-baseline');
  if (seedIndex >= 0) {
    const id = argv[seedIndex + 1];
    if (!counts[id]) {
      console.error(`--seed-baseline: "${id}" is not a ratchet rule.`);
      return 1;
    }
    if (baseline[id]) {
      console.error(`--seed-baseline: "${id}" already has a baseline; it can only be lowered (--update-baseline).`);
      return 1;
    }
    const next = { ...baseline, [id]: counts[id] };
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(next, null, 2) + '\n');
    const total = Object.values(counts[id]).reduce((a, b) => a + b, 0);
    console.log(`Seeded "${id}": ${total} occurrence(s) in ${Object.keys(counts[id]).length} file(s).`);
    return 0;
  }

  if (argv.includes('--update-baseline')) {
    const { baseline: next, refused } = lowerBaseline(baseline, counts);
    fs.writeFileSync(BASELINE_PATH, JSON.stringify(next, null, 2) + '\n');
    const lowered = improved.length;
    console.log(`Baseline updated: ${lowered} file(s) lowered.`);
    for (const r of refused) {
      console.error(`Not recorded (increase): ${r.file} [${r.rule}] ${r.from} → ${r.to}`);
    }
    const remaining = checkRepoDetailed(ROOT, RULES, next).violations;
    return refused.length || remaining.length ? 1 : 0;
  }

  if (violations.length) {
    for (const v of violations) {
      console.error(`${v.file}:${v.line}  [${v.rule}]  ${v.text}\n    → ${v.message}`);
    }
    console.error(`\n${violations.length} gateway bypass(es). See scripts/check_gateways.js.`);
    return 1;
  }
  console.log(`Gateway check passed (${RULES.length} rule(s)).`);
  return 0;
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}

module.exports = {
  RULES,
  checkSource,
  checkRepo,
  checkRepoDetailed,
  applyBaseline,
  lowerBaseline,
  loadBaseline,
  serverConfigClientRules,
  serverConfigAsClientValueRule,
  rawCollectionRule,
  undeclaredCollectionRule,
  callableTenantCheckRule,
};
