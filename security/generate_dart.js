#!/usr/bin/env node
/**
 * Emits the client shim's copy of security/collections.json:
 * packages/shared_services/lib/generated/collection_policies.g.dart
 * (plans/firestore-rules/IMPLEMENTATION_PLAN.md §2.3, consumer 2; T10).
 *
 * ScopedCollection and MeteredFirestore read it to decide, per collection:
 *   kind          tenant (the default) or a pass-through kind (server,
 *                 personal, platform, platform_admin, public). Raw
 *                 `.collection()` access is only for pass-through kinds;
 *                 scripts/check_gateways.js (raw-collection) enforces that
 *                 statically and MeteredFirestore.collection in debug builds.
 *   apps          the owning app ids (`apps: [...]`). More than one means
 *                 the collection is multi-app, so ScopedCollection.query adds
 *                 `appId ==` to stay provable (§4.8). Empty: not declared yet.
 *   serverOwned   only the Admin SDK writes it (`kind: server`,
 *                 `serverWritten`, `public`).
 *   naturalKeyIds ids are natural keys (`naturalKeyIds: true` or an
 *                 `idPattern`), so callers use ScopedCollection.docForKey
 *                 (§3.3, §4.6). Declared in the table by T12.
 *   auditTrail    every change is recorded in audit_events, so ScopedCollection
 *                 stamps lastModifiedBy/lastModifiedAt on its writes.
 *   subcollections declared subcollections and whether each is server-owned.
 *   selfReadSubcollections  self-keyed subcollections whose docs only their
 *                 own uid reads (`selfKeyed.selfRead`): ScopedCollection
 *                 refuses to list them below the admin tier (debug assert).
 *   publishTo     a tenant collection's public namespace (`public_<name>`,
 *                 D2), which PublicCollection reads and publishes to.
 *   source        a public collection's tenant source.
 *   clientReaderListField          the client uid list queryAsClient filters on
 *   editTierWrites  writes need `:edit` or `:admin` (`writeTier: "edit"`).
 *   ownerScoped / singleOwner  below `:admin`, members reach only docs they
 *                 own (and, singleOwner, nobody shares them).
 *   blockDelete   docs are never deleted from the client: soft delete or
 *                 archive instead.
 *   searchable    record search indexes its docs (`search`): they carry
 *                 server-maintained `searchPrefixes`, so a RecordType may
 *                 search it (packages/shared_services/lib/record_types.dart).
 *   serverFields  fields no client may set. Shared tools that write
 *                 records an app describes (record_import.dart's spec
 *                 check) read these four to refuse writes the rules would.
 *   readerField / readerListField  the uid field (list) that grants a
 *                 personal read whatever the group; ScopedCollection.queryAsReader
 *                 filters on it.
 *
 * The emitter reads keys the table doesn't declare yet (apps, the non-server
 * kinds, naturalKeyIds, idPattern) tolerantly, so the T6 table rewrite only
 * has to add data, never to change this file — except to add a new kind,
 * which fails loudly here until KINDS knows it.
 *
 * Run through security/generate.js (which writes it, and checks it with
 * --check); `writeDart`/`checkDart` are its only touch points.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DART_PATH = path.join(ROOT, 'packages/shared_services/lib/generated/collection_policies.g.dart');

/** Table kind -> Dart enum value. `tenant` is the default for undeclared collections. */
const KINDS = {
  tenant: 'tenant',
  server: 'server',
  personal: 'personal',
  platform: 'platform',
  platform_admin: 'platformAdmin',
  public: 'public',
};

/** The shim's view of one table entry. */
function shimPolicy(name, entry) {
  const kind = entry.kind || 'tenant';
  if (!(kind in KINDS)) {
    throw new Error(`security/generate_dart.js: collection "${name}" has kind "${kind}", which the Dart table doesn't know. Add it to KINDS (and CollectionKind's docs).`);
  }
  const subs = {};
  const auditedSubs = [];
  const selfReadSubs = [];
  for (const [sub, cfg] of Object.entries(entry.subcollections || {})) {
    subs[sub] = { serverOwned: cfg.serverWritten === true || cfg.kind === 'server' };
    if (cfg.auditTrail === true) auditedSubs.push(sub);
    if (cfg.selfKeyed && cfg.selfKeyed.selfRead === true) selfReadSubs.push(sub);
  }
  return {
    kind,
    apps: Array.isArray(entry.apps) ? [...entry.apps] : [],
    serverOwned: kind === 'server' || kind === 'public' || entry.serverWritten === true,
    naturalKeyIds: entry.naturalKeyIds === true || typeof entry.idPattern === 'string',
    auditTrail: entry.auditTrail === true,
    subcollections: subs,
    auditedSubcollections: auditedSubs.sort(),
    selfReadSubcollections: selfReadSubs.sort(),
    publishTo: typeof entry.publishTo === 'string' ? entry.publishTo : null,
    source: kind === 'public' && typeof entry.source === 'string' ? entry.source : null,
    readerField: typeof entry.readerField === 'string' ? entry.readerField : null,
    readerListField: typeof entry.readerListField === 'string' ? entry.readerListField : null,
    clientReaderListField: typeof entry.clientReaderListField === 'string' ? entry.clientReaderListField : null,
    editTierWrites: entry.writeTier === 'edit',
    ownerScoped: entry.ownerScoped === true,
    singleOwner: entry.singleOwner === true,
    blockDelete: entry.blockDelete === true || kind === 'server' || kind === 'public' || entry.serverWritten === true,
    serverFields: Array.isArray(entry.serverFields) ? [...entry.serverFields].sort() : [],
    searchable: Boolean(entry.search),
  };
}

/** { collection: shimPolicy } for every table entry, sorted by name. */
function shimPolicies(table) {
  const out = {};
  for (const name of Object.keys(table.collections).sort()) {
    out[name] = shimPolicy(name, table.collections[name]);
  }
  return out;
}

/** Whether raw `.collection(name)` access is allowed: every non-tenant kind is a pass-through. */
function isPassThrough(policies, name) {
  const p = policies[name];
  return Boolean(p && p.kind !== 'tenant');
}

const dartString = (s) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$')}'`;

function renderPolicy(p) {
  const args = [];
  if (p.kind !== 'tenant') args.push(`kind: CollectionKind.${KINDS[p.kind]}`);
  if (p.apps.length) args.push(`apps: [${p.apps.map(dartString).join(', ')}]`);
  if (p.serverOwned) args.push('serverOwned: true');
  if (p.naturalKeyIds) args.push('naturalKeyIds: true');
  if (p.auditTrail) args.push('auditTrail: true');
  const subs = Object.entries(p.subcollections);
  if (subs.length) {
    const rendered = subs.map(([s, c]) => `${dartString(s)}: ${c.serverOwned ? 'true' : 'false'}`).join(', ');
    args.push(`subcollections: {${rendered}}`);
  }
  if (p.auditedSubcollections.length) {
    args.push(`auditedSubcollections: {${p.auditedSubcollections.map(dartString).join(', ')}}`);
  }
  if (p.selfReadSubcollections.length) {
    args.push(`selfReadSubcollections: {${p.selfReadSubcollections.map(dartString).join(', ')}}`);
  }
  if (p.publishTo) args.push(`publishTo: ${dartString(p.publishTo)}`);
  if (p.source) args.push(`source: ${dartString(p.source)}`);
  if (p.readerField) args.push(`readerField: ${dartString(p.readerField)}`);
  if (p.readerListField) args.push(`readerListField: ${dartString(p.readerListField)}`);
  if (p.clientReaderListField) args.push(`clientReaderListField: ${dartString(p.clientReaderListField)}`);
  if (p.editTierWrites) args.push('editTierWrites: true');
  if (p.ownerScoped) args.push('ownerScoped: true');
  if (p.singleOwner) args.push('singleOwner: true');
  if (p.blockDelete) args.push('blockDelete: true');
  if (p.serverFields.length) args.push(`serverFields: [${p.serverFields.map(dartString).join(', ')}]`);
  if (p.searchable) args.push('searchable: true');
  return `CollectionPolicy(${args.join(', ')})`;
}

function renderDart(table) {
  const policies = shimPolicies(table);
  const entries = Object.entries(policies)
    .map(([name, p]) => `  ${dartString(name)}: ${renderPolicy(p)},`)
    .join('\n');
  return `// GENERATED by security/generate.js (security/generate_dart.js) from
// security/collections.json. Do not edit: change the table and run
// \`node security/generate.js\`. CI fails if this file is out of date.
//
// The client shim's view of the collection policy table
// (plans/firestore-rules/IMPLEMENTATION_PLAN.md §2.3). It is convenience,
// not the boundary: firestore.rules decides every request.

/// A collection's kind (security/collections.json \`kind\`). Every kind but
/// [tenant] is a pass-through: raw \`.collection()\` access is expected for
/// it, rather than a ScopedCollection.
enum CollectionKind {
  /// Tenant data: every doc carries \`groupId\`; reach it via ScopedCollection.
  tenant,

  /// Written only by the Admin SDK; clients read their own docs at most.
  server,

  /// Belongs to one user (\`users/{uid}\` and the like); no tenant.
  personal,

  /// A global catalog any signed-in user reads.
  platform,

  /// Readable by platform admins (and developers) only.
  platformAdmin,

  /// Published cross-group projections (the public namespace, D2).
  public,
}

/// One collection's entry in [collectionPolicies].
class CollectionPolicy {
  const CollectionPolicy({
    this.kind = CollectionKind.tenant,
    this.apps = const [],
    this.serverOwned = false,
    this.naturalKeyIds = false,
    this.auditTrail = false,
    this.subcollections = const {},
    this.auditedSubcollections = const {},
    this.selfReadSubcollections = const {},
    this.publishTo,
    this.source,
    this.readerField,
    this.readerListField,
    this.clientReaderListField,
    this.editTierWrites = false,
    this.ownerScoped = false,
    this.singleOwner = false,
    this.blockDelete = false,
    this.serverFields = const [],
    this.searchable = false,
  });

  final CollectionKind kind;

  /// The app ids that own the collection; empty when the table doesn't
  /// declare them yet.
  final List<String> apps;

  /// Only the Admin SDK writes it.
  final bool serverOwned;

  /// Its ids are natural keys: address docs with ScopedCollection.docForKey.
  final bool naturalKeyIds;

  /// Every change is recorded in \`audit_events\`: ScopedCollection stamps
  /// \`lastModifiedBy\`/\`lastModifiedAt\` on its writes.
  final bool auditTrail;

  /// Declared subcollections, each mapped to whether it is server-owned.
  final Map<String, bool> subcollections;

  /// Declared subcollections whose docs are on the audit trail (their
  /// \`auditTrail\`): ScopedCollection.sub stamps their writes too.
  final Set<String> auditedSubcollections;

  /// Declared self-keyed subcollections whose docs only their own uid reads
  /// (\`selfKeyed.selfRead\`; platform admins too, never the app's
  /// admin tier): a client reads its own doc by id, never a list.
  final Set<String> selfReadSubcollections;

  /// A tenant collection's public namespace (\`public_<name>\`, D2): where
  /// PublicCollection reads its published projections.
  final String? publishTo;

  /// A [CollectionKind.public] collection's tenant source.
  final String? source;

  /// The field holding the one uid that may read a doc whatever its group
  /// (a notification's recipientId).
  final String? readerField;

  /// The server-maintained list of uids that may read a doc whatever its
  /// group (a marketplace thread's participants).
  final String? readerListField;

  /// The server-maintained list of portal clients who may read a doc while
  /// they are an admitted guest of its app in its group
  /// (ScopedCollection.queryAsClient).
  final String? clientReaderListField;

  /// Writes need the \`:edit\` or \`:admin\` tier (\`writeTier: "edit"\`); base-tier
  /// members only read.
  final bool editTierWrites;

  /// Below the \`:admin\` tier, members read and write only the docs they own.
  final bool ownerScoped;

  /// Each doc has exactly one owner and is never shared.
  final bool singleOwner;

  /// Clients never delete its docs (\`blockDelete\`, or a server-owned kind):
  /// they are soft-deleted or archived instead.
  final bool blockDelete;

  /// Fields no client may set, on create or update.
  final List<String> serverFields;

  /// Record search indexes its docs (\`search\`): each carries the
  /// server-maintained \`searchPrefixes\` a RecordSearch queries.
  final bool searchable;

  /// Raw \`.collection()\` access is expected (every non-tenant kind).
  bool get isPassThrough => kind != CollectionKind.tenant;

  /// Owned by more than one app: queries must also filter on \`appId\`.
  bool get isMultiApp => apps.length > 1;
}

/// The policy for every collection the table declares. Use
/// [collectionPolicyFor], which applies the default for the rest.
const Map<String, CollectionPolicy> collectionPolicies = {
${entries}
};

/// The policy for [collection] (a top-level name); an undeclared collection
/// is a tenant collection with nothing else declared.
CollectionPolicy collectionPolicyFor(String collection) =>
    collectionPolicies[collection] ?? const CollectionPolicy();
`;
}

/** Writes the Dart table if it changed; returns whether it did. */
function writeDart(table, dartPath = DART_PATH) {
  const next = renderDart(table);
  const current = fs.existsSync(dartPath) ? fs.readFileSync(dartPath, 'utf8') : null;
  if (current === next) return false;
  fs.mkdirSync(path.dirname(dartPath), { recursive: true });
  fs.writeFileSync(dartPath, next);
  return true;
}

/** Whether the committed Dart table matches the table. */
function checkDart(table, dartPath = DART_PATH) {
  return fs.existsSync(dartPath) && fs.readFileSync(dartPath, 'utf8') === renderDart(table);
}

module.exports = { DART_PATH, KINDS, shimPolicy, shimPolicies, isPassThrough, renderDart, writeDart, checkDart };
