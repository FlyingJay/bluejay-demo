#!/usr/bin/env node
/**
 * Generates firestore.rules' table-driven sections from security/collections.json.
 *
 *   node security/generate.js          rewrite the generated sections in place
 *   node security/generate.js --check  exit 1 if firestore.rules is out of date (CI)
 *
 * The table is the single source of truth for per-collection policy: every
 * collectionPolicy(), selfKeyedSubcollections(), selfReadSubcollections()
 * and serverWrittenSubcollections() entry comes from it. Hand-written rules logic (inTenant(), detail(), the field-lock helpers,
 * the generic match blocks) stays in firestore.rules, outside the BEGIN/END GENERATED markers.
 * The table's `exceptions` section generates nothing: it is read by
 * security/check_rules_exceptions.js, which approves the reviewed exceptions.
 *
 * Every entry key maps 1:1 to a collectionPolicy() key, except:
 *   kind: "server"                  also emits blockCreate/Update/Delete + serverOnly
 *   kind: "tenant"                  the default; not emitted
 *   serverWritten: true             blockCreate/Update/Delete; reads keep the tenant rule
 *   subcollections.<s>.serverWritten  'collection/s' in serverWrittenSubcollections():
 *                                   the generic subcollection rule grants no writes
 *   subcollections.<s>.selfKeyed.selfRead  'collection/s' in selfReadSubcollections():
 *                                   the generic subcollection read lets only the
 *                                   keyed uid, the app's :admin tier and platform
 *                                   admins read a doc
 *   subcollections.<s>.collectionGroup  collectionGroupRead():
 *                                   collection-group queries over <s>
 *   subcollections.<s>.auditTrail / blockDelete / authorField /
 *     authorMayUpdate / softDelete / selfArrayFields /
 *     selfMapFields / createdAtField 'collection/s' in subcollectionPolicies():
 *                                   the governed-subcollection rule
 *   commentThread: true             adds COMMENT_THREAD's subcollections
 *                                   (comments, comment_likes) at load time
 *
 * Emitted into their own generated function, not collectionPolicy():
 *   serverFields: [...]             serverFields(collection); no client
 *                                   write may set these fields
 *   readerMayUpdate: [...]          readerWrites(collection) (with kind
 *   readerMayDelete: true           "server" + readerField): the reader may
 *                                   change only these fields on, or delete,
 *                                   their own doc (a notification's isRead)
 *
 * The public namespace (D2, plan 2.7): kind "public" emits only `kind`; its
 * table keys (source, projection, publishTier, publishWhen, requiredFields,
 * fileFields, maxBytes) and a tenant entry's `publishTo` are the server's
 * config (security/generate_public.js writes functions/_public_collections.json)
 * and the shim's (generate_dart.js), never the rules'.
 *
 *
 * Rule-side meaning of two tenant keys worth knowing when reading the table:
 *   memberWrite: true               memberWriteOk(): any non-guest member of the
 *                                   doc's group creates and updates their own
 *                                   doc (creatorId and any readerField == caller)
 *                                   without the app entitlement; needs singleOwner
 *   idPattern                       an extra id regex; `<groupId>` and `<uid>`
 *                                   stand for the doc's groupId and the caller
 *   clientReaderListField           isClientReader(): a uid in that list reads the
 *                                   doc while it holds `<scope>:guest` in the
 *                                   doc's group (portal clients)
 *
 * A collection with no entry (or an entry that emits no keys) is kind
 * "tenant", scoped by its docs' appId: collectionPolicy() returns {} for it.
 *
 * See plans/firestore-rules/IMPLEMENTATION_PLAN.md §2.3 (T1) and §2.4.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const generateDart = require('./generate_dart');

const ROOT = path.resolve(__dirname, '..');
const TABLE_PATH = path.join(__dirname, 'collections.json');
const SCHEMA_PATH = path.join(__dirname, 'collections.schema.json');
const RULES_PATH = path.join(ROOT, 'firestore.rules');

const SHORTHANDS = ['serverWritten'];
// `naturalKeyIds`: shim data (security/generate_dart.js); tenantIdOk() covers the id shape.
// The public namespace's keys (D2): the server's config (security/generate_public.js)
// and the shim's (generate_dart.js); the rules need only `kind: 'public'`.
const PUBLIC_KEYS = ['source', 'projection', 'publishTier', 'requiredFields', 'publishWhen', 'fileFields', 'maxBytes'];
// `auditAppId`, `auditRedact`: the audit trail's config (security/generate_audit.js), not the rules'.
// `automation`: the Automations engine's config (security/generate_automation.js), not the rules'.
const TABLE_ONLY = ['comment', 'subcollections', 'commentThread', 'naturalKeyIds', 'publishTo', 'auditAppId', 'auditGroupIdFromDocId', 'auditExempt', 'auditRedact', 'automation', ...PUBLIC_KEYS];
/** Fields every published doc carries besides its projection (plan 2.7). */
const PUBLIC_RESERVED_FIELDS = ['sourceGroupId', 'sourceAppId', 'sourceCollection', 'sourceId', 'publishedBy',
  'publishedAt', 'projectionVersion'];
/** Tenant identity: never copied into the public namespace. */
const TENANT_IDENTITY_FIELDS = ['groupId', 'appId', 'creatorId', 'ownerIds'];
// Keys emitted into their own small generated function instead of
// collectionPolicy(): a rule that evaluates the whole collectionPolicy() map
// literal exceeds the rules engine's 1000-expression budget, so hot checks
// that need only one key read a dedicated map.
const OWN_FUNCTION = ['serverFields', 'readerMayUpdate', 'readerMayDelete'];
const EXPANDED_KEYS = ['blockCreate', 'blockUpdate', 'blockDelete', 'serverOnly', 'serverOnlyReaderField'];
/** Keys that only mean something for kind "tenant" (the tenant rule's detail and field locks). */
const TENANT_ONLY_KEYS = ['apps', 'naturalKeyIds', 'commentThread', 'publishTo', 'memberRead', 'guestShareable', 'guestWritable', 'stewardRead', 'adminComments', 'adminOnlyCollection',
  'ownerScoped', 'writeTier', 'idPattern',
  'requiredClearance', 'staffApps', 'staffOnly', 'staffOnlyAppIds', 'staffOnlyValues', 'singleOwner', 'restrictEditToCreator',
  'protectedRoleField', 'immutable', 'creatorOnly', 'ownerOnly', 'adminOnly', 'immutableDoc', 'memberWrite',
  'clientReaderListField'];
// The tenant key a kind "server" collection may also declare: `apps` names
// the app that owns the collection (the tier audit counts it). The rules
// ignore it there (no client writes or tenant reads one), so it is dropped
// from the collection's collectionPolicy() entry.
const SERVER_ALSO_KEYS = ['apps'];
/**
 * Top-level collections that may be auditExempt: deliveries with no record
 * of their own (notifications; action_items, which mirror pending state
 * recorded on their source docs; notification_audit_log, the log of emails
 * and notifications the server sent; ops_alerts, whether an operations
 * problem has alerted yet). Subcollections: users/metadata (the derived access index)
 * and a `ledger` under an audited collection (append-only entries).
 */
const AUDIT_EXEMPT_COLLECTIONS = ['notifications', 'action_items', 'notification_audit_log', 'ops_alerts'];
/** Placeholders an idPattern may hold; tenantIdOk() substitutes them. */
const ID_PATTERN_PLACEHOLDERS = ['<groupId>', '<uid>'];
/** Keys that narrow detail(), which memberWrite skips, so they can't be combined with it. */
const MEMBER_WRITE_CONFLICTS = ['adminOnlyCollection', 'requiredClearance', 'writeTier', 'serverWritten'];
/** The tenant-id format computeEntitlements accepts (functions/_tenant_ids.js). */
const APP_ID = /^[a-z0-9][a-z0-9-]{0,62}$/;
const COMMENT_WIDTH = 72;
// Widest generated line, not counting its indentation.
const LINE_WIDTH = 100;
// Most expressions one collectionPolicy() bucket may cost; see policyBuckets().
const POLICY_BUCKET_BUDGET = 40;
/** The audit stamp every write to an audited collection or subcollection carries. */
const AUDIT_STAMP_FIELDS = ['lastModifiedAt', 'lastModifiedBy'];
/** The keys that make a subcollection governed (subcollectionPolicies()). */
const SUB_POLICY_KEYS = ['auditTrail', 'blockDelete', 'authorField', 'authorMayUpdate', 'authorEmailField', 'softDelete',
  'softDeleteClears', 'boundedList', 'selfArrayFields', 'selfMapFields', 'createdAtField'];
/**
 * The most selfArrayFields / selfMapFields one subcollection may declare: the
 * rules check each field by position (no loops), so the bound is fixed.
 */
const MAX_SELF_FIELDS = 2;
/** The fields a soft delete sets. */
const SOFT_DELETE_FIELDS = ['deletedAt', 'deletedBy'];

/**
 * The shared comment thread (packages/shared_ui/lib/comment_thread_widget.dart),
 * added to every entry that declares `commentThread: true`. One definition, so
 * each collection that shows the widget has the same policy.
 */
const COMMENT_THREAD = {
  comments: {
    comment: 'Comment thread: each comment is its author\'s. Any reader of the parent comments; only the author edits their text or deletes it, and deleting sets deletedAt/deletedBy (and clears the text) instead of removing the doc, so the audit trail keeps what was said.',
    authorField: 'authorId',
    authorMayUpdate: ['text', 'deletedAt', 'deletedBy'],
    authorEmailField: 'authorEmail',
    softDelete: true,
    softDeleteClears: 'text',
    blockDelete: true,
    auditTrail: true,
  },
  comment_likes: {
    comment: 'One doc per reader of the thread, keyed by their uid, listing the comments they like (commentIds): any reader likes a comment without editing it. Unliking removes the id; the doc is never deleted.',
    selfKeyed: { fields: ['userId', 'commentIds', 'updatedAt'], selfCreate: true, selfDelete: false, threadReaders: true },
    boundedList: { field: 'commentIds', max: 500 },
    blockDelete: true,
    auditTrail: true,
  },
};

/**
 * [table] with its templates applied: every `commentThread` entry gains
 * COMMENT_THREAD's subcollections. Pure (returns a copy); an entry that
 * already declares one of those subcollections keeps its own, and
 * validateTable reports the clash.
 */
function applyTemplates(table) {
  const collections = {};
  for (const [name, entry] of Object.entries(table.collections || {})) {
    if (!entry || entry.commentThread !== true) {
      collections[name] = entry;
      continue;
    }
    const subs = { ...(entry.subcollections || {}) };
    for (const [sub, cfg] of Object.entries(COMMENT_THREAD)) {
      if (!(sub in subs)) subs[sub] = JSON.parse(JSON.stringify(cfg));
    }
    collections[name] = { ...entry, subcollections: subs };
  }
  return { ...table, collections };
}

// ---------------------------------------------------------------------------
// Loading and validation
// ---------------------------------------------------------------------------

/**
 * Keys that appear more than once in the same JSON object. JSON.parse keeps
 * the last one silently, which would hide a second, conflicting entry for a
 * collection (firestore.rules had exactly that for one collection).
 */
function duplicateKeys(text) {
  const dups = [];
  const stack = [];
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      let j = i + 1;
      while (text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      const str = JSON.parse(text.slice(i, j + 1));
      let k = j + 1;
      while (/\s/.test(text[k])) k++;
      const top = stack[stack.length - 1];
      if (text[k] === ':' && top && top.type === 'object') {
        if (top.keys.has(str)) dups.push(str);
        top.keys.add(str);
      }
      i = j + 1;
      continue;
    }
    if (ch === '{') stack.push({ type: 'object', keys: new Set() });
    else if (ch === '[') stack.push({ type: 'array' });
    else if (ch === '}' || ch === ']') stack.pop();
    i++;
  }
  return dups;
}

function typeError(where, rule, value) {
  if (rule.const !== undefined) return value === rule.const ? null : `${where} must be ${JSON.stringify(rule.const)}`;
  if (rule.enum) return rule.enum.includes(value) ? null : `${where} must be one of ${rule.enum.join(', ')}`;
  if (rule.type === 'boolean') return typeof value === 'boolean' ? null : `${where} must be a boolean`;
  if (rule.type === 'integer') return Number.isInteger(value) && value >= 0 ? null : `${where} must be a whole number`;
  if (rule.type === 'string') {
    if (typeof value !== 'string') return `${where} must be a string`;
    if (rule.minLength && value.trim().length < rule.minLength) return `${where} needs at least ${rule.minLength} characters`;
    if (rule.pattern && !new RegExp(rule.pattern).test(value)) return `${where} must match ${rule.pattern}`;
    return null;
  }
  if (rule.type === 'array') {
    if (!Array.isArray(value) || value.some((v) => typeof v !== 'string')) return `${where} must be a list of strings`;
    if (rule.minItems && value.length < rule.minItems) return `${where} needs at least ${rule.minItems} item(s)`;
    if (rule.maxItems && value.length > rule.maxItems) return `${where} allows at most ${rule.maxItems} item(s)`;
    if (new Set(value).size !== value.length) return `${where} has duplicate items`;
    return null;
  }
  return null;
}

/** Validates an object against a (small) subset of JSON Schema: the subset collections.schema.json uses. */
function validateObject(where, obj, schema, defs, problems) {
  const resolve = (rule) => (rule && rule.$ref ? defs[rule.$ref.replace('#/$defs/', '')] : rule);
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    problems.push(`${where} must be an object`);
    return;
  }
  for (const key of schema.required || []) {
    if (!(key in obj)) problems.push(`${where} is missing "${key}"`);
  }
  for (const [key, value] of Object.entries(obj)) {
    const rule = resolve((schema.properties || {})[key]) ||
      (schema.additionalProperties && typeof schema.additionalProperties === 'object'
        ? resolve(schema.additionalProperties) : null);
    if (!rule) {
      problems.push(`${where} has unknown key "${key}"`);
      continue;
    }
    if (schema.propertyNames && !(schema.properties || {})[key] &&
        !new RegExp(schema.propertyNames.pattern).test(key)) {
      problems.push(`${where}: "${key}" isn't a valid name`);
    }
    if (rule.type === 'object' || rule.properties || rule.additionalProperties) {
      validateObject(`${where}.${key}`, value, rule, defs, problems);
    } else {
      const err = typeError(`${where}.${key}`, rule, value);
      if (err) problems.push(err);
    }
  }
}

/**
 * The public namespace (D2, plan 2.7): every `public` entry is
 * public_<source>, its source is a tenant collection that declares
 * `publishTo` back, and its projection never carries tenant identity.
 */
function validatePublicNamespace(table) {
  const problems = [];
  const collections = (table && table.collections) || {};
  for (const [name, entry] of Object.entries(collections)) {
    if (!entry || typeof entry !== 'object') continue;
    const where = `collections.${name}`;
    const isPublic = entry.kind === 'public';
    if (!isPublic) {
      for (const key of PUBLIC_KEYS) if (key in entry) problems.push(`${where}.${key} only applies to kind "public"`);
      if (entry.publishTo !== undefined) {
        const target = collections[entry.publishTo];
        if (entry.publishTo !== `public_${name}`) problems.push(`${where}.publishTo must be "public_${name}"`);
        else if (!target || target.kind !== 'public' || target.source !== name) {
          problems.push(`${where}.publishTo names "${entry.publishTo}", which isn't a kind "public" entry with source "${name}"`);
        }
      }
      continue;
    }
    const source = collections[entry.source];
    if (typeof entry.source !== 'string') problems.push(`${where} (kind "public") needs a source`);
    else if (name !== `public_${entry.source}`) problems.push(`${where}: a public collection is named public_<source> ("public_${entry.source}")`);
    else if (!source || (source.kind || 'tenant') !== 'tenant') problems.push(`${where}.source "${entry.source}" must be a kind "tenant" collection`);
    else if (source.publishTo !== name) problems.push(`${where}: its source "${entry.source}" must declare publishTo "${name}"`);
    if (!Array.isArray(entry.projection)) problems.push(`${where} (kind "public") needs a projection`);
    const projection = entry.projection || [];
    for (const field of projection) {
      if (TENANT_IDENTITY_FIELDS.includes(field)) problems.push(`${where}.projection can't publish the tenant field "${field}"`);
      if (PUBLIC_RESERVED_FIELDS.includes(field)) problems.push(`${where}.projection can't hold "${field}": every published doc sets it`);
      if (!/^[A-Za-z0-9_]+$/.test(field)) problems.push(`${where}.projection: "${field}" must be a top-level field name`);
    }
    for (const field of entry.fileFields || []) {
      if (!projection.includes(field)) problems.push(`${where}.fileFields: "${field}" isn't in the projection`);
    }
    for (const [field, value] of Object.entries(entry.publishWhen || {})) {
      if (!['string', 'number', 'boolean'].includes(typeof value)) problems.push(`${where}.publishWhen.${field} must be a string, number or boolean`);
    }
    if (entry.maxBytes !== undefined && (entry.maxBytes < 1024 || entry.maxBytes > 900000)) {
      problems.push(`${where}.maxBytes must be between 1024 and 900000 (Firestore's doc limit is 1 MiB)`);
    }
    for (const key of ['subcollections', 'adminWritable', 'developerWritable', 'developerRead', 'readerField',
      'readerListField', 'serverFields', 'serverWritten', 'blockCreate', 'blockUpdate', 'blockDelete', 'immutableDoc']) {
      if (key in entry) problems.push(`${where}.${key}: kind "public" takes no client grants or subcollections (only the publish callables write it)`);
    }
  }
  return problems;
}

/**
 * Every reason the table is invalid ([] = valid). [rawTable] is the table as
 * written; its templates (applyTemplates) are applied before checking, so
 * what is validated is what the rules are generated from.
 */
function validateTable(rawTable, schema, text) {
  const problems = [];
  if (text) {
    for (const key of duplicateKeys(text)) problems.push(`"${key}" appears twice in the same object`);
  }
  const rawSubs = (name) => (((rawTable && rawTable.collections) || {})[name] || {}).subcollections;
  const table = rawTable && typeof rawTable === 'object' && rawTable.collections && typeof rawTable.collections === 'object'
    ? applyTemplates(rawTable) : rawTable;
  validateObject('collections.json', table, schema, schema.$defs, problems);
  problems.push(...validatePublicNamespace(table));
  for (const [name, entry] of Object.entries(table.collections || {})) {
    const where = `collections.${name}`;
    const kind = entry.kind || 'tenant';
    const shorthand = entry.serverWritten || kind === 'server';
    if (entry.serverWritten && kind !== 'tenant') problems.push(`${where}.serverWritten only applies to kind "tenant"`);
    if (shorthand && EXPANDED_KEYS.some((k) => k in entry)) {
      problems.push(`${where} mixes ${entry.serverWritten ? 'serverWritten' : 'kind "server"'} with the keys it expands to (${EXPANDED_KEYS.filter((k) => k in entry).join(', ')})`);
    }
    if ('serverOnly' in entry || 'serverOnlyReaderField' in entry) {
      problems.push(`${where}: write kind "server" (+ readerField) instead of serverOnly`);
    }
    if (('readerField' in entry || 'readerListField' in entry) && !['server', 'tenant'].includes(kind)) {
      problems.push(`${where}.readerField/readerListField need kind "server" or "tenant"`);
    }
    if ('clientReaderListField' in entry) {
      // The rule proves a client's list query from `groupId ==` and the
      // field alone, so the scope must come from the table (one app), and
      // only the server may say who the doc's clients are.
      if ((entry.apps || []).length !== 1) problems.push(`${where}.clientReaderListField needs exactly one app in apps`);
      if (!(entry.serverFields || []).includes(entry.clientReaderListField) && !entry.serverWritten) {
        problems.push(`${where}.clientReaderListField "${entry.clientReaderListField}" must be in serverFields`);
      }
    }
    if (kind !== 'tenant') {
      for (const key of TENANT_ONLY_KEYS) {
        if (kind === 'server' && SERVER_ALSO_KEYS.includes(key)) continue;
        if (key in entry) problems.push(`${where}.${key} only applies to kind "tenant"`);
      }
    }
    if ((entry.developerWritable || entry.adminWritable) && ['server', 'personal'].includes(kind)) {
      problems.push(`${where}: kind "${kind}" takes no adminWritable/developerWritable`);
    }
    if (entry.idPattern) {
      try { new RegExp(entry.idPattern); } catch (err) { problems.push(`${where}.idPattern isn't a valid regex`); }
      for (const token of entry.idPattern.match(/<[^>]*>/g) || []) {
        if (!ID_PATTERN_PLACEHOLDERS.includes(token)) {
          problems.push(`${where}.idPattern: "${token}" isn't a placeholder (use ${ID_PATTERN_PLACEHOLDERS.join(' or ')})`);
        }
      }
    }
    if (entry.memberWrite) {
      if (!entry.singleOwner) problems.push(`${where}.memberWrite needs singleOwner (a member writes only a doc that is theirs alone)`);
      for (const key of MEMBER_WRITE_CONFLICTS.filter((k) => k in entry)) {
        problems.push(`${where}.memberWrite can't be combined with ${key} (memberWrite skips the entitlement detail ${key} narrows)`);
      }
    }
    // The audit trail is a server trigger, so it applies to tenant and server
    // collections alike (any kind with docs the server writes).
    if (entry.auditTrail && !['tenant', 'server'].includes(kind)) problems.push(`${where}.auditTrail only applies to kind "tenant" or "server"`);
    if (entry.auditTrail && 'auditExempt' in entry) problems.push(`${where} can't be both auditTrail and auditExempt`);
    if ('auditExempt' in entry && !AUDIT_EXEMPT_COLLECTIONS.includes(name)) {
      problems.push(`${where}.auditExempt is allowed only on ${AUDIT_EXEMPT_COLLECTIONS.join(', ')} (and ledger subcollections of audited collections, and users/metadata)`);
    }
    if ('auditExempt' in entry && kind === 'tenant' && Array.isArray(entry.apps) && entry.apps.length) {
      problems.push(`${where}.auditExempt can't apply to an app's own tenant collection`);
    }
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (!('auditExempt' in cfg)) continue;
      const allowed = (name === 'users' && sub === 'metadata') || (sub === 'ledger' && entry.auditTrail === true);
      if (!allowed) problems.push(`${where}.subcollections.${sub}.auditExempt is allowed only on users/metadata and on a ledger under an audited collection`);
    }
    if (entry.auditGroupIdFromDocId && !entry.auditTrail) problems.push(`${where}.auditGroupIdFromDocId needs auditTrail`);
    if ('auditRedact' in entry) {
      if (!entry.auditTrail) problems.push(`${where}.auditRedact needs auditTrail`);
      const fields = entry.auditRedact;
      if (!Array.isArray(fields) || fields.length === 0 || fields.some((f) => typeof f !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(f))) {
        problems.push(`${where}.auditRedact must be a non-empty list of field names (a dotted path names a key inside a map field)`);
      } else if (new Set(fields).size !== fields.length) {
        problems.push(`${where}.auditRedact lists a field twice`);
      }
    }
    if ('search' in entry) {
      // The audit trail's trigger keeps searchPrefixes current, and only it
      // may write the field.
      if (!entry.auditTrail) problems.push(`${where}.search needs auditTrail (its trigger maintains searchPrefixes)`);
      if (kind !== 'server' && !(entry.serverFields || []).includes('searchPrefixes')) problems.push(`${where}.search needs "searchPrefixes" in serverFields`);
      const search = entry.search || {};
      const isPath = (f) => typeof f === 'string' && /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/.test(f);
      for (const key of ['fields', 'digitFields', 'hiddenWhen']) {
        const list = search[key];
        if (list === undefined) continue;
        if (!Array.isArray(list) || list.some((f) => !isPath(f))) problems.push(`${where}.search.${key} must be a list of field names (a dotted path names a key inside a map field)`);
        else if (new Set(list).size !== list.length) problems.push(`${where}.search.${key} lists a field twice`);
      }
      for (const f of search.digitFields || []) {
        if (!(search.fields || []).includes(f)) problems.push(`${where}.search.digitFields: "${f}" isn't one of its fields`);
      }
    }
    if ('auditAppId' in entry) {
      if (!entry.auditTrail) problems.push(`${where}.auditAppId needs auditTrail`);
      if (typeof entry.auditAppId !== 'string' || !APP_ID.test(entry.auditAppId)) {
        problems.push(`${where}.auditAppId: "${entry.auditAppId}" isn't a valid app id`);
      }
    }
    for (const key of ['apps', 'staffApps', 'staffOnlyAppIds']) {
      for (const app of entry[key] || []) {
        if (!APP_ID.test(app)) problems.push(`${where}.${key}: "${app}" isn't a valid app id (computeEntitlements skips it)`);
      }
    }
    for (const key of ['readerMayUpdate', 'readerMayDelete']) {
      if (key in entry && !(entry.kind === 'server' && entry.readerField)) {
        problems.push(`${where}.${key} needs kind "server" and a readerField (the reader is who may write)`);
      }
    }
    if ((entry.readerMayUpdate || []).includes(entry.readerField)) {
      problems.push(`${where}.readerMayUpdate can't include the readerField itself (the reader could hand the doc to someone else)`);
    }
    // No client writes these collections at all, so a client-write key is a mistake.
    const noClientWrites = entry.kind === 'server' ? 'kind "server"' : (entry.serverWritten ? 'serverWritten' : null);
    for (const key of ['adminWritable', 'serverFields']) {
      if (noClientWrites && key in entry) problems.push(`${where}.${key} contradicts ${noClientWrites} (no client writes at all)`);
    }
    if (entry.commentThread) {
      for (const sub of Object.keys(COMMENT_THREAD)) {
        if ((rawSubs(name) || {})[sub]) problems.push(`${where}.subcollections.${sub} clashes with commentThread, which defines it`);
      }
    }
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      const subWhere = `${where}.subcollections.${sub}`;
      if (cfg && cfg.serverWritten && SUB_POLICY_KEYS.some((k) => k in cfg)) {
        problems.push(`${subWhere} combines serverWritten with ${SUB_POLICY_KEYS.filter((k) => k in cfg).join(', ')}; a server-written subcollection has no client writers`);
      }
      if (cfg && cfg.authorField && cfg.selfKeyed) problems.push(`${subWhere} combines authorField and selfKeyed; a doc has one owner`);
      if (cfg && cfg.selfKeyed && cfg.selfKeyed.threadReaders && !SUB_POLICY_KEYS.some((k) => k in cfg)) {
        problems.push(`${subWhere}.selfKeyed.threadReaders applies to a governed subcollection only (declare auditTrail or blockDelete)`);
      }
      if (cfg && ('authorField' in cfg) !== ('authorMayUpdate' in cfg)) problems.push(`${subWhere}: authorField and authorMayUpdate go together`);
      if (cfg && cfg.softDelete && !cfg.blockDelete) problems.push(`${subWhere}.softDelete needs blockDelete (a soft delete replaces the hard one)`);
      if (cfg && cfg.softDelete && cfg.authorField && !SOFT_DELETE_FIELDS.every((f) => (cfg.authorMayUpdate || []).includes(f))) {
        problems.push(`${subWhere}.authorMayUpdate must list ${SOFT_DELETE_FIELDS.join(' and ')} (softDelete: the author deletes by setting them)`);
      }
      if (cfg && cfg.authorEmailField && (!cfg.authorField || (cfg.authorMayUpdate || []).includes(cfg.authorEmailField))) {
        problems.push(`${subWhere}.authorEmailField needs authorField and stays out of authorMayUpdate (it is fixed at create)`);
      }
      if (cfg && cfg.softDeleteClears && (!cfg.softDelete || (cfg.authorField && !(cfg.authorMayUpdate || []).includes(cfg.softDeleteClears)))) {
        problems.push(`${subWhere}.softDeleteClears needs softDelete, and with authorField a field in authorMayUpdate`);
      }
      if (cfg && cfg.boundedList) {
        const writable = [...((cfg.selfKeyed && cfg.selfKeyed.fields) || []), ...(cfg.authorMayUpdate || [])];
        if (!writable.includes(cfg.boundedList.field)) problems.push(`${subWhere}.boundedList.field must be a field its writers may set`);
      }
      const selfFields = [...((cfg && cfg.selfArrayFields) || []), ...((cfg && cfg.selfMapFields) || [])];
      for (const key of ['selfArrayFields', 'selfMapFields']) {
        if (cfg && (cfg[key] || []).length > MAX_SELF_FIELDS) problems.push(`${subWhere}.${key} lists more than ${MAX_SELF_FIELDS} fields`);
      }
      if (selfFields.length && !cfg.authorField) problems.push(`${subWhere}: selfArrayFields/selfMapFields need authorField (whose doc readers mark)`);
      if (new Set(selfFields).size !== selfFields.length) problems.push(`${subWhere}: a field is listed twice in selfArrayFields/selfMapFields`);
      if (selfFields.some((f) => f === cfg.authorField || (cfg.authorMayUpdate || []).includes(f) || TENANT_IDENTITY_FIELDS.includes(f) ||
          AUDIT_STAMP_FIELDS.includes(f) || f === cfg.authorEmailField)) {
        problems.push(`${subWhere}: selfArrayFields/selfMapFields can't name the authorField, its email, an authorMayUpdate field, a tenant identity field or an audit stamp`);
      }
      if (cfg && cfg.createdAtField) {
        const writable = [...((cfg.selfKeyed && cfg.selfKeyed.fields) || []), ...(cfg.authorMayUpdate || []), ...selfFields];
        if (!cfg.authorField || writable.includes(cfg.createdAtField) || TENANT_IDENTITY_FIELDS.includes(cfg.createdAtField) ||
            AUDIT_STAMP_FIELDS.includes(cfg.createdAtField)) {
          problems.push(`${subWhere}.createdAtField needs authorField and must be a field nobody may update (not in authorMayUpdate, the self fields, a tenant identity field or an audit stamp)`);
        }
      }
      if (cfg && (cfg.authorMayUpdate || []).some((f) => f === cfg.authorField || TENANT_IDENTITY_FIELDS.includes(f))) {
        problems.push(`${subWhere}.authorMayUpdate can't include the authorField or a tenant identity field`);
      }
      if (cfg && cfg.selfKeyed && cfg.selfKeyed.selfRead) {
        if ((entry.kind || 'tenant') !== 'tenant') problems.push(`${subWhere}.selfKeyed.selfRead applies under a tenant collection only`);
        if (cfg.collectionGroup) problems.push(`${subWhere} combines selfKeyed.selfRead and collectionGroup; a collection-group read would show every doc`);
      }
      if (cfg && cfg.serverWritten && cfg.selfKeyed) {
        problems.push(`${where}.subcollections.${sub} combines serverWritten and selfKeyed; a server-written subcollection has no client writers`);
      }
      const cg = (cfg && cfg.collectionGroup) || null;
      if (cg && !cg.readerField && !cg.readApps) {
        problems.push(`${where}.subcollections.${sub}.collectionGroup needs readerField or readApps`);
      }
    }
    const strings = JSON.stringify(entry, (k, v) => (k === 'comment' ? undefined : v));
    if (strings.includes("'")) problems.push(`${where} contains a single quote, which the rules output can't hold`);
  }
  for (const [id, ex] of Object.entries(table.exceptions || {})) {
    // The schema checks the YYYY-MM-DD shape; this rejects dates that don't exist (2026-02-30).
    const d = typeof ex.reviewed === 'string' && new Date(`${ex.reviewed}T00:00:00Z`);
    if (d && (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== ex.reviewed)) {
      problems.push(`exceptions.${id}.reviewed "${ex.reviewed}" isn't a real date`);
    }
    if (!ex.firestoreMatchBlocks && !ex.storageMatchBlocks && !ex.ruleFunctions) {
      problems.push(`exceptions.${id} names no firestoreMatchBlocks, storageMatchBlocks or ruleFunctions`);
    }
  }
  return problems;
}

function loadTable(tablePath = TABLE_PATH, schemaPath = SCHEMA_PATH) {
  const text = fs.readFileSync(tablePath, 'utf8');
  const table = JSON.parse(text);
  const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
  const problems = validateTable(table, schema, text);
  if (problems.length) {
    throw new Error(`security/collections.json is invalid:\n  - ${problems.join('\n  - ')}`);
  }
  return applyTemplates(table);
}

// ---------------------------------------------------------------------------
// Expansion: table entry -> collectionPolicy() entry
// ---------------------------------------------------------------------------

/**
 * The collectionPolicy() map entry for a table entry, keys in emit order
 * ({} = none: the rules read a missing entry as kind "tenant").
 */
function expandEntry(entry) {
  const out = {};
  if (entry.kind && entry.kind !== 'tenant') out.kind = entry.kind;
  if (entry.kind === 'server' || entry.serverWritten) {
    out.blockCreate = true;
    out.blockUpdate = true;
    out.blockDelete = true;
  }
  if (entry.kind === 'server') out.serverOnly = true;
  for (const [key, value] of Object.entries(entry)) {
    if ([...TABLE_ONLY, ...OWN_FUNCTION, ...SHORTHANDS, 'kind'].includes(key)) continue;
    if (entry.kind === 'server' && SERVER_ALSO_KEYS.includes(key)) continue;
    out[key] = value;
  }
  return out;
}

/** { collection: expanded policy } for every collection with a non-empty policy. */
function collectionPolicies(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    const policy = expandEntry(entry);
    if (Object.keys(policy).length) out[name] = policy;
  }
  return out;
}

/** { name: [{readerField?, readApps?}, ...] } for every declared collection-group subcollection. */
function collectionGroups(table) {
  const out = {};
  for (const entry of Object.values(table.collections)) {
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg.collectionGroup) (out[sub] = out[sub] || []).push(cfg.collectionGroup);
    }
  }
  return out;
}

/** { collection: [field, ...] } for every collection declaring serverFields. */
function serverFieldsByCollection(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    if (entry.serverFields) out[name] = entry.serverFields;
  }
  return out;
}

/** { collection: {field, update, delete} } for every collection whose reader may write their own doc. */
function readerWritesByCollection(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    if (!entry.readerMayUpdate && !entry.readerMayDelete) continue;
    out[name] = { field: entry.readerField, update: entry.readerMayUpdate || [], delete: entry.readerMayDelete === true };
  }
  return out;
}

const isGoverned = (cfg) => SUB_POLICY_KEYS.some((k) => k in (cfg || {}));

/** A selfKeyed config as the rules read it: an audited one's owner also writes the audit stamp. */
function selfKeyedRule(cfg) {
  const fields = cfg.auditTrail
    ? [...cfg.selfKeyed.fields, ...AUDIT_STAMP_FIELDS.filter((f) => !cfg.selfKeyed.fields.includes(f))]
    : cfg.selfKeyed.fields;
  const out = { fields, selfCreate: cfg.selfKeyed.selfCreate, selfDelete: cfg.selfKeyed.selfDelete };
  if (cfg.selfKeyed.editorsWrite) out.editorsWrite = true;
  if (cfg.selfKeyed.threadReaders) out.threadReaders = true;
  return out;
}

/**
 * { 'collection/subcollection': {fields, selfCreate, selfDelete} } for the
 * selfKeyed subcollections the generic rule handles. A governed one's
 * config travels in subcollectionPolicies() instead, so its writes never
 * build this map (the 1000-expression budget).
 */
function selfKeyedSubcollections(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg.selfKeyed && !isGoverned(cfg)) out[`${name}/${sub}`] = selfKeyedRule(cfg);
    }
  }
  return out;
}

/**
 * { 'collection/subcollection': policy } for every governed subcollection:
 * one declaring any of SUB_POLICY_KEYS (in that order), plus its selfKeyed
 * config if it has one.
 */
function subcollectionPolicies(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (!isGoverned(cfg)) continue;
      const policy = {};
      for (const key of SUB_POLICY_KEYS) if (key in cfg) policy[key] = cfg[key];
      if (cfg.selfKeyed) policy.selfKeyed = selfKeyedRule(cfg);
      out[`${name}/${sub}`] = policy;
    }
  }
  return out;
}


/**
 * ['collection/subcollection', ...] for every selfKeyed subcollection
 * declaring selfRead: a doc there is read only by the uid it is keyed by,
 * the parent app's :admin tier and platform admins.
 */
function selfReadSubcollections(table) {
  const out = [];
  for (const [name, entry] of Object.entries(table.collections)) {
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg.selfKeyed && cfg.selfKeyed.selfRead) out.push(`${name}/${sub}`);
    }
  }
  return out.sort();
}

/** { 'collection/subcollection': true } for every subcollection only the Admin SDK writes. */
function serverWrittenSubcollections(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) {
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg.serverWritten) out[`${name}/${sub}`] = true;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const q = (s) => `'${s}'`;

function renderValue(value) {
  if (Array.isArray(value)) return `[${value.map(renderValue).join(', ')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.entries(value).map(([k, v]) => `${q(k)}: ${renderValue(v)}`).join(', ')}}`;
  }
  return typeof value === 'string' ? q(value) : String(value);
}

/** A list too long for one line, packed into lines under LINE_WIDTH. */
function renderWrappedList(prefix, items, indent) {
  const lines = [];
  let line = `${prefix}[`;
  items.forEach((item, i) => {
    const piece = q(item) + (i < items.length - 1 ? ',' : '');
    if (line.trimStart().length + piece.length + 1 > LINE_WIDTH && !line.endsWith('[')) {
      lines.push(line);
      line = `${' '.repeat(indent)}${piece}`;
    } else {
      line += (line.endsWith('[') ? '' : ' ') + piece;
    }
  });
  lines.push(`${line}]`);
  return lines;
}

function wrapComment(text, indent) {
  const pad = `${' '.repeat(indent)}// `;
  const lines = [];
  let line = '';
  for (const word of text.split(/\s+/)) {
    if (line && line.length + word.length + 1 > COMMENT_WIDTH) {
      lines.push(pad + line);
      line = word;
    } else {
      line = line ? `${line} ${word}` : word;
    }
  }
  if (line) lines.push(pad + line);
  return lines;
}

/**
 * One line per entry, except entries with more than two keys that include a
 * list or object, which get one key per line. (The existing contract tests in
 * functions/field_permissions_rules_contracts.test.js match these shapes.)
 */
function renderEntry(name, policy, indent) {
  const pad = ' '.repeat(indent);
  const keys = Object.keys(policy);
  const nested = keys.some((k) => typeof policy[k] === 'object');
  if (keys.length <= 2 || !nested) return [`${pad}${q(name)}: ${renderValue(policy)},`];
  const inner = ' '.repeat(indent + 2);
  const lines = [`${pad}${q(name)}: {`];
  keys.forEach((k, i) => {
    const comma = i < keys.length - 1 ? ',' : '';
    const single = `${inner}${q(k)}: ${renderValue(policy[k])}${comma}`;
    if (single.trimStart().length <= LINE_WIDTH || !Array.isArray(policy[k])) {
      lines.push(single);
    } else {
      const prefix = `${inner}${q(k)}: `;
      const wrapped = renderWrappedList(prefix, policy[k], prefix.length + 1);
      wrapped[wrapped.length - 1] += comma;
      lines.push(...wrapped);
    }
  });
  lines.push(`${pad}},`);
  return lines;
}

const MARKER = (kind, name) => `    // ${kind} GENERATED ${name}`;
const MARKER_NOTE = ': edit security/collections.json, then run `node security/generate.js`.';

/** Rough count of the expressions Firestore evaluates to build one policy entry. */
function entryCost(policy) {
  let cost = 1;
  const walk = (v) => {
    if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === 'object') Object.values(v).forEach((x) => { cost += 1; walk(x); });
    else cost += 1;
  };
  Object.values(policy).forEach((v) => { cost += 1; walk(v); });
  return cost;
}

/**
 * collectionPolicy()'s entries in sorted buckets, each costing at most
 * POLICY_BUCKET_BUDGET (an entry costlier than that gets a bucket to itself).
 *
 * Why buckets: Firestore counts every expression it evaluates toward a limit
 * of 1000 per request, and building a map literal evaluates every key, value
 * and list item in it. The full table cost several hundred expressions per
 * collectionPolicy() call, and the rules call it several times per write, so
 * every ordinary write failed with "maximum of 1000 expressions" (found
 * 2026-11-05 with the Rules API). A balanced tree of name comparisons picks
 * one small bucket instead (see renderBucketTree()).
 */
function policyBuckets(table) {
  return costBuckets(Object.entries(table.collections)
    .map(([name, entry]) => ({ name, entry, policy: expandEntry(entry) }))
    .filter((e) => Object.keys(e.policy).length)
    .map((e) => ({ ...e, cost: entryCost(e.policy) })));
}

/**
 * [entries] ({name, cost, ...}) sorted by name and split into buckets each
 * costing at most POLICY_BUCKET_BUDGET (an entry costlier than that gets a
 * bucket to itself). Every per-collection lookup the rules call on a hot
 * path is bucketed this way (renderBucketedLookup), so the cost of a call
 * stays flat as the table grows instead of every entry taxing every request.
 */
function costBuckets(entries) {
  const sorted = [...entries].sort((x, y) => (x.name < y.name ? -1 : x.name > y.name ? 1 : 0));
  const buckets = [];
  let current = null;
  for (const e of sorted) {
    if (!current || current.cost + e.cost > POLICY_BUCKET_BUDGET) {
      current = { entries: [], cost: 0 };
      buckets.push(current);
    }
    current.entries.push(e);
    current.cost += e.cost;
  }
  return buckets;
}

/**
 * Nested `collection < 'x' ? (...) : (...)` over buckets[lo, hi), split in
 * the middle; [renderEntries](entries, indent) emits one bucket's map lines.
 */
function renderBucketTree(buckets, lo, hi, indent, lines, renderEntries) {
  const pad = ' '.repeat(indent);
  if (hi - lo === 1) {
    lines.push(`${pad}{`);
    lines.push(...renderEntries(buckets[lo].entries, indent + 2));
    lines.push(`${pad}}`);
    return;
  }
  const mid = Math.floor((lo + hi) / 2);
  lines.push(`${pad}collection < ${q(buckets[mid].entries[0].name)} ? (`);
  renderBucketTree(buckets, lo, mid, indent + 2, lines, renderEntries);
  lines.push(`${pad}) : (`);
  renderBucketTree(buckets, mid, hi, indent + 2, lines, renderEntries);
  lines.push(`${pad})`);
}

/**
 * `function <fn>(<params>)` returning `<map>.get(collection, <fallback>)`
 * and then [tail] (e.g. a further `.get(subcollection, {})`), where the map
 * is only the bucket [entries] picks by name. An empty table returns the
 * fallback (plus [tail]).
 */
function renderBucketedLookup({ fn, params = 'collection', entries, fallback, renderEntries, header = [], tail = '' }) {
  const lines = [...header, `    function ${fn}(${params}) {`];
  if (entries.length === 0) {
    lines.push(`      return ${fallback}${tail};`, '    }');
    return lines;
  }
  const buckets = costBuckets(entries);
  lines.push('      return (');
  renderBucketTree(buckets, 0, buckets.length, 8, lines, renderEntries);
  lines.push(`      ).get(collection, ${fallback})${tail};`, '    }');
  return lines;
}

function renderCollectionPolicy(table) {
  const lines = [`${MARKER('BEGIN', 'collectionPolicy')}${MARKER_NOTE}`];
  lines.push(...renderBucketedLookup({
    fn: 'collectionPolicy',
    fallback: '{}',
    header: [
      '    // A balanced tree of name comparisons picks one small bucket, so a call',
      '    // builds only that bucket\'s map: Firestore counts every map key, value',
      '    // and list item it evaluates toward its 1000-expression-per-request limit',
      '    // (see costBuckets() in security/generate.js).',
    ],
    entries: policyBuckets(table).flatMap((b) => b.entries),
    renderEntries: (entries, indent) => {
      const out = [];
      entries.forEach(({ name, entry, policy }, i) => {
        if (entry.comment) {
          if (i > 0) out.push('');
          out.push(...wrapComment(entry.comment, indent));
        }
        out.push(...renderEntry(name, policy, indent));
      });
      return out;
    },
  }));
  lines.push(MARKER('END', 'collectionPolicy'));
  return lines.join('\n');
}

function renderSelfKeyed(table) {
  const lines = [`${MARKER('BEGIN', 'selfKeyedSubcollections')}${MARKER_NOTE}`];
  lines.push('    function selfKeyedSubcollections() {', '      return {');
  for (const [key, cfg] of Object.entries(selfKeyedSubcollections(table))) {
    const entry = { fields: cfg.fields, selfCreate: cfg.selfCreate, selfDelete: cfg.selfDelete };
    if (cfg.editorsWrite) entry.editorsWrite = true;
    lines.push(`        ${q(key)}: ${renderValue(entry)},`);
  }
  lines.push('      };', '    }', MARKER('END', 'selfKeyedSubcollections'));
  return lines.join('\n');
}

function renderServerFields(table) {
  const lines = [`${MARKER('BEGIN', 'serverFields')}${MARKER_NOTE}`];
  lines.push(...renderBucketedLookup({
    fn: 'serverFields',
    fallback: '[]',
    entries: Object.entries(serverFieldsByCollection(table)).map(([name, fields]) => ({ name, fields, cost: entryCost(fields) })),
    renderEntries: (entries, indent) => entries.flatMap(({ name, fields }) => {
      const prefix = `${' '.repeat(indent)}${q(name)}: `;
      const wrapped = renderWrappedList(prefix, fields, prefix.length + 1);
      wrapped[wrapped.length - 1] += ',';
      return wrapped;
    }),
  }));
  lines.push(MARKER('END', 'serverFields'));
  return lines.join('\n');
}

function renderReaderWrites(table) {
  const lines = [`${MARKER('BEGIN', 'readerWrites')}${MARKER_NOTE}`];
  lines.push(...renderBucketedLookup({
    fn: 'readerWrites',
    fallback: '{}',
    entries: Object.entries(readerWritesByCollection(table)).map(([name, cfg]) => ({ name, cfg, cost: entryCost(cfg) })),
    renderEntries: (entries, indent) => entries.map(({ name, cfg }) => `${' '.repeat(indent)}${q(name)}: ${renderValue(cfg)},`),
  }));
  lines.push(MARKER('END', 'readerWrites'));
  return lines.join('\n');
}

/** { collection: { subcollection: policy } } for every governed subcollection. */
function subcollectionPoliciesByCollection(table) {
  const out = {};
  for (const [key, policy] of Object.entries(subcollectionPolicies(table))) {
    const [name, sub] = key.split('/');
    (out[name] = out[name] || {})[sub] = policy;
  }
  return out;
}

/**
 * subcollectionPolicy(collection, subcollection): the bucket tree picks the
 * bucket holding the collection's map of governed subcollections, then the
 * subcollection's policy, like collectionPolicy() (renderBucketedLookup()).
 */
function renderSubcollectionPolicies(table) {
  const lines = [`${MARKER('BEGIN', 'subcollectionPolicies')}${MARKER_NOTE}`];
  lines.push(...renderBucketedLookup({
    fn: 'subcollectionPolicy',
    params: 'collection, subcollection',
    fallback: '{}',
    tail: '.get(subcollection, {})',
    entries: Object.entries(subcollectionPoliciesByCollection(table)).map(([name, subs]) => ({ name, subs, cost: entryCost(subs) })),
    renderEntries: (entries, indent) => entries.flatMap(({ name, subs }) => {
      const pad = ' '.repeat(indent);
      const out = [`${pad}${q(name)}: {`];
      for (const [sub, policy] of Object.entries(subs)) out.push(...renderEntry(sub, policy, indent + 2));
      out.push(`${pad}},`);
      return out;
    }),
  }));
  lines.push(MARKER('END', 'subcollectionPolicies'));
  return lines.join('\n');
}

function renderServerWrittenSubcollections(table) {
  const lines = [`${MARKER('BEGIN', 'serverWrittenSubcollections')}${MARKER_NOTE}`];
  lines.push('    function serverWrittenSubcollections() {', '      return {');
  for (const key of Object.keys(serverWrittenSubcollections(table))) lines.push(`        ${q(key)}: true,`);
  lines.push('      };', '    }', MARKER('END', 'serverWrittenSubcollections'));
  return lines.join('\n');
}

function renderSelfReadSubcollections(table) {
  const lines = [`${MARKER('BEGIN', 'selfReadSubcollections')}${MARKER_NOTE}`];
  const keys = selfReadSubcollections(table);
  lines.push('    function selfReadSubcollections() {', `      return [${keys.map(q).join(', ')}];`, '    }', MARKER('END', 'selfReadSubcollections'));
  return lines.join('\n');
}

/** Replaces one BEGIN..END GENERATED section of the rules text. */
function spliceSection(rulesText, name, rendered) {
  const begin = rulesText.indexOf(MARKER('BEGIN', name));
  const endMarker = MARKER('END', name);
  const end = rulesText.indexOf(endMarker, begin);
  if (begin === -1 || end === -1) {
    throw new Error(`firestore.rules has no "${MARKER('BEGIN', name).trim()}" … "${endMarker.trim()}" section`);
  }
  return rulesText.slice(0, begin) + rendered + rulesText.slice(end + endMarker.length);
}

/** One `group == name && (...)` clause per declared collection group. */
function renderCollectionGroupRead(table) {
  const lines = [`${MARKER('BEGIN', 'collectionGroupRead')}${MARKER_NOTE}`];
  lines.push('    function collectionGroupRead(group, d) {', '      return (');
  const clauses = [];
  for (const [name, cfgs] of Object.entries(collectionGroups(table)).sort()) {
    const parts = [];
    for (const cfg of cfgs) {
      if (cfg.readerField) parts.push(`d.get(${q(cfg.readerField)}, '') == request.auth.uid`);
      if (cfg.readApps) {
        const scopes = cfg.readApps.map((a) => `d.get('groupId', '') + ${q(`:${a}`)}`).join(', ');
        parts.push(`(inTenant(idx(), d.get('groupId', '')) && idx().get('entitlements', []).hasAny([${scopes}]))`);
      }
    }
    clauses.push(`        (group == ${q(name)} && (${parts.join(' || ')}))`);
  }
  clauses.push('        false');
  lines.push(clauses.join(' ||\n'));
  lines.push('      );', '    }', MARKER('END', 'collectionGroupRead'));
  return lines.join('\n');
}

function generateRules(rulesText, table) {
  let out = spliceSection(rulesText, 'collectionPolicy', renderCollectionPolicy(table));
  out = spliceSection(out, 'selfKeyedSubcollections', renderSelfKeyed(table));
  out = spliceSection(out, 'serverFields', renderServerFields(table));
  out = spliceSection(out, 'readerWrites', renderReaderWrites(table));
  out = spliceSection(out, 'serverWrittenSubcollections', renderServerWrittenSubcollections(table));
  out = spliceSection(out, 'selfReadSubcollections', renderSelfReadSubcollections(table));
  out = spliceSection(out, 'subcollectionPolicies', renderSubcollectionPolicies(table));
  out = spliceSection(out, 'collectionGroupRead', renderCollectionGroupRead(table));
  return out;
}

function main(argv = process.argv.slice(2)) {
  require('./generate_storage').main(argv); // storage.rules from security/storage_paths.json (T16)
  const table = loadTable();
  require('./generate_public').main(table, argv); // the server's public-namespace config (T27)
  require('./generate_audit').main(table, argv); // the server's audited collections (audit_trail.js)
  require('./generate_automation').main(table, argv); // the collections that feed Automations (automations.js)
  require('./generate_data_catalog').main(table, argv); // the tenant collections Data & privacy lists and exports
  require('./generate_preview_sandbox').main(argv); // the preview sandbox seed's policy (functions/_preview_sandbox.js)
  const current = fs.readFileSync(RULES_PATH, 'utf8');
  const next = generateRules(current, table);
  if (argv.includes('--check')) {
    // The client shim's Dart table (security/generate_dart.js).
    const dartOk = generateDart.checkDart(table);
    if (!dartOk) {
      console.error(`${path.relative(ROOT, generateDart.DART_PATH)} is out of date with security/collections.json. Run \`node security/generate.js\` and commit the result.`);
      process.exitCode = 1;
    }
    if (next !== current) {
      console.error('firestore.rules is out of date with security/collections.json. Run `node security/generate.js` and commit the result.');
      process.exitCode = 1;
      return;
    }
    if (dartOk) console.log('firestore.rules matches security/collections.json.');
    return;
  }
  if (generateDart.writeDart(table)) console.log(`${path.relative(ROOT, generateDart.DART_PATH)} regenerated.`);
  if (next !== current) fs.writeFileSync(RULES_PATH, next);
  console.log(next !== current ? 'firestore.rules regenerated.' : 'firestore.rules already up to date.');
}

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(err.message);
    process.exitCode = 1;
  }
}

module.exports = {
  TABLE_PATH, SCHEMA_PATH, RULES_PATH, PUBLIC_KEYS, PUBLIC_RESERVED_FIELDS,
  COMMENT_THREAD, AUDIT_STAMP_FIELDS, SUB_POLICY_KEYS, SOFT_DELETE_FIELDS, MAX_SELF_FIELDS,
  duplicateKeys, validateTable, validatePublicNamespace, loadTable, applyTemplates, expandEntry, collectionPolicies, selfKeyedSubcollections,
  subcollectionPolicies, subcollectionPoliciesByCollection, renderSubcollectionPolicies,
  collectionGroups, renderCollectionGroupRead,
  serverFieldsByCollection, readerWritesByCollection, serverWrittenSubcollections, selfReadSubcollections, renderSelfReadSubcollections, policyBuckets, costBuckets, entryCost, renderCollectionPolicy, renderSelfKeyed,
  renderServerFields, renderReaderWrites, renderServerWrittenSubcollections, generateRules,
};
