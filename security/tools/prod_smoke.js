#!/usr/bin/env node
/**
 * Production smoke test for the released Firestore rules (plans/firestore-rules
 * §8.2 step 3, §6.4.4 "After deploy"). Read-only: it signs in as the test
 * accounts in prod_smoke_accounts.json (Admin SDK custom token, then the
 * identitytoolkit `signInWithCustomToken` REST endpoint, exactly as a client
 * would) and issues Firestore REST reads, asserting each is allowed or denied.
 * It writes nothing to Firestore (signing in only updates the account's
 * last-sign-in time).
 *
 *   node security/tools/prod_smoke.js [--out smoke.json] [--accounts file] [--core-only]
 *
 * --core-only skips the per-collection probes: after a rollback the released
 * ruleset is older than the table in the checkout, so its denies don't apply.
 *
 * Probes:
 *   - core flows, every persona, expect ALLOW: own user doc, own access index,
 *     own group doc, own notification inbox (list), the group's first
 *     installed app doc;
 *   - unauthenticated get of a user doc, expect DENY;
 *   - per collection, for every collection security/collections.json
 *     declares: an unauthenticated get (expect DENY); one doc from the
 *     *other* persona's group (expect DENY; not for kinds platform and
 *     public, which every signed-in user reads) and, when the persona is
 *     entitled to one, one doc from its own group (expect ALLOW). Samples
 *     are picked with the Admin SDK.
 *
 * A "maximum of 1000 expressions" error is reported as its own outcome and
 * always fails the run, allowed or not: it means a request runs out of the
 * rules engine's per-request budget (see the plan's T2 spike results).
 *
 * Exit code 1 when any probe fails. Needs GOOGLE_APPLICATION_CREDENTIALS for
 * a service account key (custom tokens are signed locally with its key;
 * reading the web API key uses the Firebase Management API, or set
 * FIREBASE_WEB_API_KEY).
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PROJECT = 'bluejay-d926f';
const DOCS = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;
const ACCOUNTS_PATH = path.join(__dirname, 'prod_smoke_accounts.json');
const PLATFORM_ROLES = ['admin', 'developer', 'support'];
const EXPRESSION_LIMIT = /maximum of 1000 expressions/i;

function parseArgs(argv) {
  const out = { accounts: ACCOUNTS_PATH };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--out') out.out = argv[++i];
    else if (a === '--accounts') out.accounts = argv[++i];
    else if (a === '--core-only') out.coreOnly = true;
    else throw new Error(`unknown argument ${a}`);
  }
  return out;
}

// ── Probe definitions (pure) ───────────────────────────────────────────────

const getProbe = (label, persona, docPath, expect, stage = 'core') => ({ label, persona, kind: 'get', path: docPath, expect, stage });
const listProbe = (label, persona, collection, field, value, expect, stage = 'core') => ({
  label, persona, kind: 'list', collection, field, value, expect, stage,
});

/** Probes every persona runs. */
function coreProbes(persona, { firstApp } = {}) {
  const p = persona.name;
  const out = [
    getProbe(`${p}: get own user doc`, p, `users/${persona.uid}`, 'ALLOW'),
    getProbe(`${p}: get own access index`, p, `users/${persona.uid}/metadata/access_index`, 'ALLOW'),
    getProbe(`${p}: get own group`, p, `groups/${persona.group}`, 'ALLOW'),
    listProbe(`${p}: list own notifications`, p, 'notifications', 'recipientId', persona.uid, 'ALLOW'),
  ];
  if (firstApp) out.push(getProbe(`${p}: get installed app ${firstApp}`, p, `apps/${firstApp}`, 'ALLOW'));
  return out;
}

/** Kinds any signed-in user reads: a doc of another group is no deny probe. */
const SIGNED_IN_READ_KINDS = ['platform', 'public'];

/** Every root collection the table declares: [[name, entry]], sorted. */
function declaredCollections(table) {
  return Object.entries(table.collections || {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
}

/**
 * Per-collection probes from samples: samples[collection][personaName] =
 * {foreign: docPath|null, own: docPath|null}. Every declared collection
 * also gets an unauthenticated get (any id: the rules deny before the doc
 * is read).
 */
function collectionProbes(table, personas, samples) {
  const out = [];
  const skipped = [];
  for (const [name, entry] of declaredCollections(table)) {
    out.push(getProbe(`anonymous: get ${name}`, null, `${name}/prod-smoke-probe`, 'DENY', 'collections'));
    for (const persona of personas) {
      const s = (samples[name] || {})[persona.name] || {};
      if (SIGNED_IN_READ_KINDS.includes(entry.kind)) {
        // read by any signed-in user: only the anonymous deny applies
      } else if (s.foreign) {
        out.push(getProbe(`${persona.name}: get ${name} doc of another group`, persona.name, s.foreign, 'DENY', 'collections'));
      } else {
        skipped.push(`${name}: no doc outside ${persona.name}'s groups to probe a deny with`);
      }
      if (s.own) out.push(getProbe(`${persona.name}: get ${name} doc in own group`, persona.name, s.own, 'ALLOW', 'collections'));
    }
  }
  return { probes: out, skipped };
}

// ── Classifying Firestore REST responses (pure) ─────────────────────────────

/** {outcome: ALLOW | DENY | EXPRESSION_LIMIT | ERROR, detail}. */
function classify(status, body) {
  const errs = [];
  if (body && body.error) errs.push(body.error);
  if (Array.isArray(body)) for (const item of body) if (item && item.error) errs.push(item.error);
  const message = errs.map((e) => e.message || '').join(' ');
  if (EXPRESSION_LIMIT.test(message)) return { outcome: 'EXPRESSION_LIMIT', detail: message.slice(0, 300) };
  if (status === 403 || errs.some((e) => e.status === 'PERMISSION_DENIED' || e.code === 403)) {
    return { outcome: 'DENY', detail: message.slice(0, 200) };
  }
  // 404 on a get means the rules allowed it and the doc is gone.
  if ((status >= 200 && status < 300 && !errs.length) || status === 404) return { outcome: 'ALLOW', detail: status === 404 ? 'not found' : '' };
  return { outcome: 'ERROR', detail: `${status} ${message || JSON.stringify(body).slice(0, 200)}` };
}

function judge(probe, { outcome, detail }) {
  const ok = outcome === probe.expect;
  return { ...probe, outcome, detail, ok };
}

// ── Network ────────────────────────────────────────────────────────────────

async function readJson(res) {
  const text = await res.text();
  try {
    return text ? JSON.parse(text) : {};
  } catch (_) {
    return { raw: text.slice(0, 300) };
  }
}

async function runProbe(fetchFn, probe, idToken) {
  const headers = { 'content-type': 'application/json' };
  if (idToken) headers.authorization = `Bearer ${idToken}`;
  let res;
  if (probe.kind === 'get') {
    const url = `${DOCS}/${probe.path.split('/').map(encodeURIComponent).join('/')}`;
    res = await fetchFn(url, { method: 'GET', headers });
  } else {
    res = await fetchFn(`${DOCS}:runQuery`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: probe.collection }],
          where: { fieldFilter: { field: { fieldPath: probe.field }, op: 'EQUAL', value: { stringValue: probe.value } } },
          limit: 1,
        },
      }),
    });
  }
  return classify(res.status, await readJson(res));
}

async function webApiKey(env = process.env) {
  if (env.FIREBASE_WEB_API_KEY) return env.FIREBASE_WEB_API_KEY;
  const { GoogleAuth } = require(path.join(ROOT, 'functions', 'node_modules', 'google-auth-library'));
  const client = await new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] }).getClient();
  const base = `https://firebase.googleapis.com/v1beta1/projects/${PROJECT}`;
  const apps = await client.request({ url: `${base}/webApps` });
  const app = (apps.data.apps || [])[0];
  if (!app) throw new Error('no Firebase web app found to read the API key from; set FIREBASE_WEB_API_KEY');
  const config = await client.request({ url: `https://firebase.googleapis.com/v1beta1/${app.name}/config` });
  return config.data.apiKey;
}

async function signIn(fetchFn, auth, uid, apiKey) {
  let token;
  try {
    token = await auth.createCustomToken(uid);
  } catch (err) {
    throw new Error(`could not mint a custom token for ${uid} (${err.message}). With a key file the Admin SDK signs locally; without one the credential needs iam.serviceAccounts.signBlob (roles/iam.serviceAccountTokenCreator).`);
  }
  const res = await fetchFn(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${apiKey}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token, returnSecureToken: true }),
  });
  const body = await readJson(res);
  if (!body.idToken) throw new Error(`sign-in as ${uid} failed: ${JSON.stringify(body.error || body).slice(0, 300)}`);
  return body.idToken;
}

// ── Admin SDK lookups (read-only) ──────────────────────────────────────────

/** Problems that make [persona] unfit to prove tenant isolation ([] = fit). */
function personaProblems(persona, index, otherGroups) {
  const problems = [];
  if (!index) return [`${persona.name}: no access index at users/${persona.uid}/metadata/access_index`];
  if (index.status !== 'ACTIVE') problems.push(`${persona.name}: access index status is ${index.status}, not ACTIVE`);
  const roles = (index.roles || []).filter((r) => PLATFORM_ROLES.includes(r));
  if (roles.length) problems.push(`${persona.name}: holds platform role(s) ${roles.join(', ')}, which read across groups`);
  if (!(index.groups || []).includes(persona.group)) problems.push(`${persona.name}: not a member of ${persona.group}`);
  for (const g of otherGroups) {
    if ((index.groups || []).includes(g)) problems.push(`${persona.name}: also a member of ${g}, so it can't prove a deny there`);
  }
  return problems;
}

/**
 * Whether the tenant rule's entitlement path lets [uid] read doc [d] (a
 * snapshot with get()): mirrors scopeOf() and detail() in firestore.rules,
 * so an "own group" probe expects ALLOW only for a doc the rules grant. The
 * other grants (readerField, memberRead, ...) only widen reads, so leaving
 * them out never yields a false ALLOW.
 */
function tenantReadAllowed(name, entry, index, uid, d) {
  const ents = new Set(index.entitlements || []);
  const apps = entry.apps || [];
  const app = apps.length === 1 ? apps[0] : d.get('appId') || entry.app || name;
  const scope = `${d.get('groupId')}:${app}`;
  const own = d.get('creatorId') === uid || (d.get('ownerIds') || []).includes(uid);
  if ((index.clearance_level || 0) < (entry.requiredClearance || 0)) return false;
  if (ents.has(`${scope}:admin`)) return true;
  if (entry.adminOnlyCollection || (entry.ownerScoped && !own)) return false;
  return ents.has(scope) || ents.has(`${scope}:edit`);
}

/** Picks probe docs for each declared collection with the Admin SDK. */
async function pickSamples(db, table, personas, indexes) {
  const samples = {};
  {
    for (const [name, entry] of declaredCollections(table)) {
      if (SIGNED_IN_READ_KINDS.includes(entry.kind)) continue;
      samples[name] = {};
      for (const persona of personas) {
        const index = indexes[persona.name];
        const mine = new Set(index.groups || []);
        const others = personas.filter((o) => o !== persona && !mine.has(o.group)).map((o) => o.group);
        let foreign = null;
        for (const g of others) {
          const snap = await db.collection(name).where('groupId', '==', g).limit(1).get();
          if (!snap.empty) {
            foreign = `${name}/${snap.docs[0].id}`;
            break;
          }
        }
        if (!foreign && entry.kind === 'server') {
          // Server-only collections without groupId: any doc must be unreadable to a client
          // unless it names the persona as its reader.
          const snap = await db.collection(name).limit(5).get();
          const doc = snap.docs.find((d) => !entry.readerField || d.get(entry.readerField) !== persona.uid);
          if (doc) foreign = `${name}/${doc.id}`;
        }
        let own = null;
        if (entry.kind === 'server') {
          if (entry.readerField) {
            const snap = await db.collection(name).where(entry.readerField, '==', persona.uid).limit(1).get();
            if (!snap.empty) own = `${name}/${snap.docs[0].id}`;
          }
        } else {
          const reads = (d) => tenantReadAllowed(name, entry, index, persona.uid, d);
          let snap = await db.collection(name).where('groupId', '==', persona.group).limit(20).get();
          let doc = snap.docs.find(reads);
          if (!doc && entry.ownerScoped) {
            // Owner-scoped docs are mostly other members': look for the persona's own.
            snap = await db.collection(name).where('groupId', '==', persona.group).where('creatorId', '==', persona.uid).limit(5).get();
            doc = snap.docs.find(reads);
          }
          if (doc) own = `${name}/${doc.id}`;
        }
        samples[name][persona.name] = { foreign, own };
      }
    }
  }
  return samples;
}

function defaultAdmin() {
  const admin = require(path.join(ROOT, 'functions', 'node_modules', 'firebase-admin'));
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  return { auth: admin.auth(), db: admin.firestore() };
}

// ── Main ───────────────────────────────────────────────────────────────────

function summarize(results, skipped, setupProblems) {
  const failed = results.filter((r) => !r.ok);
  const expressionLimit = results.filter((r) => r.outcome === 'EXPRESSION_LIMIT').map((r) => r.label);
  return {
    ok: !failed.length && !setupProblems.length,
    passed: results.length - failed.length,
    failed: failed.length,
    skipped: skipped.length,
    expressionLimit,
    setupProblems,
    skippedProbes: skipped,
    results,
  };
}

async function main(argv = process.argv.slice(2), deps = {}) {
  const args = parseArgs(argv);
  const log = deps.log || console.log;
  const fetchFn = deps.fetch || fetch;
  const { auth, db } = deps.admin || defaultAdmin();
  const table = deps.table || require('../generate').loadTable();
  const { personas } = JSON.parse(fs.readFileSync(args.accounts, 'utf8'));

  const indexes = {};
  const setupProblems = [];
  for (const persona of personas) {
    const snap = await db.doc(`users/${persona.uid}/metadata/access_index`).get();
    indexes[persona.name] = snap.exists ? snap.data() : null;
    const otherGroups = personas.filter((o) => o !== persona).map((o) => o.group);
    setupProblems.push(...personaProblems(persona, indexes[persona.name], otherGroups));
  }
  if (setupProblems.length) {
    for (const p of setupProblems) log(`::error::smoke account unsuitable: ${p}`);
    const summary = summarize([], [], setupProblems);
    if (args.out) fs.writeFileSync(args.out, `${JSON.stringify(summary, null, 2)}\n`);
    process.exitCode = 1;
    return summary;
  }

  const apiKey = deps.apiKey || (await webApiKey());
  const probes = [];
  for (const persona of personas) {
    const group = await db.doc(`groups/${persona.group}`).get();
    const firstApp = ((group.exists && group.data().installedApps) || [])[0];
    probes.push(...coreProbes(persona, { firstApp }));
  }
  probes.push(getProbe('anonymous: get a user doc', null, `users/${personas[0].uid}`, 'DENY'));
  const staged = args.coreOnly
    ? { probes: [], skipped: [] }
    : collectionProbes(table, personas, await pickSamples(db, table, personas, indexes));
  probes.push(...staged.probes);

  const tokens = {};
  for (const persona of personas) tokens[persona.name] = await signIn(fetchFn, auth, persona.uid, apiKey);

  const results = [];
  for (const probe of probes) {
    const result = judge(probe, await runProbe(fetchFn, probe, probe.persona ? tokens[probe.persona] : null));
    results.push(result);
    const tag = result.ok ? 'ok  ' : 'FAIL';
    log(`${tag} [${probe.stage}] ${probe.label}: expected ${probe.expect}, got ${result.outcome}${result.detail ? ` (${result.detail})` : ''}`);
  }
  for (const s of staged.skipped) log(`skip ${s}`);
  if (args.coreOnly) log('--core-only: per-collection probes skipped.');
  else log(`Probed ${declaredCollections(table).length} declared collection(s).`);

  const summary = summarize(results, staged.skipped, []);
  for (const label of summary.expressionLimit) {
    log(`::error::"maximum of 1000 expressions" on ${label}: a request exceeds the rules engine's per-request budget. Roll back (security/RULES_ROLLBACK.md).`);
  }
  log(`${summary.passed}/${results.length} probes as expected, ${summary.skipped} skipped.`);
  if (args.out) fs.writeFileSync(args.out, `${JSON.stringify(summary, null, 2)}\n`);
  if (!summary.ok) process.exitCode = 1;
  return summary;
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = {
  main, parseArgs, coreProbes, declaredCollections, collectionProbes, classify, judge, personaProblems, pickSamples, runProbe, signIn,
  tenantReadAllowed,
};
