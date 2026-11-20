'use strict';
/**
 * The table-driven matrix (plan 6.2): for every security/collections.json
 * entry and the synthetic undeclared collection, the cases persona x fixture
 * x operation, plus the collection-group queries. Writes nothing to disk;
 * test/matrix.test.js runs the cases against the committed rules, and
 * test/every_collection.test.js runs everyCollectionCases().
 * lib/expected.js says what each should decide.
 *
 * Entries whose policy is identical (same expanded collectionPolicy() entry,
 * serverFields and subcollections, not `groups`) can only differ by name, so
 * one representative per class runs the FULL matrix and the rest run a CORE
 * slice (own / other / other-group docs, get, create, benign update, delete,
 * the two shim list shapes). `full: true` runs the full matrix for every entry.
 */

const crypto = require('crypto');
const gen = require('../../generate');
const W = require('./world');

/** Subcollections exercised under the undeclared collection. */
const DEFAULT_SUBS = ['children', 'comments'];

/** A deterministic auto-id-shaped doc id (20 alphanumerics) for [key]. */
function autoId(key) {
  return crypto.createHash('sha256').update(key).digest('base64').replace(/[^A-Za-z0-9]/g, '').slice(0, 20);
}

const isPersonal = (entry) => entry.kind === 'personal';

function lockOps(entry) {
  const ops = [];
  for (const key of ['immutable', 'creatorOnly', 'ownerOnly', 'adminOnly', 'staffOnly', 'serverFields']) {
    if (entry[key]) {
      const f = entry[key].find((x) => !['groupId', 'appId', 'creatorId', 'ownerIds'].includes(x)) || entry[key][0];
      ops.push({ op: 'update', variant: `lock:${key}:${f}`, changes: { [f]: 'changed-by-client' } });
    }
  }
  if (entry.protectedRoleField) {
    ops.push({ op: 'update', variant: `lock:protectedRoleField:${entry.protectedRoleField}`, changes: (actor) => ({ [entry.protectedRoleField]: actor }) });
  }
  if (entry.readerMayUpdate) {
    const f = entry.readerMayUpdate[0];
    ops.push({ op: 'update', variant: `reader:${f}`, changes: { [f]: 'changed-by-reader' } });
  }
  if (entry.staffOnlyValues) {
    const { field, values } = entry.staffOnlyValues;
    ops.push({ op: 'update', variant: `lock:staffOnlyValues:${field}=${values[0]}`, changes: { [field]: values[0] } });
  }
  return ops;
}

/** The fixture app of a collection: the app its field locks apply to, its own app, else beta. */
const appFor = (entry) => (entry.staffOnlyAppIds ? entry.staffOnlyAppIds[0] : (entry.apps ? entry.apps[0] : W.APP_BETA));

/**
 * Fixture docs, as functions of the actor. Reader-field collections get the
 * creator's uid in that field too, so own/other also test the reader grant.
 */
function fixtures(entry) {
  const app = appFor(entry);
  const base = (creator, extra = {}) => {
    const d = { groupId: W.GROUP_A, appId: app, creatorId: creator, ownerIds: [creator], title: 't', ...extra };
    if (entry.readerField) d[entry.readerField] = creator;
    if (entry.readerListField) d[entry.readerListField] = [creator];
    if (entry.clientReaderListField) d[entry.clientReaderListField] = [creator];
    if (entry.protectedRoleField) {
      d[entry.protectedRoleField] = W.AUTHOR;
      d.memberIds = [W.AUTHOR, creator];
    }
    return d;
  };
  return {
    own: (a) => base(a),
    other: () => base(W.AUTHOR),
    otherShared: () => base(W.AUTHOR, { appId: W.APP_ALPHA }),
    adminOnly: () => base(W.AUTHOR, { __admin_only: true }),
    clearance3: () => base(W.AUTHOR, { __required_clearance: 3 }),
    publicB: () => base(W.AUTHOR, { groupId: W.GROUP_B, visibility: 'public' }),
    groupB: () => base(W.AUTHOR, { groupId: W.GROUP_B }),
    ownInB: (a) => base(a, { groupId: W.GROUP_B }),
    missingGroup: () => { const d = base(W.AUTHOR); delete d.groupId; return d; },
    guestApp: () => base(W.AUTHOR, { appId: W.APP_GAMMA }),
    ownGuestApp: (a) => base(a, { appId: W.APP_GAMMA }),
    segApp: () => base(W.AUTHOR, { appId: W.APP_SEG }),
    frozenOwn: (a) => base(a, { groupId: W.GROUP_FROZEN, appId: W.APP_BETA }),
    related: () => base(W.AUTHOR, { groupId: W.GROUP_B, relatedAppId: W.APP_ALPHA }),
    coOwned: () => base(W.AUTHOR, { ownerIds: [W.AUTHOR, 'u-co-owner'] }),
  };
}

const CORE_FIXTURES = ['own', 'other', 'groupB'];
const BASIC_VARIANTS = new Set(['get', 'create', 'benign', 'delete']);
const WRITE_VARIANT_FIXTURES = new Set(['own', 'other', 'groupB', 'ownInB', 'ownGuestApp', 'selfId']);

function docOps(entry, full) {
  const ops = [
    { op: 'get', variant: 'get' },
    { op: 'create', variant: 'create' },
    { op: 'update', variant: 'benign', changes: { title: 'changed' } },
    { op: 'delete', variant: 'delete' },
  ];
  if (!full) return ops;
  return [
    ...ops,
    // Natural-key ids (plan 4.6): tagged with the doc's own group, or another's.
    { op: 'create', variant: 'create:ownTaggedId', id: (d) => `${d.groupId || 'none'}__k` },
    { op: 'create', variant: 'create:otherTaggedId', id: () => `${W.GROUP_B}__k` },
    { op: 'create', variant: 'create:naturalKeyId', id: () => 'my-natural-key' },
    { op: 'create', variant: 'create:wrongApp', changes: { appId: 'zz-not-this-app' } },
    { op: 'update', variant: 'moveGroup', changes: { groupId: W.GROUP_B } },
    { op: 'update', variant: 'moveApp', changes: { appId: W.APP_ALPHA } },
    { op: 'update', variant: 'claim', changes: (a) => ({ creatorId: a, ownerIds: [a] }) },
    { op: 'update', variant: 'share', changes: (a) => ({ ownerIds: [W.AUTHOR, a] }) },
    ...lockOps(entry),
  ];
}

const where = (...triples) => triples;

function listOps(entry, full) {
  const app = appFor(entry);
  const ops = [
    { variant: 'list:groupId+appId', where: where(['groupId', '==', W.GROUP_A], ['appId', '==', app]) },
    { variant: 'list:groupId', where: where(['groupId', '==', W.GROUP_A]) },
  ];
  if (!full) return ops;
  ops.push(
    { variant: 'list:groupId+creatorId', where: (a) => where(['groupId', '==', W.GROUP_A], ['creatorId', '==', a]) },
    { variant: 'list:creatorId', where: (a) => where(['creatorId', '==', a]) },
    { variant: 'list:otherGroup', where: where(['groupId', '==', W.GROUP_B], ['appId', '==', app]) },
    { variant: 'list:none', where: where() },
    { variant: 'list:relatedAppId', where: where(['relatedAppId', '==', W.APP_ALPHA]) },
  );
  if (entry.readerField) ops.push({ variant: `list:${entry.readerField}`, where: (a) => where([entry.readerField, '==', a]) });
  if (entry.readerListField) {
    ops.push({ variant: `list:${entry.readerListField}`, where: (a) => where([entry.readerListField, 'array-contains', a]) });
  }
  if (entry.clientReaderListField) {
    // ScopedCollection.queryAsClient's shape.
    ops.push({
      variant: `list:groupId+${entry.clientReaderListField}`,
      where: (a) => where(['groupId', '==', W.GROUP_A], [entry.clientReaderListField, 'array-contains', a]),
    });
  }
  return ops;
}

/** Every collection the matrix covers, with its table entry ({} if none). */
function matrixCollections(table) {
  const out = {};
  for (const [name, entry] of Object.entries(table.collections)) out[name] = entry;
  out[W.UNDECLARED] = {};
  return out;
}

/** Equivalence classes: { signature: [collection, ...] }, representative first. */
function equivalenceClasses(table) {
  const policies = gen.collectionPolicies(table);
  const classes = {};
  for (const [name, entry] of Object.entries(matrixCollections(table))) {
    const unique = name === 'groups' || isPersonal(entry);
    // Which app a single-app collection names doesn't change its policy class.
    const policy = { ...(policies[name] || {}) };
    if (policy.apps) policy.apps = policy.apps.length === 1 ? 'single' : policy.apps.length;
    const sig = unique ? `name:${name}` : JSON.stringify({
      policy,
      serverFields: entry.serverFields || [],
      subcollections: entry.subcollections || {},
      readerMayUpdate: entry.readerMayUpdate || [],
      readerMayDelete: entry.readerMayDelete || false,
    });
    (classes[sig] = classes[sig] || []).push(name);
  }
  for (const members of Object.values(classes)) {
    members.sort((a, b) => (a === W.UNDECLARED ? -1 : b === W.UNDECLARED ? 1 : a.localeCompare(b)));
  }
  return classes;
}

const resolve = (x, actor) => (typeof x === 'function' ? x(actor) : x);

/** The declared collection-group names, plus one undeclared. */
function collectionGroupNames(table) {
  return [...Object.keys(gen.collectionGroups(table)), 'children'];
}

function collectionGroupCases(table, personas) {
  const cases = [];
  for (const name of collectionGroupNames(table)) {
    for (const persona of personas) {
      const a = persona === 'anon' ? 'anon' : persona;
      for (const [variant, w] of [
        ['cg:groupId', where(['groupId', '==', W.GROUP_A])],
        ['cg:otherGroup', where(['groupId', '==', W.GROUP_B])],
        ['cg:uid', where(['uid', '==', a])],
        ['cg:userId', where(['userId', '==', a])],
        ['cg:none', where()],
      ]) {
        cases.push({
          key: `cg:${name} | ${persona} | query | ${variant}`,
          collection: name, collectionGroup: name, persona, fixture: 'query', op: 'list', variant, path: name, where: w, seed: {},
        });
      }
    }
  }
  return cases;
}

/**
 * The cases. Each:
 *   { key, collection, persona, fixture, op, variant, path, id,
 *     seed: {path: data}, data (create payload / update changes), where (list),
 *     sub, subId, collectionGroup, exclusive (path shared with other cases: run alone) }
 */
function generateMatrix({ table = gen.loadTable(), full = false, personas = W.PERSONA_IDS } = {}) {
  const collections = matrixCollections(table);
  const classes = equivalenceClasses(table);
  const representative = new Set(Object.values(classes).map((m) => m[0]));
  const cases = [];

  for (const [c, entry] of Object.entries(collections)) {
    const isFull = full || representative.has(c);
    const fx = fixtures(entry);
    const fixtureNames = isFull ? Object.keys(fx) : CORE_FIXTURES;
    const selfId = isPersonal(entry);

    for (const persona of personas) {
      const actorUid = persona === 'anon' ? 'anon' : persona;
      for (const fname of [...fixtureNames, ...(selfId ? ['selfId'] : [])]) {
        const docFor = fname === 'selfId' ? () => ({ title: 't', uid: actorUid }) : fx[fname];
        const stored = docFor(actorUid);
        for (const o of docOps(entry, isFull)) {
          if (fname === 'selfId' && !['get', 'create', 'update', 'delete'].includes(o.op)) continue;
          if (o.variant.startsWith('create:') && !['own', 'ownInB', 'ownGuestApp'].includes(fname)) continue;
          // Shape fixtures (flags, other apps, missing tenant...) run the
          // basic operations only; the write variants run on the core ones.
          if (!BASIC_VARIANTS.has(o.variant) && !WRITE_VARIANT_FIXTURES.has(fname)) continue;
          const key = `${c} | ${persona} | ${fname} | ${o.variant}`;
          const changes = resolve(o.changes, actorUid);
          const data = o.op === 'create' ? { ...stored, ...(o.variant === 'create:wrongApp' ? changes : {}) } : changes;
          const id = fname === 'selfId' ? actorUid : (o.id ? `${o.id(stored)}-${autoId(key).slice(0, 6)}` : autoId(key));
          const path = `${c}/${id}`;
          cases.push({
            key, collection: c, persona, fixture: fname, op: o.op, variant: o.variant, path, id,
            seed: o.op === 'create' ? {} : { [path]: stored },
            data,
            exclusive: fname === 'selfId',
            full: isFull,
          });
        }
      }
      if (isFull) {
        // A get of a doc that doesn't exist, under a tenant-tagged id.
        for (const g of [W.GROUP_A, W.GROUP_B]) {
          const key = `${c} | ${persona} | missing | get:${g}__`;
          const id = `${g}__missing-${autoId(key).slice(0, 6)}`;
          cases.push({ key, collection: c, persona, fixture: 'missing', op: 'get', variant: `get:${g}__`, path: `${c}/${id}`, id, seed: {}, full: true });
        }
      }
      for (const l of listOps(entry, isFull)) {
        cases.push({
          key: `${c} | ${persona} | query | ${l.variant}`,
          collection: c, persona, fixture: 'query', op: 'list', variant: l.variant,
          path: c, where: resolve(l.where, actorUid), seed: {}, full: isFull,
        });
      }
      if (!isFull) continue;

      // Subcollections: declared ones, plus a generic pair under the default.
      const subs = Object.keys(entry.subcollections || {});
      if (c === W.UNDECLARED) subs.push(...DEFAULT_SUBS);
      for (const sub of subs) {
        const selfKeyed = (entry.subcollections || {})[sub]?.selfKeyed;
        const parentFixtures = sub === 'comments' ? ['own', 'other', 'groupB', 'related'] : ['own', 'other', 'groupB'];
        for (const pf of [...parentFixtures, ...(selfId ? ['selfId'] : [])]) {
          const parentDoc = pf === 'selfId' ? { title: 't', uid: actorUid } : fx[pf](actorUid);
          for (const subKind of ['other', 'self']) {
            const subId = subKind === 'self' ? actorUid : 'sub1';
            const stored = selfKeyed
              ? { userId: subId, ...Object.fromEntries(selfKeyed.fields.filter((f) => f !== 'userId').map((f) => [f, 'pending'])) }
              : { title: 't', authorId: W.AUTHOR };
            const createData = selfKeyed
              ? Object.fromEntries(selfKeyed.fields.map((f) => [f, f === 'userId' ? actorUid : 'yes']))
              : { title: 't', authorId: actorUid };
            const changes = selfKeyed
              ? { [selfKeyed.fields.find((f) => f !== 'userId')]: 'changed' }
              : { title: 'changed' };
            for (const op of ['get', 'create', 'update', 'delete']) {
              const key = `${c}/${sub} | ${persona} | ${pf}/${subKind} | ${op}`;
              const parentId = pf === 'selfId' ? actorUid : autoId(key);
              const parentPath = `${c}/${parentId}`;
              const path = `${parentPath}/${sub}/${subId}`;
              const seed = { [parentPath]: parentDoc };
              if (op !== 'create') seed[path] = stored;
              cases.push({
                key, collection: c, sub, subId, persona, fixture: `${pf}/${subKind}`, op, variant: op,
                path, id: parentId, parentPath, seed,
                data: op === 'create' ? createData : op === 'update' ? changes : undefined,
                exclusive: pf === 'selfId',
                full: true,
              });
            }
          }
        }
      }
    }
  }
  cases.push(...collectionGroupCases(table, personas));
  return { cases, classes, collections: Object.keys(collections) };
}

/**
 * What the 2025-12-16 permissive release granted everywhere and the rules
 * must not (stage 7 removed the open mode that reproduced it): for every
 * declared collection and the undeclared default, a doc of another group,
 * every operation, at each of [depths] ('top', 'sub' one subcollection
 * down, 'deep' two down), an unfiltered top-level list, and the
 * collection-group queries.
 */
function everyCollectionCases({ table = gen.loadTable(), personas = ['anon', 'u-member', 'u-admin'], depths = ['deep'] } = {}) {
  const cases = [];
  const names = [...Object.keys(table.collections), W.UNDECLARED];
  for (const c of names) {
    for (const persona of personas) {
      const a = persona === 'anon' ? 'anon' : persona;
      const doc = { groupId: W.GROUP_B, appId: 'zz', creatorId: 'u-somebody', ownerIds: ['u-somebody'], title: 't' };
      for (const [depth, suffix] of [['top', ''], ['sub', '/kids/k1'], ['deep', '/kids/k1/grandkids/g1']].filter(([d]) => depths.includes(d))) {
        for (const op of ['get', 'create', 'update', 'delete']) {
          const key = `every | ${c} | ${persona} | ${depth} | ${op}`;
          const parentId = autoId(key);
          const path = `${c}/${parentId}${suffix}`;
          cases.push({
            key, collection: c, persona, fixture: depth, op, variant: op, path, id: parentId,
            sub: depth === 'top' ? undefined : 'kids', subId: depth === 'top' ? undefined : 'k1', deep: depth === 'deep',
            parentPath: depth === 'top' ? undefined : `${c}/${parentId}`,
            seed: op === 'create' ? {} : { [path]: doc },
            data: op === 'create' ? { ...doc, creatorId: a } : op === 'update' ? { title: 'x', groupId: 'moved' } : undefined,
          });
        }
      }
      cases.push({
        key: `every | ${c} | ${persona} | query | list:none`,
        collection: c, persona, fixture: 'query', op: 'list', variant: 'list:none', path: c, where: [], seed: {},
      });
    }
  }
  cases.push(...collectionGroupCases(table, personas));
  return cases;
}

module.exports = {
  generateMatrix, everyCollectionCases, equivalenceClasses, matrixCollections, fixtures, appFor, autoId, collectionGroupNames,
};
