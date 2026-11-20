#!/usr/bin/env node
/**
 * Rolls a Firestore or Storage rules release back to an earlier ruleset
 * (plans/firestore-rules §8.2). Rulesets stay stored after a deploy replaces
 * them, so this only re-points the release: nothing is rebuilt and it takes
 * effect in about a minute. See security/RULES_ROLLBACK.md.
 *
 *   node security/tools/rollback_rules.js --list [--service firestore|storage] [--limit 20]
 *   node security/tools/rollback_rules.js --to <rulesetName> [--service firestore|storage] [--dry-run]
 *
 * --service defaults to firestore. For storage, every `firebase.storage/<bucket>`
 * release is moved (pass --release <id> to move just one). The target ruleset
 * must exist and must be a ruleset for that service, so a Storage ruleset
 * can't be released to Firestore by a typo.
 *
 * Needs credentials allowed to call firebaserules on bluejay-d926f
 * (GOOGLE_APPLICATION_CREDENTIALS; see scripts/firestore_admin/README.md).
 * Also runs from the rollback-rules.yml workflow.
 */
'use strict';

const api = require('./rules_api');

function parseArgs(argv) {
  const out = { service: 'firestore', limit: 20 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === '--list') out.list = true;
    else if (a === '--to') out.to = value();
    else if (a === '--service') out.service = value();
    else if (a === '--release') out.release = value();
    else if (a === '--limit') out.limit = Number(value());
    else if (a === '--dry-run') out.dryRun = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!api.SERVICES[out.service]) throw new Error(`--service must be firestore or storage, not "${out.service}"`);
  if (!out.help && !out.list && !out.to) throw new Error('pass --list or --to <rulesetName>');
  return out;
}

/** Which service a stored ruleset is for, from its metadata or its file name. */
function rulesetService(ruleset) {
  const services = (ruleset.metadata && ruleset.metadata.services) || [];
  for (const [key, s] of Object.entries(api.SERVICES)) {
    if (services.includes(s.release)) return key;
  }
  const files = ((ruleset.source && ruleset.source.files) || []).map((f) => f.name);
  for (const [key, s] of Object.entries(api.SERVICES)) {
    if (files.includes(s.file)) return key;
  }
  return null;
}

async function list(request, { service, limit }, log) {
  const current = await api.currentReleases(request, Object.keys(api.SERVICES));
  log('Current releases:');
  for (const [svc, releases] of Object.entries(current)) {
    for (const r of releases) log(`  ${svc.padEnd(9)} ${r.release.padEnd(45)} -> ${r.rulesetName}  (updated ${r.updateTime})`);
  }
  const live = new Set(Object.values(current).flat().map((r) => r.rulesetName));
  const rulesets = await api.listRulesets(request, { limit: limit * 3 });
  const rows = [];
  for (const r of rulesets) {
    let svc = r.services.length ? rulesetService({ metadata: { services: r.services } }) : null;
    if (!svc) svc = rulesetService(await api.getRuleset(request, r.name));
    if (svc === service) rows.push({ ...r, service: svc });
    if (rows.length >= limit) break;
  }
  log(`\nRecent ${service} rulesets (newest first):`);
  for (const r of rows) log(`  ${r.createTime}  ${r.name}${live.has(r.name) ? '  [LIVE]' : ''}`);
  return { current, rulesets: rows };
}

async function rollback(request, { to, service, release, dryRun }, log) {
  const target = api.normalizeRulesetName(to);
  const ruleset = await api.getRuleset(request, target);
  const svc = rulesetService(ruleset);
  if (svc !== service) {
    throw new Error(`${target} is a ${svc || 'unknown-service'} ruleset, not ${service}; refusing to release it to ${service}`);
  }
  let releases = await api.releasesFor(request, service);
  if (release) releases = releases.filter((r) => api.releaseId(r.name) === release);
  if (!releases.length) throw new Error(`no ${service} release found${release ? ` named ${release}` : ''}`);
  const results = [];
  for (const r of releases) {
    const id = api.releaseId(r.name);
    const from = r.rulesetName;
    if (from === target) {
      log(`${id}: already on ${target}`);
      results.push({ release: id, from, to: target, changed: false });
      continue;
    }
    if (dryRun) {
      log(`[dry run] ${id}: would move ${from} -> ${target}`);
      results.push({ release: id, from, to: target, changed: false });
      continue;
    }
    await api.patchRelease(request, id, target);
    log(`${id}: ${from} -> ${target}`);
    results.push({ release: id, from, to: target, changed: true });
  }
  return results;
}

async function main(argv = process.argv.slice(2), { request, log = console.log } = {}) {
  const args = parseArgs(argv);
  if (args.help) {
    log('Usage: rollback_rules.js --list [--service firestore|storage] | --to <rulesetName> [--service ...] [--release <id>] [--dry-run]');
    return null;
  }
  const req = request || (await api.defaultRequest());
  return args.list ? list(req, args, log) : rollback(req, args, log);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = { main, parseArgs, rulesetService };
