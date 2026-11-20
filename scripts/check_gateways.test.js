'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  RULES,
  checkSource,
  checkRepo,
  checkRepoDetailed,
  applyBaseline,
  lowerBaseline,
  serverConfigClientRules,
  serverConfigAsClientValueRule,
  rawCollectionRule,
  undeclaredCollectionRule,
} = require('./check_gateways');

const signOut = RULES.find((r) => r.id === 'sign-out');
const firestore = RULES.find((r) => r.id === 'firestore-instance');

test('flags a raw FirebaseAuth signOut outside the gateway', () => {
  const v = checkSource(signOut, 'lib/x.dart', 'a();\n    await fire_auth.FirebaseAuth.instance.signOut();\n');
  assert.equal(v.length, 1);
  assert.equal(v[0].line, 2);
});

test('allows the gateway file, comments, and explicit exemptions', () => {
  const src = 'await FirebaseAuth.instance.signOut();';
  assert.deepEqual(checkSource(signOut, signOut.allowed[0], src), []);
  assert.deepEqual(checkSource(signOut, 'lib/x.dart', `// ${src}`), []);
  assert.deepEqual(checkSource(signOut, 'lib/x.dart', `// gateway-exempt: sign-out test fixture\n${src}`), []);
  assert.deepEqual(checkSource(signOut, 'lib/x.dart', `${src} // gateway-exempt: sign-out reason`), []);
  assert.equal(checkSource(signOut, 'lib/x.dart', `// gateway-exempt: other-rule\n${src}`).length, 1);
});

test('does not flag unrelated signOut calls', () => {
  assert.deepEqual(checkSource(signOut, 'lib/x.dart', 'await GoogleSignIn().signOut();'), []);
});

const builders = RULES.find((r) => r.id === 'functions-builders');
const http = RULES.find((r) => r.id === 'functions-http');
const bigquery = RULES.find((r) => r.id === 'functions-bigquery');

test('functions must build triggers through _metered_functions', () => {
  for (const src of [
    "const { onCall, HttpsError } = require('firebase-functions/v2/https');",
    "const functions = require('firebase-functions');",
    'const { onSchedule } = require("firebase-functions/v2/scheduler");',
    "const functions = require('firebase-functions/v1');",
  ]) {
    assert.equal(checkSource(builders, 'functions/notes.js', src).length, 1, src);
  }
  // Helpers too: HttpsError comes from the gateway like everything else.
  assert.equal(checkSource(builders, 'functions/_shared.js', "require('firebase-functions/v2/https')").length, 1);
});

test('functions may use logger/params directly; the gateway, tests and scripts are exempt', () => {
  const src = "const { onCall } = require('firebase-functions/v2/https');";
  assert.deepEqual(checkSource(builders, 'functions/x.js', "const logger = require('firebase-functions/logger');"), []);
  assert.deepEqual(checkSource(builders, 'functions/x.js', "const { defineSecret } = require('firebase-functions/params');"), []);
  assert.deepEqual(checkSource(builders, 'functions/_metered_functions.js', src), []);
  assert.deepEqual(checkSource(builders, 'functions/notes.test.js', src), []);
  assert.deepEqual(checkSource(builders, 'functions/test/notes.test.js', src), []);
  assert.deepEqual(checkSource(builders, 'functions/scripts/sync.js', src), []);
});

test('external HTTP and BigQuery go through their gateways', () => {
  assert.equal(checkSource(http, 'functions/x.js', "const axios = require('axios');").length, 1);
  assert.equal(checkSource(http, 'functions/x.js', 'const r = await fetch(url);').length, 1);
  assert.deepEqual(checkSource(http, 'functions/x.js', 'await externalHttp.fetch(url);'), []);
  assert.deepEqual(checkSource(http, 'functions/x.js', 'const r = await prefetch(url);'), []);
  assert.deepEqual(checkSource(http, 'functions/_external_http.js', "require('axios')"), []);
  assert.equal(checkSource(bigquery, 'functions/x.js', "const { BigQuery } = require('@google-cloud/bigquery');").length, 1);
  assert.deepEqual(checkSource(bigquery, 'functions/_warehouse_bigquery_client.js', "require('@google-cloud/bigquery')"), []);
});

test('functions use the metered admin.firestore() instance only', () => {
  const fs = RULES.find((r) => r.id === 'functions-firestore-instance');
  for (const src of [
    "const { Firestore } = require('@google-cloud/firestore');",
    "const db = getFirestore(app, 'other');",
    'const db = new Firestore({ projectId });',
    'const db = admin.firestore(otherApp);',
    'const db = otherAdmin.firestore(app2);',
    "const db = admin.app('reports').firestore();",
    "const db = admin\n  .app('reports')\n  .firestore();",
    "admin.initializeApp({ projectId: 'x' }, 'second');",
    "admin.initializeApp(undefined, 'second');",
    'const db = apps[1].firestore(x);',
  ]) {
    assert.equal(checkSource(fs, 'functions/x.js', src).length, 1, src);
  }
  for (const src of [
    'const db = admin.firestore();',
    "const { AggregateField, FieldValue } = require('firebase-admin/firestore');",
    'admin.firestore.FieldValue.serverTimestamp();',
    'resolve: TARGETS.firestoreTrigger(appConfig),',
    'if (!admin.apps.length) admin.initializeApp();',
    'const db = admin.firestore ();',
  ]) {
    assert.deepEqual(checkSource(fs, 'functions/x.js', src), [], src);
  }
  assert.deepEqual(checkSource(fs, 'functions/_firestore_metering.js', "require('@google-cloud/firestore')"), []);
});

test('vendor SDKs stay behind their metered gateways', () => {
  const stripe = RULES.find((r) => r.id === 'functions-stripe');
  const messaging = RULES.find((r) => r.id === 'functions-messaging-sdk');
  assert.equal(checkSource(stripe, 'functions/payments.js', "const s = require('stripe')(key);").length, 1);
  assert.deepEqual(checkSource(stripe, 'functions/_stripe.js', "const Stripe = require('stripe');"), []);
  assert.equal(checkSource(messaging, 'functions/x.js', "const nodemailer = require('nodemailer');").length, 1);
  assert.equal(checkSource(messaging, 'functions/x.js', "const twilio = require('twilio');").length, 1);
  assert.deepEqual(checkSource(messaging, 'functions/_shared.js', "const nodemailer = require('nodemailer');"), []);
});

test('Stripe webhooks are verified only by the shared verifier', () => {
  const webhook = RULES.find((r) => r.id === 'functions-stripe-webhook');
  const flagged = [
    'event = stripe.webhooks.constructEvent(req.rawBody, sig, secret);',
    'const event = await stripe.webhooks.constructEventAsync(body, sig, secret);',
    "const sig = req.headers['stripe-signature'];",
    'const sig = req.get("Stripe-Signature");',
    "const { stripeWebhooks } = require('./_stripe'); stripeWebhooks().constructEvent(a, b, c);",
    'const w = stripeWebhooks();',
  ];
  for (const line of flagged) {
    assert.equal(checkSource(webhook, 'functions/payments.js', line).length, 1, line);
  }
  assert.deepEqual(
    checkSource(webhook, 'functions/_stripe_webhook.js', "deps.webhooks().constructEvent(raw, headerValue(req, 'stripe-signature'), secret);"),
    [],
  );
  // _stripe.js may define (not call) the helper; the definition isn't a use.
  assert.deepEqual(checkSource(webhook, 'functions/_stripe.js', 'function stripeWebhooks() {'), []);
  assert.deepEqual(checkSource(webhook, 'functions/payments.js', "exports.x = onRequest(stripeWebhookHandler({ secretName: 'stripe_webhook_secret' }));"), []);
});

test('money moves only through the payments core', () => {
  const create = RULES.find((r) => r.id === 'stripe-payment-intent-create');
  const account = RULES.find((r) => r.id === 'stripe-connected-account');
  const confirm = RULES.find((r) => r.id === 'stripe-client-confirm');

  assert.equal(checkSource(create, 'functions/rented_dwelling.js', 'const pi = await stripe.paymentIntents.create({ amount });').length, 1);
  assert.equal(checkSource(create, 'functions/x.js', 'await stripe.paymentIntents\n  .create(params)').length, 1);
  assert.deepEqual(checkSource(create, 'functions/_payments.js', 'pi = await stripe.paymentIntents.create(params, opts);'), []);
  // No exemption for the platform's own billing any more: invoices are paid through the core.
  assert.equal(checkSource(create, 'functions/payments.js', 'await stripe.paymentIntents.create(params);').length, 1);
  assert.equal(checkSource(create, 'functions/_platform_invoicing.js', 'await stripe.paymentIntents.create({ off_session: true });').length, 1);
  assert.deepEqual(checkSource(create, 'functions/x.js', 'await stripe.paymentIntents.retrieve(id);'), []);

  for (const line of [
    'await stripe.refunds.create({ charge }, { stripeAccount: acct });',
    "headers['Stripe-Account'] = acct;",
    "fetch(url, { headers: { 'stripe-account': acct } });",
  ]) {
    assert.equal(checkSource(account, 'functions/x.js', line).length, 1, line);
  }
  assert.deepEqual(checkSource(account, 'functions/_payments.js', 'return { stripeAccount: order.account };'), []);
  assert.deepEqual(checkSource(account, 'functions/x.js', 'tx.set(ref, { stripeAccountId: id });'), []);

  for (const line of [
    'await Stripe.instance.confirmPayment(paymentIntentClientSecret: s);',
    'await Stripe.instance\n    .handleNextAction(s);',
    "Stripe.stripeAccountId = 'acct_x';",
    'await Stripe.instance.presentPaymentSheet();',
  ]) {
    assert.equal(checkSource(confirm, 'packages/some_app/lib/pay.dart', line).length, 1, line);
  }
  assert.deepEqual(
    checkSource(confirm, 'packages/shared_services/lib/payments/stripe_payment_checkout.dart', 'await Stripe.instance.confirmPayment(paymentIntentClientSecret: s);'),
    [],
  );
  assert.deepEqual(checkSource(confirm, 'packages/payments/lib/x.dart', 'await Stripe.instance.createPaymentMethod(params: p);'), []);
});

const storageInstance = RULES.find((r) => r.id === 'storage-instance');
const storagePut = RULES.find((r) => r.id === 'storage-put');

test('Storage is only reachable through the Dart Storage gateway files', () => {
  const raw = "final ref = FirebaseStorage.instance.ref('x');";
  assert.equal(checkSource(storageInstance, 'packages/app/lib/a.dart', raw).length, 1);
  assert.equal(checkSource(storageInstance, 'lib/a.dart', 'FirebaseStorage.instanceFor(bucket: b)').length, 1);
  assert.deepEqual(checkSource(storageInstance, 'packages/shared_services/lib/scoped_storage.dart', raw), []);
  // Only the gateway files themselves, not the rest of shared_services.
  assert.equal(checkSource(storageInstance, 'packages/shared_services/lib/other_service.dart', raw).length, 1);
});

test('raw uploads are flagged outside the Storage gateway files', () => {
  assert.equal(checkSource(storagePut, 'packages/a/lib/a.dart', 'await ref.putData(bytes, meta);').length, 1);
  assert.equal(checkSource(storagePut, 'packages/a/lib/a.dart', 'ref.putFile(file)').length, 1);
  assert.deepEqual(checkSource(storagePut, 'packages/a/lib/a.dart', 'await _files.putBytes(ref, bytes);'), []);
  assert.deepEqual(checkSource(storagePut, 'packages/shared_services/lib/platform_service_web.dart', 'ref.putData(b, m)'), []);
  assert.equal(checkSource(storagePut, 'packages/shared_services/lib/usage_meter.dart', 'ref.putData(b, m)').length, 1);
});

test('clients may not upload to or address a Storage prefix that grants them nothing', () => {
  const closed = RULES.find((r) => r.id === 'storage-closed-prefix');
  const at = 'packages/a/lib/a.dart';
  for (const bad of [
    "ScopedStorage.platform(root: 'gallery_photos', appId: 'art-gallery')",
    "ScopedStorage.platform(\n  appId: 'x',\n  root: 'users/$uid',\n)",
    "ScopedStorage.platform(root: 'app_icons_thumbs', appId: 'app-manager')",
    "ScopedStorage.refForPath('wood_shop/a.jpg')",
    "ScopedStorage.refForPath('naic_sight/$uid/$job/in.csv')",
  ]) assert.equal(checkSource(closed, at, bad).length, 1, bad);
  for (const ok of [
    "ScopedStorage.platform(root: 'profile_pictures', appId: 'me')",
    "ScopedStorage.platform(root: 'app_icons', appId: 'app-manager')",
    "ScopedStorage.platform(root: 'groups/$groupId', appId: 'groups', groupId: groupId)",
    "ScopedStorage(folder: 'gallery_photos', appId: APP_ID)",
    'ScopedStorage.refForPath(document.storagePath)',
    "ScopedStorage.refForPath('published/g/a/x')",
  ]) assert.deepEqual(checkSource(closed, at, ok), [], ok);
});

const aiDart = RULES.find((r) => r.id === 'ai-sdk-dart');
const geminiKey = RULES.find((r) => r.id === 'server-config-in-client' && r.pattern.test("'gemini_api_key'"));
const aiServer = RULES.find((r) => r.id === 'ai-sdk-server');

test('flags client-side Gemini SDK use outside the AI gateway', () => {
  assert.equal(checkSource(aiDart, 'packages/x/lib/a.dart', "import 'package:google_generative_ai/google_generative_ai.dart';").length, 1);
  assert.equal(checkSource(aiDart, 'packages/x/lib/a.dart', "final m = GenerativeModel(model: 'gemini-2.5-flash', apiKey: k);").length, 1);
  assert.deepEqual(checkSource(aiDart, 'packages/x/lib/a.dart', "final m = AiModel(appId: APP_ID, model: 'gemini-2.5-flash');"), []);
  assert.deepEqual(checkSource(aiDart, 'packages/x/lib/a.dart', 'class MyGenerativeModelView {}'), []);
  assert.deepEqual(checkSource(aiDart, aiDart.allowed[0], 'GenerativeModel('), []);
  for (const line of [
    "import 'package:firebase_ai/firebase_ai.dart';",
    "import 'package:firebase_vertexai/firebase_vertexai.dart';",
    "final url = 'https://generativelanguage.googleapis.com/v1beta/models/x:generateContent';",
    "final url = Uri.https('us-central1-aiplatform.googleapis.com', '/v1/projects');",
  ]) {
    assert.equal(checkSource(aiDart, 'packages/x/lib/a.dart', line).length, 1, line);
  }
  assert.deepEqual(checkSource(aiDart, 'packages/x/lib/a.dart', "import 'package:firebase_auth/firebase_auth.dart';"), []);
});

test('flags client reads of the Gemini API key', () => {
  assert.deepEqual(geminiKey.allowed, [], 'no device may read the Gemini key');
  assert.equal(checkSource(geminiKey, 'packages/x/lib/a.dart', "rc.getString('gemini_api_key');").length, 1);
  assert.equal(checkSource(geminiKey, 'lib/a.dart', 'rc.getString("gemini_api_key");').length, 1);
  assert.deepEqual(checkSource(geminiKey, 'lib/a.dart', "rc.getString('youtube_api_key');"), []);
});

test('flags direct Google Places calls and client reads of the Places keys', () => {
  const places = RULES.find((r) => r.id === 'places-direct');
  assert.deepEqual(places.allowed, [], 'every client goes through googlePlacesProxy');
  for (const line of [
    "static const _apiBase = 'https://maps.googleapis.com/maps/api/place';",
    "final u = 'https://maps.googleapis.com/maps/api/place/details/json';",
    "final u = 'https://maps.googleapis.com/maps/api/geocode/json';",
    "final u = Uri.https('places.googleapis.com', '/v1/places:autocomplete');",
    "rc.getString('google_places_api_key');",
  ]) {
    assert.equal(checkSource(places, 'packages/x/lib/a.dart', line).length, 1, line);
  }
  assert.deepEqual(checkSource(places, 'packages/x/lib/a.dart', "GooglePlacesClient.proxyUri('details', {});"), []);
  assert.deepEqual(checkSource(places, 'packages/x/lib/a.dart', "rc.getString('google_places_proxy_url');"), []);
  // Server code is out of scope: googlePlacesProxy is the one caller.
  assert.ok(!places.files.roots.includes('functions'));

  const proxyUrl = RULES.find((r) => r.id === 'places-proxy-url');
  assert.equal(
    checkSource(proxyUrl, 'packages/x/lib/a.dart', "const u = 'https://us-central1-bluejay-d926f.cloudfunctions.net/googlePlacesProxy';").length,
    1,
  );
  for (const line of [
    "final u = BluejayFunctions.functionUri('googlePlacesProxy');",
    "const u = '$kFunctionsBaseUrl/googlePlacesProxy';",
  ]) {
    assert.equal(checkSource(proxyUrl, 'packages/x/lib/a.dart', line).length, 1, line);
  }
  assert.deepEqual(checkSource(proxyUrl, proxyUrl.allowed[0], "static const defaultProxyUrl = '.../googlePlacesProxy';"), []);
  assert.deepEqual(checkSource(proxyUrl, 'packages/x/lib/a.dart', '/// via the `googlePlacesProxy` Cloud Function'), []);

  const serverKey = RULES.find(
    (r) => r.id === 'server-config-in-client' && r.pattern.test("'google_places_server_api_key'"),
  );
  assert.ok(serverKey, 'google_places_server_api_key is a registered server parameter');
  assert.equal(checkSource(serverKey, 'lib/a.dart', "rc.getString('google_places_server_api_key');").length, 1);
});

test('client code reaches Cloud Functions only through the Dart gateway', () => {
  const rule = RULES.find((r) => r.id === 'cloud-functions-client');
  for (const line of [
    'final f = FirebaseFunctions.instance;',
    "final f = FirebaseFunctions.instanceFor(region: 'us-central1');",
    'final f = FirebaseFunctions\n    .instance\n    .httpsCallable(name);',
    "const url = 'https://us-central1-bluejay-d926f.cloudfunctions.net/x';",
    "Uri.https('$region-$project.cloudfunctions.net', 'x');",
  ]) {
    assert.equal(checkSource(rule, 'packages/x/lib/a.dart', line).length, 1, line);
  }
  for (const line of [
    'final f = BluejayFunctions.instance;',
    'FirebaseFunctions? functions,',
    "} on FirebaseFunctionsException catch (e) {",
    '/// See https://us-central1-p.cloudfunctions.net/x',
  ]) {
    assert.deepEqual(checkSource(rule, 'packages/x/lib/a.dart', line), [], line);
  }
  assert.deepEqual(checkSource(rule, rule.allowed[0], 'FirebaseFunctions.instanceFor(region: kFunctionsRegion);'), []);
});

test('deployed functions code names no region outside _function_regions.js', () => {
  const rule = RULES.find((r) => r.id === 'functions-region-literal');
  for (const line of [
    "const REGION = 'us-central1';",
    'onCall({ region: "northamerica-northeast2" }, h);',
    'const url = `https://us-central1-${project}.cloudfunctions.net/x`;',
    "const q = 'locations/europe-west1/functions/x';",
  ]) {
    assert.equal(checkSource(rule, 'functions/x.js', line).length, 1, line);
  }
  for (const line of [
    "const host = 'email-smtp.us-east-2.amazonaws.com';",
    '// runs in us-central1 today',
    " * northamerica-northeast2 (Toronto)",
  ]) {
    assert.deepEqual(checkSource(rule, 'functions/x.js', line), [], line);
  }
  assert.deepEqual(checkSource(rule, 'functions/_function_regions.js', "const LEGACY_REGION = 'us-central1';"), []);
  assert.deepEqual(checkSource(rule, 'functions/scripts/x.js', "const r = 'us-central1';"), []);
  assert.deepEqual(checkSource(rule, 'functions/x.test.js', "const r = 'us-central1';"), []);
});

test('deployed functions code names no default runtime service account outside _function_identity.js', () => {
  const rule = RULES.find((r) => r.id === 'functions-service-account-literal');
  for (const line of [
    "functions.runWith({ serviceAccount: 'bluejay-d926f@appspot.gserviceaccount.com' })",
    'onRequest({ serviceAccount: `${project}@appspot.gserviceaccount.com` }, h);',
    "const sa = '691184172506-compute@developer.gserviceaccount.com';",
  ]) {
    assert.equal(checkSource(rule, 'functions/x.js', line).length, 1, line);
  }
  for (const line of [
    "onRequest({ ...appEngineIdentity(), memory: '256MiB' }, h);",
    "const to = 'someone@bluejay.gg';",
  ]) {
    assert.deepEqual(checkSource(rule, 'functions/x.js', line), [], line);
  }
  assert.deepEqual(checkSource(rule, 'functions/_function_identity.js',
    'return `${projectId}@appspot.gserviceaccount.com`;'), []);
  assert.deepEqual(checkSource(rule, 'functions/x.test.js', "const sa = 'p@appspot.gserviceaccount.com';"), []);
});

test('flags server-side Gemini SDK construction outside functions/_ai.js', () => {
  assert.equal(checkSource(aiServer, 'functions/x.js', "const { GoogleGenerativeAI } = require('@google/generative-ai');").length, 1);
  assert.equal(checkSource(aiServer, 'functions/x.js', 'const genAI = new GoogleGenerativeAI(apiKey);').length, 1);
  assert.deepEqual(checkSource(aiServer, 'functions/_ai.js', "require('@google/generative-ai'); new GoogleGenerativeAI(k);"), []);
  assert.deepEqual(checkSource(aiServer, 'functions/x.js', "const { generate } = require('./_ai');"), []);
  assert.deepEqual(checkSource(aiServer, 'functions/x.test.js', "if (request === '@google/generative-ai') {"), []);
});

const remoteConfigTemplate = RULES.find((r) => r.id === 'remote-config-template');

test('functions read Remote Config only through _server_config.js', () => {
  for (const src of [
    'const template = await admin.remoteConfig().getTemplate();',
    'const t = await rc.getServerTemplate();',
    "const key = template.parameters['stripe_secret_key']?.defaultValue?.value?.trim();",
    "const v = params['x'].defaultValue.value;",
  ]) {
    assert.equal(checkSource(remoteConfigTemplate, 'functions/payments.js', src).length, 1, src);
  }
  const src = 'const template = await admin.remoteConfig().getTemplate();';
  assert.deepEqual(checkSource(remoteConfigTemplate, 'functions/_server_config.js', src), []);
  assert.deepEqual(checkSource(remoteConfigTemplate, 'functions/scripts/migrate_server_secrets.js', src), []);
  assert.deepEqual(checkSource(remoteConfigTemplate, 'functions/payments.test.js', src), []);
  assert.deepEqual(
    checkSource(remoteConfigTemplate, 'functions/x.js', "const key = await readServerSecret('stripe_secret_key');"),
    [],
  );
});

test('client code may not name a server-only parameter', () => {
  const rules = serverConfigClientRules({
    stripe_secret_key: { kind: 'secret' },
    // A leftover legacyClientReaders entry no longer exempts anything.
    gemini_api_key: { kind: 'secret', legacyClientReaders: ['packages/ai/lib/a.dart'] },
  });
  const check = (rel, src) => rules.flatMap((rule) => checkSource(rule, rel, src));
  assert.equal(check('packages/x/lib/a.dart', "rc.getString('stripe_secret_key');").length, 1);
  assert.equal(check('lib/a.dart', 'rc.getString("stripe_secret_key");').length, 1);
  assert.equal(check('web/index.html', 'getValue(rc, `stripe_secret_key`)').length, 1);
  assert.deepEqual(check('packages/x/lib/a.dart', "rc.getString('stripe_publishable_key');"), []);
  assert.deepEqual(check('packages/x/lib/a.dart', "rc.getString('stripe_secret_key_hint');"), []);
  assert.deepEqual(check('packages/x/lib/a.dart', "/// never read 'stripe_secret_key' here"), []);
  assert.equal(check('packages/ai/lib/a.dart', "rc.getString('gemini_api_key');").length, 1);
  assert.equal(check('packages/other/lib/a.dart', "rc.getString('gemini_api_key');").length, 1);
});

test('functions may not read a server-only parameter from the client template', () => {
  const rule = serverConfigAsClientValueRule({ google_places_server_api_key: {}, exchange_api_key: {} });
  assert.equal(checkSource(rule, 'functions/insure_me.js', "await readClientConfigValue('google_places_server_api_key')").length, 1);
  assert.equal(checkSource(rule, 'functions/x.js', 'readClientConfigValue(\n  "exchange_api_key")').length, 1);
  assert.deepEqual(checkSource(rule, 'functions/x.js', "readClientConfigValue('ai_model_lite')"), []);
  assert.deepEqual(checkSource(rule, 'functions/x.js', "readServerSecret('google_places_server_api_key')"), []);
  assert.deepEqual(checkSource(rule, 'functions/x.test.js', "readClientConfigValue('exchange_api_key')"), []);
  // The real rule covers every name in the shared table.
  const real = RULES.find((r) => r.id === 'server-config-as-client-value');
  assert.equal(checkSource(real, 'functions/x.js', "readClientConfigValue('stripe_secret_key')").length, 1);
});

test('nothing reads the server Remote Config template, not even _server_config.js', () => {
  const rule = RULES.find((r) => r.id === 'remote-config-server-template');
  for (const file of ['functions/_server_config.js', 'functions/payments.js']) {
    assert.equal(checkSource(rule, file, 'const t = await rc.getServerTemplate();').length, 1, file);
    assert.equal(checkSource(rule, file, 'const t = await rc.initServerTemplate({});').length, 1, file);
  }
  assert.deepEqual(checkSource(rule, 'functions/_server_config.test.js', 'getServerTemplate: async () => {}'), []);
});

test('every server-only parameter in the shared table has a client rule', () => {
  const { SERVER_CONFIG_PARAMETERS } = require('../functions/_server_config_parameters');
  const clientRules = RULES.filter((r) => r.id === 'server-config-in-client');
  assert.equal(clientRules.length, Object.keys(SERVER_CONFIG_PARAMETERS).length);
  for (const name of Object.keys(SERVER_CONFIG_PARAMETERS)) {
    assert.ok(clientRules.some((r) => r.pattern.test(`'${name}'`)), name);
  }
});

test('the repository currently passes', () => {
  assert.deepEqual(checkRepo(), []);
});

// -----------------------------------------------------------------------------
// Ratchet (baseline) rules
// -----------------------------------------------------------------------------

function occurrences(rule, file, n) {
  const src = Array.from({ length: n }, () => 'final db = FirebaseFirestore.instance;').join('\n');
  return new Map([[file, checkSource(rule, file, src)]]);
}

test('firestore-instance flags instance and instanceFor, not the gateways', () => {
  assert.equal(checkSource(firestore, 'lib/x.dart', 'final d = FirebaseFirestore.instance;').length, 1);
  assert.equal(checkSource(firestore, 'lib/x.dart', 'FirebaseFirestore.instanceFor(app: a);').length, 1);
  assert.equal(checkSource(firestore, 'lib/x.dart', 'BluejayFirestore.forApp(APP_ID);').length, 0);
  assert.equal(checkSource(firestore, 'lib/x.dart', '/// Like FirebaseFirestore.instance, but metered.').length, 0);
  assert.equal(checkSource(firestore, 'lib/x.dart', 'a(); // not FirebaseFirestore.instance').length, 0);
  for (const gateway of firestore.allowed) {
    assert.deepEqual(checkSource(firestore, gateway, 'FirebaseFirestore.instance;'), []);
  }
});

test('matches calls dart-format split across lines, reported at their first line', () => {
  const src = 'a();\nfinal d = FirebaseFirestore\n    .instance\n    .collection("x");\nb();\nFirebaseFirestore.\n  instanceFor(app: a);\n';
  const v = checkSource(firestore, 'lib/x.dart', src);
  assert.deepEqual(v.map((x) => x.line), [2, 6]);
  assert.equal(v[0].text, 'final d = FirebaseFirestore');

  const signOutSplit = 'await FirebaseAuth.instance\n    .signOut();';
  assert.equal(checkSource(signOut, 'lib/x.dart', signOutSplit).length, 1);
});

test('reports a line once however many matches it has, and ignores // inside strings', () => {
  const v = checkSource(firestore, 'lib/x.dart', 'f(FirebaseFirestore.instance, FirebaseFirestore.instance);');
  assert.equal(v.length, 1);
  const url = "final u = 'https://x'; FirebaseFirestore.instance;";
  assert.equal(checkSource(firestore, 'lib/x.dart', url).length, 1);
});

test('an exemption on any line of a split match, or the line before, applies', () => {
  const split = 'FirebaseFirestore // gateway-exempt: firestore-instance test\n  .instance;';
  assert.equal(checkSource(firestore, 'lib/x.dart', split).length, 0);
  const before = '// gateway-exempt: firestore-instance test\nFirebaseFirestore\n  .instance;';
  assert.equal(checkSource(firestore, 'lib/x.dart', before).length, 0);
});

test('ratchet: a file at its baseline passes, over it fails', () => {
  const at = applyBaseline(firestore, occurrences(firestore, 'lib/a.dart', 2), { 'lib/a.dart': 2 });
  assert.deepEqual(at, { violations: [], improved: [] });

  const over = applyBaseline(firestore, occurrences(firestore, 'lib/a.dart', 3), { 'lib/a.dart': 2 });
  assert.equal(over.violations.length, 3);
  assert.match(over.violations[0].message, /at most 2/);

  const newFile = applyBaseline(firestore, occurrences(firestore, 'lib/new.dart', 1), { 'lib/a.dart': 2 });
  assert.equal(newFile.violations.length, 2); // the new file, and a.dart now under its baseline

  const noBaseline = applyBaseline(firestore, occurrences(firestore, 'lib/a.dart', 1), undefined);
  assert.equal(noBaseline.violations.length, 1);
});

test('ratchet: a file under its baseline fails until the baseline is lowered', () => {
  const fewer = applyBaseline(firestore, occurrences(firestore, 'lib/a.dart', 1), {
    'lib/a.dart': 2,
    'lib/gone.dart': 1,
  });
  assert.deepEqual(
    fewer.violations.map((v) => `${v.file}: ${v.text}`).sort(),
    ['lib/a.dart: baseline allows 2, found 1', 'lib/gone.dart: baseline allows 1, found 0'],
  );
  assert.match(fewer.violations[0].message, /--update-baseline/);
  assert.deepEqual(
    fewer.improved.map((i) => `${i.file}:${i.from}->${i.to}`).sort(),
    ['lib/a.dart:2->1', 'lib/gone.dart:1->0'],
  );

  const { baseline } = lowerBaseline({ [firestore.id]: { 'lib/a.dart': 2, 'lib/gone.dart': 1 } }, {
    [firestore.id]: { 'lib/a.dart': 1 },
  });
  const after = applyBaseline(firestore, occurrences(firestore, 'lib/a.dart', 1), baseline[firestore.id]);
  assert.deepEqual(after.violations, []);
});

test('lowerBaseline only ever lowers counts', () => {
  const { baseline, refused } = lowerBaseline(
    { r: { 'a.dart': 3, 'b.dart': 1, 'c.dart': 2 } },
    { r: { 'a.dart': 1, 'c.dart': 5, 'new.dart': 1 } },
  );
  assert.deepEqual(baseline, { r: { 'a.dart': 1, 'c.dart': 2 } });
  assert.deepEqual(refused.map((r) => r.file).sort(), ['c.dart', 'new.dart']);
});

test('only ratchet rules consult the baseline', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gateways-'));
  try {
    fs.mkdirSync(path.join(dir, 'lib'));
    fs.writeFileSync(path.join(dir, 'lib', 'x.dart'), 'FirebaseAuth.instance.signOut();\nFirebaseFirestore.instance;\n');
    const { violations, counts } = checkRepoDetailed(dir, RULES, {
      'sign-out': { 'lib/x.dart': 5 },
      'firestore-instance': { 'lib/x.dart': 1 },
    });
    assert.deepEqual(violations.map((v) => v.rule), ['sign-out']);
    assert.deepEqual(counts['firestore-instance'], { 'lib/x.dart': 1 });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the committed baseline covers every ratchet rule', () => {
  const { counts } = checkRepoDetailed();
  const baseline = JSON.parse(fs.readFileSync(path.join(__dirname, 'check_gateways_baseline.json'), 'utf8'));
  for (const id of Object.keys(counts)) assert.ok(baseline[id], `missing baseline for ${id}`);
});

test('a pattern that consumes a leading boundary character reports the right line', () => {
  const http = RULES.find((r) => r.id === 'functions-http');
  const src = "const a = 1; // fetch( in a comment\nfetch('https://x');\n  await fetch(url);\nclient.fetch(url);\n";
  assert.deepEqual(checkSource(http, 'functions/x.js', src).map((v) => v.line), [2, 3]);
});

test('invoices and billing events: clients only read them, through read-only accessors', () => {
  const fs = require('fs');
  const collections = RULES.find((r) => r.id === 'platform-billing-collections');
  const readOnly = RULES.find((r) => r.id === 'platform-billing-read-only');
  for (const line of [
    "final _inv = ScopedCollection(collection: 'invoices', appId: APP_ID);",
    "ScopedCollection(\n  collection: 'billing_events',\n  appId: APP_ID,\n)",
    "await BluejayFirestore.forApp(APP_ID).collection('invoices').doc(id).update({'status': 'paid'});",
    "FirebaseFirestore.instance\n    .collection('billing_events')\n    .add(event);",
  ]) {
    assert.equal(checkSource(collections, 'packages/some_app/lib/pay.dart', line).length, 1, line);
  }
  // budgie_ting's own invoices subcollection is a different collection.
  assert.deepEqual(checkSource(collections, 'packages/budgie_ting/lib/x.dart',
    "FirebaseFirestore.instance.collection('budgie_ting').doc(uid).collection('invoices')"), []);
  assert.deepEqual(checkSource(collections, 'packages/payments/lib/services/invoice_service.dart',
    "BluejayFirestore.forApp(APP_ID).collection('invoices').where('userId', isEqualTo: uid)"), []);

  for (const line of [
    'await _invoices.doc(invoiceId).update(updates);',
    "batch.update(_billingEventsSvc.doc(eventId), {'status': 'cancelled'});",
    'final batch = BluejayFirestore.forApp(APP_ID).batch();',
    'await doc.reference.delete();',
    'await db.runTransaction((tx) async {});',
    "await _ref.collection('billing_events').add(map);",
  ]) {
    assert.equal(checkSource(readOnly, 'packages/payments/lib/services/billing_service.dart', line).length, 1, line);
  }
  for (const line of ['sampleIds.add(doc.id);', "final snap = await _invoices.where('userId', isEqualTo: uid).get();"]) {
    assert.deepEqual(checkSource(readOnly, 'packages/payments/lib/services/billing_service.dart', line), [], line);
  }
  // The read-only rule scans exactly the reader files, which must exist (or it scans nothing).
  assert.deepEqual(collections.allowed, readOnly.files.roots);
  for (const file of readOnly.files.roots) assert.ok(fs.existsSync(require('path').join(__dirname, '..', file)), file);
});

test('access-index-read: server code reads the index only through getAccessIndex', () => {
  const rule = RULES.find((r) => r.id === 'access-index-read');
  assert.equal(checkSource(rule, 'functions/x.js', "db.collection('users').doc(uid).collection('metadata').doc('access_index').get()").length, 1);
  assert.equal(checkSource(rule, 'functions/x.js', 'db.doc(`users/${uid}/metadata/access_index`).get()').length, 1);
  assert.equal(checkSource(rule, 'functions/x.js', "x.collection('metadata')\n  .doc( 'access_index' )\n  .get()").length, 1);
  assert.deepEqual(checkSource(rule, 'functions/_shared.js', ".doc('access_index')"), []);
  assert.deepEqual(checkSource(rule, 'functions/x.js', 'const index = await getAccessIndex(uid);'), []);
});

test('storage-object-path: non-literal bucket.file paths go through _storage_paths.js', () => {
  const rule = RULES.find((r) => r.id === 'storage-object-path');
  assert.equal(checkSource(rule, 'functions/x.js', 'await bucket.file(doc.storagePath).delete();').length, 1);
  assert.equal(checkSource(rule, 'functions/x.js', 'admin.storage().bucket().file(`groups/${g}/x`)').length, 1);
  assert.equal(checkSource(rule, 'functions/x.js', 'bucket\n  .file(path)\n  .download()').length, 1);
  assert.deepEqual(checkSource(rule, 'functions/x.js', "bucket.file('constant/path.json')"), []);
  assert.deepEqual(checkSource(rule, 'functions/_storage_paths.js', 'bucket.file(checked)'), []);
  assert.deepEqual(checkSource(rule, 'functions/x.js', '// gateway-exempt: storage-object-path built here\nbucket.file(p)'), []);
  assert.deepEqual(checkSource(rule, 'functions/x.test.js', 'bucket.file(p)'), []);
});

test('callable-tenant-check: an endpoint reading a request groupId with no tenant check is flagged', () => {
  const rule = RULES.find((r) => r.id === 'callable-tenant-check');
  assert.equal(rule.ratchet, true);
  const unchecked = 'exports.x = onCall(async (request) => {\n  const groupId = request.data?.groupId;\n  return db.doc(groupId).get();\n});';
  const found = checkSource(rule, 'functions/x.js', unchecked);
  assert.equal(found.length, 1);
  assert.equal(found[0].line, 1);
  assert.match(found[0].text, /^x: reads groupId/);
  const checked = unchecked.replace('  return', "  await requireGroupEntitlement({ uid, groupId, appId: 'a', where: 'x' });\n  return");
  assert.deepEqual(checkSource(rule, 'functions/x.js', checked), []);
  assert.deepEqual(checkSource(rule, 'functions/x.js', '// gateway-exempt: callable-tenant-check platform admins only\n' + unchecked), []);
  assert.deepEqual(checkSource(rule, 'functions/x.test.js', unchecked), []);
  assert.deepEqual(checkSource(rule, 'functions/_tenant_access.js', unchecked), []);
});

const scopeLiteral = RULES.find((r) => r.id === 'entitlement-scope-literal-app-id');

test('entitlement scopes must be keyed by APP_ID, not a hand-typed app id', () => {
  for (const src of [
    "entitlements.contains('$groupId:rented_dwelling:admin')",
    "entitlements.contains('${groupId}:insurance_coc:edit')",
    "final scope = '$activeGroupId:billing';",
  ]) {
    assert.equal(checkSource(scopeLiteral, 'packages/x/lib/x_access.dart', src).length, 1, src);
  }
  for (const src of [
    "entitlements.contains('$groupId:$APP_ID:admin')",
    "final scope = '$groupId:$appId';",
    "'${_scope(groupId, appId)}:admin'",
  ]) {
    assert.deepEqual(checkSource(scopeLiteral, 'packages/x/lib/x_access.dart', src), [], src);
  }
  // Tests may spell out the scopes they feed in.
  assert.deepEqual(
    checkSource(scopeLiteral, 'packages/x/test/x_test.dart', "['$groupId:rented-dwelling:admin']"),
    [],
  );
});

test('raw-collection: raw .collection() of a tenant collection is flagged, pass-through kinds are not', () => {
  const rule = rawCollectionRule({
    collections: {
      payment_orders: { kind: 'server' },
      users: { kind: 'personal' },
      notes: { apps: ['notes'] },
      vendor_market_threads: { serverWritten: true },
    },
  });
  const file = 'packages/x/lib/x.dart';
  for (const src of [
    "db.collection('notes').doc(id).get();",
    "BluejayFirestore.forApp(APP_ID)\n    .collection(\n      'whiteboards')",
    "ref.doc(id).collection('strokes')",
    // serverWritten is still the tenant kind: reads need the tenant filter.
    "db.collection('vendor_market_threads')",
    // A name that merely starts with a pass-through one.
    "db.collection('users_archive')",
  ]) {
    assert.equal(checkSource(rule, file, src).length, 1, src);
  }
  for (const src of [
    "db.collection('payment_orders').doc(id).get();",
    "db.collection(\"users\").doc(uid)",
    "db.collection(name)",
    "ScopedCollection(collection: 'notes', appId: APP_ID)",
    "// gateway-exempt: raw-collection admin tool, EX-ADMIN-1\ndb.collection('notes')",
  ]) {
    assert.deepEqual(checkSource(rule, file, src), [], src);
  }
  assert.deepEqual(checkSource(rule, 'packages/x/test/x_test.dart', "db.collection('notes')"), []);
});

test('raw-collection: a subcollection declared under a pass-through parent passes only chained off it', () => {
  const rule = rawCollectionRule({
    collections: {
      users: { kind: 'personal', subcollections: { metadata: { serverWritten: true }, prefs: {} } },
      notes: { apps: ['notes'], subcollections: { history: {} } },
    },
  });
  const file = 'packages/x/lib/x.dart';
  for (const src of [
    "db.collection('users').doc(uid).collection('prefs').doc('x').get();",
    "BluejayFirestore.forApp(APP_ID)\n    .collection('users')\n    .doc(widget.currentUser!.uid)\n    .collection('metadata')\n    .doc('access_index')",
    "db.collection(\"users\").doc(_uid()).collection(\"prefs\")",
  ]) {
    assert.deepEqual(checkSource(rule, file, src), [], src);
  }
  for (const src of [
    // The same name under a tenant parent, or not visibly chained off users.
    "db.collection('notes').doc(id).collection('prefs')",
    "userRef.collection('metadata')",
    // An undeclared subcollection of the pass-through parent.
    "db.collection('users').doc(uid).collection('drafts')",
    // A tenant parent's declared subcollection is still tenant data.
    "db.collection('notes').doc(id).collection('history')",
  ]) {
    assert.equal(checkSource(rule, file, src).length, 1, src);
  }
});

test('undeclared-collection: a ScopedCollection must name a declared collection', () => {
  const rule = undeclaredCollectionRule({ collections: { notes: { apps: ['notes'] }, notes_archive: {} } });
  const file = 'packages/x/lib/x.dart';
  for (const src of [
    "final c = ScopedCollection(collection: 'drafts', appId: APP_ID);",
    "final c = ScopedCollection(\n  collection: 'drafts',\n  appId: APP_ID,\n);",
    // A name that merely starts with a declared one.
    "ScopedCollection(collection: 'notes_v2', appId: APP_ID)",
  ]) {
    assert.equal(checkSource(rule, file, src).length, 1, src);
  }
  for (const src of [
    "ScopedCollection(collection: 'notes', appId: APP_ID)",
    "ScopedCollection(\n  collection: \"notes_archive\",\n  appId: APP_ID)",
    "ScopedCollection(collection: name, appId: APP_ID)",
    "// gateway-exempt: undeclared-collection not registered yet\nfinal c = ScopedCollection(\n  collection: 'drafts',\n);",
  ]) {
    assert.deepEqual(checkSource(rule, file, src), [], src);
  }
  assert.deepEqual(checkSource(rule, 'packages/x/test/x_test.dart', "ScopedCollection(collection: 'drafts')"), []);
  assert.ok(RULES.some((r) => r.id === 'undeclared-collection'), 'built from the committed table');
});

test('raw-collection is a ratchet rule built from the committed table', () => {
  const rule = RULES.find((r) => r.id === 'raw-collection');
  assert.ok(rule && rule.ratchet);
  assert.deepEqual(checkSource(rule, 'packages/x/lib/x.dart', "db.collection('payment_orders')"), []);
  assert.equal(checkSource(rule, 'packages/x/lib/x.dart', "db.collection('notes')").length, 1);
});

test('gateway-collection: only ScopedCollection skips the raw-collection check', () => {
  const rule = RULES.find((r) => r.id === 'gateway-collection');
  assert.equal(checkSource(rule, 'packages/x/lib/x.dart', 'db.scopedCollection(name)').length, 1);
  assert.deepEqual(checkSource(rule, 'packages/shared_services/lib/scoped_collection.dart', '_db.scopedCollection(collection)'), []);
});

test('client links are built on publicLinkHost', () => {
  const rule = RULES.find((r) => r.id === 'public-link-host');
  for (const line of [
    "final link = 'https://bluejay.gg/portal/$slug';",
    "Uri.https('bluejay.gg', '/$slug/forms');",
    "Uri.https(\n      'bluejay.gg',\n      '/$slug/forms');",
    "Uri.https(kPublicHost, '/store/$id');",
  ]) {
    assert.equal(checkSource(rule, 'packages/x/lib/a.dart', line).length, 1, line);
  }
  for (const line of [
    "Uri.https(publicLinkHost, '/portal/$slug');",
    '/// The portal page: `https://bluejay.gg/portal/<slug>`.',
    "static const usernameDomains = ['bluejay.gg', 'bluejay.ca'];",
  ]) {
    assert.equal(checkSource(rule, 'packages/x/lib/a.dart', line).length, 0, line);
  }
  assert.equal(checkSource(rule, 'packages/x/test/a_test.dart', "expect(link, 'https://bluejay.gg/p');").length, 0);
});
