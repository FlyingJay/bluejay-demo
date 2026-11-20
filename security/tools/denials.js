#!/usr/bin/env node
/**
 * Production permission-denied monitor: reads the `rules_denials` reports
 * clients send through rulesDenialReport (functions/rules_denials.js) and
 * prints them grouped by (service, collection, op, appId), with counts,
 * distinct users, first/last seen and the client builds that hit them.
 * Run it after each staged rules deploy; a group that appears right after
 * the deploy time is a rule wrongly denying real users.
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=... node security/tools/denials.js [options]
 *
 *   --minutes N     look back N minutes (default 60)
 *   --since <iso>   look back to this time instead (e.g. the deploy time,
 *                   2026-11-05T17:30:00Z); overrides --minutes
 *   --app <appId>   only this app
 *   --json          print the groups as JSON
 *   --limit N       read at most N reports (default 20000)
 *
 * Read-only: never writes. Uses firebase-admin from functions/node_modules
 * (or scripts/firestore_admin/node_modules) and the same credentials as
 * scripts/firestore_admin (see its README). The raw lines are also in Cloud
 * Logging: `jsonPayload.message="[RULES_DENIAL]"`.
 */
'use strict';

const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PROJECT_ID = 'bluejay-d926f';
const COLLECTION = 'rules_denials';

function parseArgs(argv) {
  const opts = { minutes: 60, since: null, app: null, json: false, limit: 20000 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (value === undefined) throw new Error(`${arg} needs a value`);
      return value;
    };
    if (arg === '--minutes') opts.minutes = Number(next());
    else if (arg === '--since') opts.since = next();
    else if (arg === '--app') opts.app = next();
    else if (arg === '--json') opts.json = true;
    else if (arg === '--limit') opts.limit = Number(next());
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else throw new Error(`Unknown option ${arg}`);
  }
  if (!(opts.minutes > 0)) throw new Error('--minutes must be a positive number');
  if (!(opts.limit > 0)) throw new Error('--limit must be a positive number');
  return opts;
}

/** The start of the window, in ms. */
function windowStartMs(opts, nowMs = Date.now()) {
  if (opts.since) {
    const ms = Date.parse(opts.since);
    if (Number.isNaN(ms)) throw new Error(`--since is not a date: ${opts.since}`);
    return ms;
  }
  return nowMs - opts.minutes * 60 * 1000;
}

/**
 * Groups report docs by (service, collection, op, appId), busiest first.
 *
 * @param {object[]} reports rules_denials doc data
 */
function groupReports(reports) {
  const groups = new Map();
  for (const r of reports) {
    const key = [r.service, r.collection, r.op, r.appId].join('|');
    let g = groups.get(key);
    if (!g) {
      g = {
        service: r.service,
        collection: r.collection,
        op: r.op,
        appId: r.appId,
        count: 0,
        users: new Set(),
        signedOut: 0,
        groups: new Set(),
        filterFields: new Set(),
        versions: new Set(),
        firstSeenMs: Infinity,
        lastSeenMs: -Infinity,
      };
      groups.set(key, g);
    }
    g.count++;
    if (r.uid) g.users.add(r.uid); else g.signedOut++;
    if (r.groupId) g.groups.add(r.groupId);
    for (const f of r.filterFields || []) g.filterFields.add(f);
    if (r.clientVersion) g.versions.add(r.clientVersion);
    const at = Number(r.receivedAtMs);
    if (Number.isFinite(at)) {
      g.firstSeenMs = Math.min(g.firstSeenMs, at);
      g.lastSeenMs = Math.max(g.lastSeenMs, at);
    }
  }
  return [...groups.values()]
    .map((g) => ({
      service: g.service,
      collection: g.collection,
      op: g.op,
      appId: g.appId,
      count: g.count,
      distinctUsers: g.users.size,
      signedOut: g.signedOut,
      groupIds: [...g.groups].sort(),
      filterFields: [...g.filterFields].sort(),
      clientVersions: [...g.versions].sort(),
      firstSeen: Number.isFinite(g.firstSeenMs) ? new Date(g.firstSeenMs).toISOString() : null,
      lastSeen: Number.isFinite(g.lastSeenMs) ? new Date(g.lastSeenMs).toISOString() : null,
    }))
    .sort((a, b) => b.distinctUsers - a.distinctUsers || b.count - a.count
      || a.collection.localeCompare(b.collection));
}

const clip = (list, n = 3) => (list.length > n ? `${list.slice(0, n).join(',')},+${list.length - n}` : list.join(','));

/** Human-readable table of [groups]. */
function formatGroups(groups, { sinceMs, total, truncated }) {
  const lines = [`Permission denials since ${new Date(sinceMs).toISOString()}: ${total} report(s), ${groups.length} group(s)`
    + (truncated ? ' (TRUNCATED at --limit; raise it)' : '')];
  if (!groups.length) {
    lines.push('None. No client has reported a permission-denied in this window.');
    return lines.join('\n');
  }
  const rows = groups.map((g) => [
    g.service === 'storage' ? `storage:${g.collection}` : g.collection,
    g.op,
    g.appId,
    String(g.count),
    String(g.distinctUsers) + (g.signedOut ? ` (+${g.signedOut} signed-out)` : ''),
    g.firstSeen ? g.firstSeen.slice(11, 19) : '-',
    g.lastSeen ? g.lastSeen.slice(11, 19) : '-',
    clip(g.groupIds),
    clip(g.filterFields, 4),
    clip(g.clientVersions.map((v) => v.slice(0, 8)), 2),
  ]);
  const header = ['COLLECTION', 'OP', 'APP', 'COUNT', 'USERS', 'FIRST(UTC)', 'LAST(UTC)', 'GROUPS', 'FILTERS', 'BUILDS'];
  const widths = header.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
  const fmt = (r) => r.map((c, i) => c.padEnd(widths[i])).join('  ').trimEnd();
  lines.push('', fmt(header), fmt(widths.map((w) => '-'.repeat(w))), ...rows.map(fmt));
  return lines.join('\n');
}

function loadAdmin() {
  for (const dir of ['functions', path.join('scripts', 'firestore_admin')]) {
    try {
      return require(path.join(ROOT, dir, 'node_modules', 'firebase-admin'));
    } catch (_) { /* try the next */ }
  }
  throw new Error('firebase-admin not found: run `npm ci` in functions/ or scripts/firestore_admin/');
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log(require('fs').readFileSync(__filename, 'utf8').split('\n').slice(2, 22).join('\n'));
    return;
  }
  const sinceMs = windowStartMs(opts);
  const admin = loadAdmin();
  admin.initializeApp({ projectId: PROJECT_ID });
  const query = admin.firestore().collection(COLLECTION).where('receivedAtMs', '>=', sinceMs);
  const snap = await query.limit(opts.limit).get();
  let reports = snap.docs.map((d) => d.data());
  if (opts.app) reports = reports.filter((r) => r.appId === opts.app);
  const groups = groupReports(reports);
  if (opts.json) {
    console.log(JSON.stringify({ since: new Date(sinceMs).toISOString(), total: reports.length, groups }, null, 2));
  } else {
    console.log(formatGroups(groups, { sinceMs, total: reports.length, truncated: snap.size >= opts.limit }));
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err.message || err);
    process.exit(1);
  });
}

module.exports = { parseArgs, windowStartMs, groupReports, formatGroups };
