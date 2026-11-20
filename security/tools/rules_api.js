/**
 * A small client for the Firebase Rules API (firebaserules.googleapis.com),
 * shared by the rules deploy pipeline's tools (plans/firestore-rules §8.2):
 * record_rules_release.js, rollback_rules.js and the deploy workflow's
 * dry-run compile.
 *
 * Every function takes a `request` function with google-auth-library's
 * `client.request` shape ({url, method, data} -> {status, data}), so tests
 * pass a fake and nothing here reaches the network on its own.
 */
'use strict';

const path = require('path');

const PROJECT = 'bluejay-d926f';
const BASE = 'https://firebaserules.googleapis.com/v1';
const ROOT = path.resolve(__dirname, '..', '..');

/** The two services a rules deploy touches, and their rules files. */
const SERVICES = {
  firestore: { release: 'cloud.firestore', file: 'firestore.rules' },
  storage: { release: 'firebase.storage', file: 'storage.rules' },
};

class RulesApiError extends Error {
  constructor(message, status, body) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

/** An authenticated request function using Application Default Credentials. */
async function defaultRequest() {
  const { GoogleAuth } = require(path.join(ROOT, 'functions', 'node_modules', 'google-auth-library'));
  const client = await new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] }).getClient();
  return (opts) => client.request({ validateStatus: () => true, ...opts });
}

async function call(request, opts) {
  const res = await request(opts);
  if (res.status < 200 || res.status >= 300) {
    const detail = res.data && res.data.error ? res.data.error.message : JSON.stringify(res.data);
    throw new RulesApiError(`Rules API ${opts.method || 'GET'} ${opts.url} returned ${res.status}: ${String(detail).slice(0, 400)}`, res.status, res.data);
  }
  return res.data || {};
}

/** Every release in the project (one for Firestore, one per Storage bucket). */
async function listReleases(request, project = PROJECT) {
  const out = [];
  let pageToken;
  do {
    const qs = new URLSearchParams({ pageSize: '100', ...(pageToken ? { pageToken } : {}) });
    const data = await call(request, { url: `${BASE}/projects/${project}/releases?${qs}` });
    out.push(...(data.releases || []));
    pageToken = data.nextPageToken;
  } while (pageToken);
  return out;
}

/** The short release id (after `releases/`) of a release resource name. */
const releaseId = (name) => name.replace(/^projects\/[^/]+\/releases\//, '');

/**
 * The release(s) for [service] ('firestore' | 'storage'). Firestore has one
 * (`cloud.firestore`); Storage has one per bucket (`firebase.storage/<bucket>`).
 */
async function releasesFor(request, service, project = PROJECT) {
  const id = SERVICES[service] && SERVICES[service].release;
  if (!id) throw new Error(`unknown service "${service}" (firestore | storage)`);
  const all = await listReleases(request, project);
  return all.filter((r) => {
    const rid = releaseId(r.name);
    return rid === id || rid.startsWith(`${id}/`);
  });
}

/** {firestore: [{release, rulesetName, updateTime}], storage: [...]} for the services asked. */
async function currentReleases(request, services = Object.keys(SERVICES), project = PROJECT) {
  const all = await listReleases(request, project);
  const out = {};
  for (const service of services) {
    const id = SERVICES[service].release;
    out[service] = all
      .filter((r) => releaseId(r.name) === id || releaseId(r.name).startsWith(`${id}/`))
      .map((r) => ({ release: releaseId(r.name), rulesetName: r.rulesetName, updateTime: r.updateTime || null }));
  }
  return out;
}

/** The most recent rulesets, newest first: [{name, createTime, services}]. */
async function listRulesets(request, { limit = 20, project = PROJECT } = {}) {
  const out = [];
  let pageToken;
  do {
    const qs = new URLSearchParams({ pageSize: String(Math.min(limit, 100)), ...(pageToken ? { pageToken } : {}) });
    const data = await call(request, { url: `${BASE}/projects/${project}/rulesets?${qs}` });
    out.push(...(data.rulesets || []));
    pageToken = data.nextPageToken;
  } while (pageToken && out.length < limit);
  return out
    .map((r) => ({
      name: r.name,
      createTime: r.createTime,
      services: (r.metadata && r.metadata.services) || [],
    }))
    .sort((a, b) => String(b.createTime).localeCompare(String(a.createTime)))
    .slice(0, limit);
}

/** A ruleset's source files ({name, content}) and metadata. */
async function getRuleset(request, rulesetName) {
  return call(request, { url: `${BASE}/${normalizeRulesetName(rulesetName)}` });
}

/** Accepts a full resource name or a bare ruleset id. */
function normalizeRulesetName(name, project = PROJECT) {
  if (!name) throw new Error('a ruleset name is required');
  return name.startsWith('projects/') ? name : `projects/${project}/rulesets/${name}`;
}

/**
 * Points [release] (a short release id such as `cloud.firestore`) at
 * [rulesetName]. This is the rollback: rulesets stay stored, so nothing is
 * rebuilt and the change takes effect in about a minute.
 */
async function patchRelease(request, release, rulesetName, project = PROJECT) {
  const name = `projects/${project}/releases/${release}`;
  return call(request, {
    url: `${BASE}/${name}`,
    method: 'PATCH',
    data: { release: { name, rulesetName: normalizeRulesetName(rulesetName, project) }, updateMask: 'ruleset_name' },
  });
}

/**
 * Compiles [content] as [fileName] through the Rules API's `test` method,
 * with no test cases: nothing is created or released. Returns the ERROR
 * issues ([] when it compiles).
 */
async function compile(request, fileName, content, project = PROJECT) {
  const data = await call(request, {
    url: `${BASE}/projects/${project}:test`,
    method: 'POST',
    data: { source: { files: [{ name: fileName, content }] } },
  });
  return (data.issues || []).filter((i) => i.severity === 'ERROR');
}

module.exports = {
  PROJECT,
  SERVICES,
  RulesApiError,
  defaultRequest,
  listReleases,
  releasesFor,
  currentReleases,
  listRulesets,
  getRuleset,
  normalizeRulesetName,
  patchRelease,
  compile,
  releaseId,
};
