#!/usr/bin/env node
/**
 * The steps of .github/workflows/deploy-rules.yml that talk to Google APIs
 * (plans/firestore-rules §8.2). The deploy itself is firebase-tools.
 *
 *   node security/tools/rules_deploy.js targets   --services firestore,storage   (prints the --only value)
 *   node security/tools/rules_deploy.js compile   --services firestore,storage
 *   node security/tools/rules_deploy.js preflight --services firestore,storage
 *   node security/tools/rules_deploy.js before    --services ... --sha <sha> --out before.json [--no-firestore]
 *   node security/tools/rules_deploy.js after     --services ... --sha <sha> --status <status>
 *                                                 [--smoke smoke.json] [--out after.json] [--no-firestore]
 *
 * compile    compiles the repo's rules files through the Rules API `test`
 *            method (nothing is created or released). The dry run stops here.
 * preflight  Storage rules that call firestore.get() need the Storage service
 *            agent to hold roles/firebaserules.firestoreServiceAgent. Fails
 *            with the grant command if it doesn't (warns if the IAM policy
 *            can't be read).
 * before     records the currently released ruleset names, i.e. the
 *            rollback targets, to --out (uploaded as an artifact) and to
 *            Firestore rules_deployments/{sha} (kind: server).
 * after      records what is released now, the outcome and the smoke result.
 *
 * rules_deployments/{sha}: `before` is the first record for the SHA and is
 * never overwritten, so a re-run can't replace the rollback target with the
 * SHA's own ruleset. Each run is appended to `runs`.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const api = require('./rules_api');

const ROOT = path.resolve(__dirname, '..', '..');
const COLLECTION = 'rules_deployments';
const CROSS_SERVICE_ROLE = 'roles/firebaserules.firestoreServiceAgent';

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const out = { command, services: Object.keys(api.SERVICES), firestore: true };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const value = () => {
      const v = rest[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === '--services') out.services = parseServices(value());
    else if (a === '--sha') out.sha = value();
    else if (a === '--out') out.out = value();
    else if (a === '--status') out.status = value();
    else if (a === '--smoke') out.smoke = value();
    else if (a === '--no-firestore') out.firestore = false;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!['targets', 'compile', 'preflight', 'before', 'after'].includes(command)) {
    throw new Error('command must be one of targets | compile | preflight | before | after');
  }
  if ((command === 'before' || command === 'after') && !out.sha) throw new Error(`${command} needs --sha`);
  if (command === 'after' && !out.status) throw new Error('after needs --status');
  return out;
}

/** "firestore,storage" | "both" | "firestore" -> ['firestore', ...]. */
function parseServices(value) {
  const list = value === 'both' ? Object.keys(api.SERVICES) : value.split(',').map((s) => s.trim()).filter(Boolean);
  for (const s of list) if (!api.SERVICES[s]) throw new Error(`unknown service "${s}" (firestore | storage | both)`);
  if (!list.length) throw new Error('no services selected');
  return list;
}

/** The firebase-tools `--only` value for [services]. */
function onlyTargets(services) {
  return services.map((s) => (s === 'firestore' ? 'firestore:rules' : 'storage')).join(',');
}

async function compileAll(request, services, { root = ROOT, log = console.log } = {}) {
  let failed = 0;
  for (const service of services) {
    const file = api.SERVICES[service].file;
    const errors = await api.compile(request, file, fs.readFileSync(path.join(root, file), 'utf8'));
    for (const e of errors) {
      log(`::error file=${file},line=${(e.sourcePosition && e.sourcePosition.line) || 1}::${e.description}`);
    }
    log(`${file}: ${errors.length ? `${errors.length} compile error(s)` : 'compiles'}`);
    failed += errors.length;
  }
  if (failed) throw new Error(`${failed} compile error(s); nothing deployed`);
}

/** The Storage service agent the cross-service (firestore.get) role belongs to. */
async function projectNumber(request, project = api.PROJECT) {
  const res = await request({ url: `https://cloudresourcemanager.googleapis.com/v1/projects/${project}` });
  if (res.status !== 200) throw new Error(`could not read project ${project}: ${res.status}`);
  return res.data.projectNumber;
}

async function preflight(request, services, { root = ROOT, log = console.log } = {}) {
  if (!services.includes('storage')) return { ok: true, skipped: true };
  const source = fs.readFileSync(path.join(root, api.SERVICES.storage.file), 'utf8');
  if (!/\bfirestore\.(get|exists)\s*\(/.test(source)) return { ok: true, skipped: true };
  let policy;
  let number;
  try {
    number = await projectNumber(request);
    const res = await request({
      url: `https://cloudresourcemanager.googleapis.com/v1/projects/${api.PROJECT}:getIamPolicy`,
      method: 'POST',
      data: {},
    });
    if (res.status !== 200) throw new Error(`getIamPolicy returned ${res.status}`);
    policy = res.data;
  } catch (err) {
    log(`::warning::Could not check the Storage cross-service IAM binding (${err.message}). If storage.rules' firestore.get() calls fail after deploy, grant ${CROSS_SERVICE_ROLE}; see security/RULES_ROLLBACK.md.`);
    return { ok: true, unknown: true };
  }
  const member = `serviceAccount:service-${number}@gcp-sa-firebasestorage.iam.gserviceaccount.com`;
  const has = (policy.bindings || []).some((b) => b.role === CROSS_SERVICE_ROLE && (b.members || []).includes(member));
  if (has) {
    log(`Storage service agent holds ${CROSS_SERVICE_ROLE}.`);
    return { ok: true };
  }
  const cmd = `gcloud projects add-iam-policy-binding ${api.PROJECT} --member=${member} --role=${CROSS_SERVICE_ROLE}`;
  log(`::error::storage.rules calls firestore.get(), but ${member} lacks ${CROSS_SERVICE_ROLE}: every such check would fail in production. Grant it once: ${cmd}`);
  return { ok: false, command: cmd };
}

function runInfo(env = process.env) {
  const server = env.GITHUB_SERVER_URL || 'https://github.com';
  return {
    runId: env.GITHUB_RUN_ID || null,
    runAttempt: env.GITHUB_RUN_ATTEMPT || null,
    runUrl: env.GITHUB_RUN_ID ? `${server}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}` : null,
    actor: env.GITHUB_ACTOR || env.USER || null,
    event: env.GITHUB_EVENT_NAME || 'local',
    ref: env.GITHUB_REF || null,
  };
}

/** {firestore: 'projects/…/rulesets/…', storage: {...}} flattened to release -> ruleset. */
function flatten(current) {
  const out = {};
  for (const releases of Object.values(current)) for (const r of releases) out[r.release] = r.rulesetName;
  return out;
}

function defaultFirestore() {
  const admin = require(path.join(ROOT, 'functions', 'node_modules', 'firebase-admin'));
  if (!admin.apps.length) admin.initializeApp({ projectId: api.PROJECT });
  return { db: admin.firestore(), FieldValue: admin.firestore.FieldValue };
}

async function recordBefore(request, args, { firestore, env = process.env, log = console.log, now = () => new Date().toISOString() } = {}) {
  const current = await api.currentReleases(request, args.services);
  const record = { sha: args.sha, services: args.services, releases: flatten(current), recordedAt: now(), ...runInfo(env) };
  if (args.out) fs.writeFileSync(args.out, `${JSON.stringify(record, null, 2)}\n`);
  for (const [release, ruleset] of Object.entries(record.releases)) log(`before: ${release} -> ${ruleset}`);
  if (args.firestore) {
    const { db, FieldValue } = firestore || defaultFirestore();
    const ref = db.collection(COLLECTION).doc(args.sha);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const run = { phase: 'before', releases: record.releases, at: record.recordedAt, ...runInfo(env) };
      if (!snap.exists) {
        tx.set(ref, {
          sha: args.sha,
          services: args.services,
          before: record.releases,
          status: 'deploying',
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
          runs: [run],
        });
      } else {
        // Keep the first `before`: it is the rollback target for this SHA.
        const before = { ...record.releases, ...(snap.data().before || {}) };
        tx.update(ref, { before, status: 'deploying', updatedAt: FieldValue.serverTimestamp(), runs: FieldValue.arrayUnion(run) });
      }
    });
    log(`recorded ${COLLECTION}/${args.sha}`);
  }
  return record;
}

async function recordAfter(request, args, { firestore, env = process.env, log = console.log, now = () => new Date().toISOString() } = {}) {
  let releases = {};
  try {
    releases = flatten(await api.currentReleases(request, args.services));
  } catch (err) {
    log(`::warning::could not read the releases after deploy: ${err.message}`);
  }
  const smoke = args.smoke && fs.existsSync(args.smoke) ? JSON.parse(fs.readFileSync(args.smoke, 'utf8')) : null;
  const smokeSummary = smoke ? { ok: !!smoke.ok, passed: smoke.passed, failed: smoke.failed, skipped: smoke.skipped, expressionLimit: smoke.expressionLimit } : null;
  const record = { sha: args.sha, status: args.status, releases, smoke: smokeSummary, recordedAt: now(), ...runInfo(env) };
  if (args.out) fs.writeFileSync(args.out, `${JSON.stringify(record, null, 2)}\n`);
  for (const [release, ruleset] of Object.entries(releases)) log(`after: ${release} -> ${ruleset}`);
  if (args.firestore) {
    const { db, FieldValue } = firestore || defaultFirestore();
    const run = { phase: 'after', status: args.status, releases, smoke: smokeSummary, at: record.recordedAt, ...runInfo(env) };
    await db.collection(COLLECTION).doc(args.sha).set({
      sha: args.sha,
      status: args.status,
      after: releases,
      smoke: smokeSummary,
      updatedAt: FieldValue.serverTimestamp(),
      runs: FieldValue.arrayUnion(run),
    }, { merge: true });
    log(`recorded ${COLLECTION}/${args.sha}: ${args.status}`);
  }
  return record;
}

async function main(argv = process.argv.slice(2), deps = {}) {
  const args = parseArgs(argv);
  if (args.command === 'targets') {
    (deps.log || console.log)(onlyTargets(args.services));
    return onlyTargets(args.services);
  }
  const request = deps.request || (await api.defaultRequest());
  if (args.command === 'compile') return compileAll(request, args.services, deps);
  if (args.command === 'preflight') {
    const result = await preflight(request, args.services, deps);
    if (!result.ok) process.exitCode = 1;
    return result;
  }
  if (args.command === 'before') return recordBefore(request, args, deps);
  return recordAfter(request, args, deps);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = { main, parseArgs, parseServices, onlyTargets, compileAll, preflight, recordBefore, recordAfter, COLLECTION, CROSS_SERVICE_ROLE };
