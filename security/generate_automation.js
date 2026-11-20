#!/usr/bin/env node
/**
 * Emits the collections that feed Automations: functions/_automation_sources.json,
 * from security/collections.json's `automation` blocks
 * (plans/automations/DESIGN.md section 2, "Exposed fields"). Cloud Functions
 * deploy only functions/, so the engine (functions/_automation_sources.js)
 * reads this generated file, never the table.
 *
 *   "automation": {
 *     "label": "Deals",        what the Automations editor calls the records (optional)
 *     "events": ["record.created", "record.updated", "record.deleted"],
 *     "fields": [...],         the only fields an event envelope carries
 *     "fieldTypes": {...},     field -> string|number|boolean|date|list|map|uid, for the editor
 *                              (optional; a dateFields entry is a date)
 *     "dateFields": [...],     fields a schedule may count days from (a subset of fields)
 *     "webhookFields": [...]   a regulated app's fields a webhook may send (a subset of fields)
 *     "writableFields": [...]  narrows the fields record.update may set (optional; see below)
 *     "fieldCheck": {...}      field -> why scripts/automations/field_check.js can't see the
 *                              app write it (optional; only when truly needed; not generated)
 *   }
 *
 * A block may sit on a collection or on one of its subcollections
 * (`subcollections.<s>.automation`). A subcollection source is keyed
 * `<collection>/<subcollection>` (the audit trail's policy key), belongs to
 * the parent's app and takes its group from the parent doc; it has no
 * dateFields (timers address top-level records only).
 *
 * The generator also works out each source's `writableFields`: the exposed
 * fields an automation's record.update may set. That leaves out every field
 * the policy table locks (serverFields, immutable, creatorOnly, ownerOnly,
 * adminOnly, staffOnly, the reader and role fields), the identity and
 * permission fields (IDENTITY_FIELDS), uid-typed fields, and everything in a
 * collection only the server writes (kind server, serverWritten, blockUpdate,
 * immutableDoc). A block's own `writableFields` narrows that further (a
 * financial record's totals, say); it can't add a field the policy locks.
 *
 * Run through security/generate.js (which writes it, and checks it with --check).
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const JSON_PATH = path.join(ROOT, 'functions', '_automation_sources.json');
const RECORD_EVENTS = ['record.created', 'record.updated', 'record.deleted'];
const FIELD = /^[A-Za-z_][A-Za-z0-9_]*$/;
/** Never exposed: the stamps, and the causation field actions write (functions/_automation_envelope.js). */
const RESERVED_FIELDS = ['lastModifiedBy', 'lastModifiedAt', 'automationCause'];
const FIELD_TYPES = ['string', 'number', 'boolean', 'date', 'list', 'map', 'uid'];
const BLOCK_KEYS = ['label', 'events', 'fields', 'fieldTypes', 'dateFields', 'webhookFields', 'writableFields', 'fieldCheck'];
/** Who a record belongs to and who may see it: never set by an automation. */
const IDENTITY_FIELDS = ['groupId', 'appId', 'creatorId', 'ownerId', 'ownerIds', 'userId', 'uid', 'members', 'memberIds',
  'adminIds', 'readerIds', 'createdAt', 'deletedAt', 'searchPrefixes'];
/** Policy keys whose fields no automation writes. */
const LOCKED_FIELD_KEYS = ['serverFields', 'immutable', 'creatorOnly', 'ownerOnly', 'adminOnly', 'staffOnly', 'readerMayUpdate'];
const LOCKED_FIELD_NAMES = ['protectedRoleField', 'readerField', 'readerListField', 'clientReaderListField'];

/**
 * Every `automation` block in [table]: [{key, name, sub, entry, cfg, block}]
 * where [entry] is the collection's entry, [cfg] the subcollection's (or
 * the entry itself) and [key] the source key ('crm_deals', 'projects/tasks').
 */
function automationBlocks(table) {
  const out = [];
  for (const [name, entry] of Object.entries(table.collections)) {
    if ('automation' in entry) out.push({ key: name, name, sub: null, entry, cfg: entry, block: entry.automation });
    for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
      if (cfg && 'automation' in cfg) out.push({ key: `${name}/${sub}`, name, sub, entry, cfg, block: cfg.automation });
    }
  }
  return out;
}

/** Problems with the table's `automation` blocks ([] when valid). */
function automationProblems(table) {
  const problems = [];
  for (const { key, sub, entry, block } of automationBlocks(table)) {
    const where = sub ? `collections.${key.split('/')[0]}.subcollections.${sub}.automation` : `collections.${key}.automation`;
    const kind = entry.kind || 'tenant';
    if (!['tenant', 'server'].includes(kind)) problems.push(`${where} applies only to kind "tenant" or "server"`);
    if (!block || typeof block !== 'object' || Array.isArray(block)) {
      problems.push(`${where} must be an object`);
      continue;
    }
    const list = (k) => (Array.isArray(block[k]) ? block[k] : null);
    for (const k of Object.keys(block)) {
      if (!BLOCK_KEYS.includes(k)) problems.push(`${where}.${k} isn't an automation setting`);
    }
    if ('label' in block && (typeof block.label !== 'string' || !block.label.trim())) problems.push(`${where}.label must be text`);
    const events = list('events');
    if (!events || !events.length || events.some((e) => !RECORD_EVENTS.includes(e))) {
      problems.push(`${where}.events must list some of ${RECORD_EVENTS.join(', ')}`);
    }
    const fields = list('fields');
    if (!fields || !fields.length || fields.some((f) => typeof f !== 'string' || !FIELD.test(f))) {
      problems.push(`${where}.fields must list top-level field names`);
    } else {
      if (new Set(fields).size !== fields.length) problems.push(`${where}.fields lists a field twice`);
      const reserved = fields.filter((f) => RESERVED_FIELDS.includes(f));
      if (reserved.length) problems.push(`${where}.fields can't expose ${reserved.join(', ')}`);
    }
    for (const k of ['dateFields', 'webhookFields', 'writableFields']) {
      if (!(k in block)) continue;
      const subset = list(k);
      if (!subset || subset.some((f) => !(fields || []).includes(f))) problems.push(`${where}.${k} must list fields from ${where}.fields`);
    }
    if (sub && (list('dateFields') || []).length) {
      problems.push(`${where}.dateFields: a subcollection can't drive schedules (timers address top-level records)`);
    }
    if ('fieldTypes' in block) {
      const types = block.fieldTypes;
      if (!types || typeof types !== 'object' || Array.isArray(types)) problems.push(`${where}.fieldTypes must map fields to types`);
      else {
        for (const [field, type] of Object.entries(types)) {
          if (!(fields || []).includes(field)) problems.push(`${where}.fieldTypes.${field} isn't in ${where}.fields`);
          if (!FIELD_TYPES.includes(type)) problems.push(`${where}.fieldTypes.${field} must be one of ${FIELD_TYPES.join(', ')}`);
          if ((list('dateFields') || []).includes(field) && type !== 'date') problems.push(`${where}.fieldTypes.${field} is a date field`);
        }
      }
    }
    if ('fieldCheck' in block) {
      const exempt = block.fieldCheck;
      if (!exempt || typeof exempt !== 'object' || Array.isArray(exempt)) problems.push(`${where}.fieldCheck must map fields to reasons`);
      else {
        for (const [field, reason] of Object.entries(exempt)) {
          if (!(fields || []).includes(field)) problems.push(`${where}.fieldCheck.${field} isn't in ${where}.fields`);
          if (typeof reason !== 'string' || !reason.trim()) problems.push(`${where}.fieldCheck.${field} must say where the app writes it`);
        }
      }
    }
    const apps = Array.isArray(entry.apps) ? entry.apps : [];
    if (apps.length !== 1) problems.push(`${where} needs exactly one app in collections.${key.split('/')[0]}.apps (the app its events belong to)`);
  }
  return problems;
}

/** The exposed fields of one source an automation's record.update may set (see the header). */
function writableFields({ entry, cfg, sub, block }, fieldTypes) {
  const serverOnly = (entry.kind || 'tenant') === 'server' || entry.serverWritten === true || entry.blockUpdate === true ||
    entry.immutableDoc === true || (sub && cfg.serverWritten === true);
  if (serverOnly) return [];
  const policy = sub ? cfg : entry;
  const locked = new Set([
    ...IDENTITY_FIELDS,
    ...LOCKED_FIELD_KEYS.flatMap((k) => (Array.isArray(policy[k]) ? policy[k] : [])),
    ...LOCKED_FIELD_NAMES.map((k) => policy[k]).filter((v) => typeof v === 'string'),
  ]);
  const narrowed = Array.isArray(block.writableFields) ? new Set(block.writableFields) : null;
  return block.fields.filter((f) => !locked.has(f) && fieldTypes[f] !== 'uid' && (!narrowed || narrowed.has(f))).sort();
}

/** source key -> its automation config, sorted. */
function automationSources(table) {
  const out = automationBlocks(table)
    .sort((a, b) => a.key.localeCompare(b.key))
    .map((found) => {
      const { key, name, sub, entry, cfg, block } = found;
      const dateFields = [...(block.dateFields || [])].sort();
      const fieldTypes = { ...(block.fieldTypes || {}) };
      for (const f of dateFields) fieldTypes[f] = 'date';
      const sortedTypes = Object.fromEntries(Object.keys(fieldTypes).sort().map((f) => [f, fieldTypes[f]]));
      return [key, {
        appId: entry.apps[0],
        ...(block.label ? { label: block.label } : {}),
        ...(sub ? { parent: name, subcollection: sub } : {}),
        events: [...block.events].sort(),
        fields: [...block.fields].sort(),
        fieldTypes: sortedTypes,
        dateFields,
        webhookFields: [...(block.webhookFields || [])].sort(),
        writableFields: writableFields(found, fieldTypes),
        audited: sub ? cfg.auditTrail === true : entry.auditTrail === true,
      }];
    });
  return Object.fromEntries(out);
}

function renderJson(table) {
  return `${JSON.stringify({
    comment: 'GENERATED by security/generate.js (security/generate_automation.js) from security/collections.json. Do not edit: change the table and run `node security/generate.js`.',
    collections: automationSources(table),
  }, null, 2)}\n`;
}

/** Writes (or with --check, verifies) the engine's list. Throws on an invalid block. */
function main(table, argv = []) {
  const problems = automationProblems(table);
  if (problems.length) throw new Error(`security/collections.json: ${problems.join('\n')}`);
  const next = renderJson(table);
  const current = fs.existsSync(JSON_PATH) ? fs.readFileSync(JSON_PATH, 'utf8') : null;
  if (argv.includes('--check')) {
    if (current !== next) {
      console.error(`${path.relative(ROOT, JSON_PATH)} is out of date with security/collections.json. Run \`node security/generate.js\` and commit the result.`);
      process.exitCode = 1;
    }
    return;
  }
  if (current !== next) {
    fs.writeFileSync(JSON_PATH, next);
    console.log(`${path.relative(ROOT, JSON_PATH)} regenerated.`);
  }
}

module.exports = { JSON_PATH, RECORD_EVENTS, RESERVED_FIELDS, IDENTITY_FIELDS, automationBlocks, automationProblems, automationSources, renderJson, main };
