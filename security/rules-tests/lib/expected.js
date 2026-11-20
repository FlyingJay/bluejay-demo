'use strict';
/**
 * The expected-outcome evaluator: a readable JS statement of what
 * firestore.rules decide, read from the same table (security/collections.json)
 * the rules are generated from. The matrix (test/matrix.test.js) asserts
 * the emulator agrees with it on every case. It is the target spec of plan
 * 6.2 item 4, and the thing a reviewer reads.
 *
 * Tenant isolation on every path (inTenant), detail that only narrows, the
 * collection kinds, and the reviewed exceptions EX-ADMIN-1, EX-DEV-1,
 * EX-STEWARD-1. An undeclared collection is kind tenant. The `public` kind
 * (D2) holds published projections: any signed-in user reads, no client
 * writes; a tenant doc's `visibility` grants nothing. Nothing deeper than
 * collection/doc/subcollection/doc is allowed.
 *
 * Firestore rules semantics modelled here:
 * - A request is allowed if ANY matching match block allows it.
 * - Three-valued logic: reading a missing field, or `get()` of a missing doc
 *   then `.data`, is an error. `a || b` is true if either is true, `a && b`
 *   false if either is false, otherwise an error propagates; an error at the
 *   top denies.
 * - List queries: `resource.data` holds only the fields the query pins with
 *   `==` (or `array-contains`); `.get(f, default)` of an unpinned field is the
 *   default (T2 spike 4), and the doc id is unknown (comparisons with it are
 *   errors).
 */

const gen = require('../../generate');

const ERR = Symbol('error');
/** Stands for `request.time` (a server timestamp) in a request's data. */
const REQUEST_TIME = Symbol('request.time');

// ---------------------------------------------------------------------------
// Three-valued helpers
// ---------------------------------------------------------------------------

const isErr = (v) => v === ERR;
const val = (x) => (typeof x === 'function' ? x() : x);

function or(...xs) {
  let err = false;
  for (const x of xs) {
    const v = val(x);
    if (v === true) return true;
    if (v === ERR || typeof v !== 'boolean') err = true;
  }
  return err ? ERR : false;
}

function and(...xs) {
  let err = false;
  for (const x of xs) {
    const v = val(x);
    if (v === false) return false;
    if (v === ERR || typeof v !== 'boolean') err = true;
  }
  return err ? ERR : true;
}

const not = (v) => (typeof v === 'boolean' ? !v : ERR);
/** `c ? a : b` (an error condition is an error). */
const cond = (c, a, b) => { const v = val(c); return v === true ? val(a) : v === false ? val(b) : ERR; };

function deepEq(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((x, i) => deepEq(x, b[i]));
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const ka = Object.keys(a);
    return ka.length === Object.keys(b).length && ka.every((k) => deepEq(a[k], b[k]));
  }
  return a === b;
}

const eq = (a, b) => (isErr(a) || isErr(b) ? ERR : deepEq(a, b));

/** `d.get(k, def)`. */
function getOr(d, k, def) {
  if (isErr(d) || d == null || typeof d !== 'object') return ERR;
  return Object.prototype.hasOwnProperty.call(d, k) ? d[k] : def;
}

function inList(x, list) {
  if (isErr(x) || !Array.isArray(list)) return ERR;
  return list.some((y) => deepEq(x, y));
}

function hasAny(list, items) {
  if (!Array.isArray(list) || !Array.isArray(items) || items.some(isErr)) return ERR;
  return items.some((i) => list.some((y) => deepEq(i, y)));
}

const hasOnly = (list, allowed) => (!Array.isArray(list) || !Array.isArray(allowed)
  ? ERR : list.every((i) => allowed.includes(i)));

function concat(...parts) {
  if (parts.some((p) => isErr(p) || typeof p !== 'string')) return ERR;
  return parts.join('');
}

const matches = (s, re) => (isErr(s) || typeof s !== 'string' || isErr(re) ? ERR : new RegExp(re).test(s));

/** `after.diff(before).affectedKeys()` as a list. */
function affectedKeys(after, before) {
  const keys = new Set([...Object.keys(after), ...Object.keys(before)]);
  return [...keys].filter((k) => !(k in after) || !(k in before) || !deepEq(after[k], before[k]));
}

// ---------------------------------------------------------------------------
// Known issues: decisions the suite pins although they look wrong.
// ---------------------------------------------------------------------------

/**
 * None in the rules logic any more: T6 fixed every issue T2 pinned
 * (categories writes, admin-only blocks, ownership and public grants across
 * tenants, per-doc __admin_only in lists, the CE and Insurance Admin app ids,
 * suspended platform roles). Kept as the place to record one.
 */
const KNOWN_ISSUES = {
  'KI-DENY-PATH-COST': 'A denied request that runs out of the 1000-expression budget before a rule says no. The decision is still deny; test/cost.test.js and the matrix pin where it happens.',
};

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------

const ID_AUTO = '^[A-Za-z0-9]{20}$';
/** Identity fields ScopedCollection stamps on every create. */
const SHIM_IDENTITY_FIELDS = ['groupId', 'appId', 'creatorId', 'ownerIds'];
const ID_UUID = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';

/**
 * Builds the evaluator for a table (default: security/collections.json, as
 * committed). evaluate(req) -> { allow: boolean, knownIssues: string[] }
 *
 * req = {
 *   uid,              // null when signed out
 *   index,            // the caller's access index, or null if there is none
 *   op,               // 'get' | 'list' | 'create' | 'update' | 'delete'
 *   collection, id,   // top-level collection and doc id (id null for lists)
 *   before,           // stored doc (get/update/delete), or the query's pinned fields (list)
 *   after,            // the doc as written (create/update)
 *   sub, subId,       // set for subcollection requests
 *   deep,             // true for a doc deeper than one subcollection
 *   parent,           // stored parent doc for subcollection requests (null if missing)
 *   collectionGroup,  // set for collection-group queries (the subcollection name)
 *   docs,             // other docs the rules may get(), by path
 * }
 */
function createEvaluator(table = gen.loadTable()) {
  const policies = gen.collectionPolicies(table);
  const serverFieldsMap = gen.serverFieldsByCollection(table);
  const readerWritesMap = gen.readerWritesByCollection(table);
  const selfKeyed = gen.selfKeyedSubcollections(table);
  const serverWrittenSubs = gen.serverWrittenSubcollections(table);
  const selfReadSubs = new Set(gen.selfReadSubcollections(table));
  const subPolicies = gen.subcollectionPolicies(table);
  const groups = gen.collectionGroups(table);

  const policy = (c) => policies[c] || {};
  const pget = (p, k, def) => (k in p ? p[k] : def);

  return function evaluate(req) {
    const uid = req.uid;
    const auth = uid != null;
    const ix = req.index || ERR; // get(.../access_index).data
    const idx = (k, def) => getOr(ix, k, def);
    const isList = req.op === 'list';
    // The doc id: unknown in a list query.
    const id = isList ? ERR : req.id;
    const idEq = (x) => (isErr(id) ? ERR : id === x);

    const isActive = () => eq(idx('status', 'INACTIVE'), 'ACTIVE');
    const hasRole = (role) => and(isActive, () => hasAny(idx('roles', []), [role]));

    // -- pillar 2 ---------------------------------------------------------
    const inTenant = (g) => and(isActive, () => typeof g === 'string', () => g !== '',
      () => inList(g, idx('groups', [])), () => not(inList(g, idx('denied_scopes', []))));
    const isMember = (g) => and(() => inTenant(g), () => not(inList(g, idx('guest_groups', []))));

    function scopeOf(p, d) {
      const apps = pget(p, 'apps', []);
      return concat(getOr(d, 'groupId', ''), ':', apps.length === 1 ? apps[0] : getOr(d, 'appId', ''));
    }
    const isOwner = (d) => or(() => eq(getOr(d, 'creatorId', ''), uid), () => inList(uid, getOr(d, 'ownerIds', [])));

    function detail(p, action, c, d) {
      const ents = idx('entitlements', []);
      const scope = scopeOf(p, d);
      const own = isOwner(d);
      const t = (suffix) => concat(scope, suffix);
      return and(
        () => {
          const level = idx('clearance_level', 0);
          return isErr(level) || typeof level !== 'number' ? ERR : level >= pget(p, 'requiredClearance', 0);
        },
        () => or(
          () => hasAny(ents, [t(':admin')]),
          () => and(
            !pget(p, 'adminOnlyCollection', false),
            () => or(!pget(p, 'ownerScoped', false), own),
            () => or(
              () => hasAny(ents, [t(':edit')]),
              () => and(action === 'read', () => or(
                () => hasAny(ents, [scope]),
                // A guest's collection scope reads only guestShareable collections.
                () => and(() => hasAny(ents, [t(`:collection:${c}`)]), () => or(
                  pget(p, 'guestShareable', false),
                  () => not(inList(getOr(d, 'groupId', ''), idx('guest_groups', [])))),
                ))),
              () => and(own, action === 'read' || pget(p, 'writeTier', 'base') === 'base', () => or(
                () => hasAny(ents, [scope]),
                () => and(pget(p, 'guestWritable', false), () => hasAny(ents, [t(':guest')])))),
            ),
          ),
        ),
      );
    }
    const grantTenant = (p, action, c, d) => and(() => inTenant(getOr(d, 'groupId', '')), () => detail(p, action, c, d));
    // EX-ADMIN-1, EX-DEV-1, EX-STEWARD-1
    const grantAdminRead = () => hasRole('admin');
    const grantAdminWrite = (p) => and(pget(p, 'adminWritable', false), () => hasRole('admin'));
    const grantAdminComment = (p) => and(pget(p, 'adminComments', false), () => or(() => hasRole('admin'), () => hasRole('developer')));
    const grantDeveloperRead = (p) => and(pget(p, 'developerRead', false), () => hasRole('developer'));
    const grantDeveloperWrite = (p) => and(pget(p, 'developerWritable', false), () => hasRole('developer'));
    const grantStewardRead = (p, d) => and(pget(p, 'stewardRead', false), isActive,
      () => not(eq(getOr(d, 'relatedAppId', ''), '')),
      () => hasAny(idx('entitlements', []), [concat('app:', getOr(d, 'relatedAppId', ''), ':steward')]));
    const isReader = (p, d) => or(
      () => and(pget(p, 'readerField', '') !== '', () => eq(getOr(d, pget(p, 'readerField', ''), ''), uid)),
      () => and(pget(p, 'readerListField', '') !== '', () => inList(uid, getOr(d, pget(p, 'readerListField', ''), []))),
    );
    const isClientReader = (p, d) => and(
      () => pget(p, 'clientReaderListField', '') !== '',
      () => inList(uid, getOr(d, pget(p, 'clientReaderListField', ''), [])),
      () => inTenant(getOr(d, 'groupId', '')),
      () => hasAny(idx('entitlements', []), [concat(scopeOf(p, d), ':guest')]),
    );
    const platformWrite = (p) => or(() => grantAdminWrite(p), () => grantDeveloperWrite(p));

    function readByIndex(p, c, d) {
      const k = pget(p, 'kind', 'tenant');
      return or(grantAdminRead, () => grantDeveloperRead(p), () => isReader(p, d), () => and(k === 'tenant', () => or(
        () => grantTenant(p, 'read', c, d),
        () => isClientReader(p, d),
        () => and(pget(p, 'staffApps', []).length > 0, () => isCollectionStaff(p, d)),
        () => and(pget(p, 'memberRead', false), () => isMember(getOr(d, 'groupId', ''))),
        () => grantStewardRead(p, d),
        () => grantAdminComment(p),
      )));
    }

    function docRead(c, d, p) {
      const k = pget(p, 'kind', 'tenant');
      if (k === 'personal') return or(() => idEq(uid), grantAdminRead, () => grantDeveloperRead(p));
      // public (D2): published projections; any signed-in reader.
      if (k === 'platform' || k === 'public') return true;
      return readByIndex(p, c, d);
    }

    // -- writes -------------------------------------------------------------
    function tenantIdOk(d, p) {
      const g = getOr(d, 'groupId', '');
      return or(() => matches(id, ID_AUTO), () => matches(id, ID_UUID), () => eq(id, g),
        () => matches(id, isErr(g) ? ERR : `^${g}__.+$`),
        () => and(pget(p, 'idPattern', '') !== '', () => matches(id, isErr(g) ? ERR
          : pget(p, 'idPattern', '').split('<groupId>').join(g).split('<uid>').join(uid))));
    }

    function isCollectionStaff(p, d) {
      const apps = pget(p, 'staffApps', []);
      const g = getOr(d, 'groupId', '');
      const ents = idx('entitlements', []);
      return or(() => hasRole('admin'), () => and(() => inTenant(g), () => or(
        () => and(apps.length > 0, () => hasAny(ents, [concat(g, ':', apps[0], ':edit'), concat(g, ':', apps[0], ':admin')])),
        () => and(apps.length > 1, () => hasAny(ents, [concat(g, ':', apps[1], ':edit'), concat(g, ':', apps[1], ':admin')])),
      )));
    }

    function staffOnlyOk(p, before, after, touched) {
      const lockedApps = pget(p, 'staffOnlyAppIds', []);
      const valueRule = pget(p, 'staffOnlyValues', {});
      const valueField = valueRule.field || '';
      const touchesFields = and(() => or(lockedApps.length === 0, () => inList(getOr(before, 'appId', ''), lockedApps)),
        () => hasAny(touched, pget(p, 'staffOnly', [])));
      const setsValue = and(valueField !== '', () => hasAny(touched, [valueField]),
        () => inList(getOr(after, valueField, null), valueRule.values || []));
      return or(() => and(() => not(touchesFields), () => not(setsValue)), () => isCollectionStaff(p, before));
    }

    function fieldLocksOk(p, before, after, changed) {
      const isAdmin = () => hasRole('admin');
      const roleField = pget(p, 'protectedRoleField', '');
      const host = getOr(before, roleField, '');
      return and(
        () => not(hasAny(changed, pget(p, 'immutable', []))),
        () => or(() => not(hasAny(changed, pget(p, 'creatorOnly', []))), isAdmin, () => eq(getOr(before, 'creatorId', ''), uid)),
        () => or(() => not(hasAny(changed, pget(p, 'ownerOnly', []))), isAdmin, () => inList(uid, getOr(before, 'ownerIds', []))),
        () => or(() => not(hasAny(changed, pget(p, 'adminOnly', []))), isAdmin),
        () => or(roleField === '', isAdmin, () => and(
          () => eq(getOr(after, roleField, ''), host),
          () => or(() => not(hasAny(getOr(before, 'memberIds', []), [host])), () => hasAny(getOr(after, 'memberIds', []), [host])),
          () => or(() => not(hasAny(getOr(before, 'ownerIds', []), [host])), () => hasAny(getOr(after, 'ownerIds', []), [host])),
        )),
        () => staffOnlyOk(p, before, after, changed),
      );
    }

    const mayMutate = (p, c, d) => or(
      () => and(() => grantTenant(p, 'edit', c, d),
        () => or(!pget(p, 'restrictEditToCreator', false), () => eq(getOr(d, 'creatorId', ''), uid))),
      () => platformWrite(p),
    );

    const serverFieldsKept = (c, keys) => not(hasAny(keys, serverFieldsMap[c] || []));

    // memberWrite: a non-guest member writes their own doc without the app.
    const memberWriteOk = (p, d) => and(pget(p, 'memberWrite', false), () => eq(getOr(d, 'creatorId', ''), uid),
      () => or(pget(p, 'readerField', '') === '', () => eq(getOr(d, pget(p, 'readerField', ''), ''), uid)),
      () => isMember(getOr(d, 'groupId', '')));

    // auditTrail: every write stamps lastModifiedAt (the request time) and lastModifiedBy (the caller).
    const auditStampOk = (p, d, touched) => or(!pget(p, 'auditTrail', false), () => and(
      () => hasAny(touched, ['lastModifiedAt']),
      () => eq(getOr(d, 'lastModifiedAt', null), REQUEST_TIME),
      () => eq(getOr(d, 'lastModifiedBy', ''), uid),
    ));

    function tenantCreate(p, c, d) {
      const apps = pget(p, 'apps', []);
      return and(
        !pget(p, 'blockCreate', false),
        () => eq(getOr(d, 'creatorId', ''), uid),
        () => or(apps.length === 0, () => inList(getOr(d, 'appId', ''), apps)),
        () => tenantIdOk(d, p),
        () => or(!pget(p, 'singleOwner', false), () => eq(getOr(d, 'ownerIds', []), [uid])),
        () => staffOnlyOk(p, d, d, Object.keys(d)),
        () => auditStampOk(p, d, Object.keys(d)),
        () => or(() => memberWriteOk(p, d), () => grantTenant(p, 'create', c, d), () => platformWrite(p)),
      );
    }

    function docCreate(c, d, p) {
      const k = pget(p, 'kind', 'tenant');
      return and(() => serverFieldsKept(c, Object.keys(d)), () => {
        if (k === 'tenant') return tenantCreate(p, c, d);
        if (k === 'personal') return idEq(uid);
        if (k === 'platform' || k === 'platform_admin') return platformWrite(p);
        return false;
      });
    }

    function readerUpdate(c, before, changed) {
      const cfg = readerWritesMap[c] || {};
      return and((cfg.update || []).length > 0, () => eq(getOr(before, cfg.field || '', ''), uid),
        () => hasOnly(changed, cfg.update || []));
    }
    function readerDelete(c, d) {
      const cfg = readerWritesMap[c] || {};
      return and(cfg.delete === true, () => eq(getOr(d, cfg.field || '', ''), uid));
    }

    function docUpdate(c, before, after, p) {
      const k = pget(p, 'kind', 'tenant');
      const changed = affectedKeys(after, before);
      return and(() => serverFieldsKept(c, changed), () => {
        if (k === 'tenant') {
          return and(!pget(p, 'blockUpdate', false), !pget(p, 'immutableDoc', false),
            () => or(!pget(p, 'blockDelete', false), () => eq(getOr(before, 'deletedAt', null), null),
              () => and(() => eq(getOr(after, 'deletedAt', null), null),
                () => hasOnly(changed, ['deletedAt', 'deletedBy', 'lastModifiedAt', 'lastModifiedBy']))),
            () => not(hasAny(changed, ['groupId', 'appId', 'creatorId'])),
            () => or(() => memberWriteOk(p, after), () => mayMutate(p, c, before)),
            () => auditStampOk(p, after, changed),
            () => fieldLocksOk(p, before, after, changed));
        }
        if (k === 'personal') return idEq(uid);
        if (k === 'server') return readerUpdate(c, before, changed);
        if (k === 'platform' || k === 'platform_admin') return platformWrite(p);
        return false;
      });
    }

    function docDelete(c, d, p) {
      const k = pget(p, 'kind', 'tenant');
      if (k === 'server') return readerDelete(c, d);
      if (k === 'public' || pget(p, 'blockDelete', false)) return false;
      if (k === 'tenant') return mayMutate(p, c, d);
      if (k === 'personal') return idEq(uid);
      return platformWrite(p);
    }

    // -- subcollections -----------------------------------------------------
    function subRule(c, p) {
      const k = pget(p, 'kind', 'tenant');
      const parent = req.parent || ERR; // get() of a missing parent, then .data: an error
      const key = `${c}/${req.sub}`;
      const { op } = req;
      const parentId = req.id;
      if (op === 'get' || op === 'list') {
        if (k === 'personal') return or(parentId === uid, grantAdminRead);
        if (k === 'platform') return true;
        if (k === 'tenant' && selfReadSubs.has(key)) {
          // selfKeyedRead(): the keyed uid (a list never pins the id) and
          // platform admins; never the parent app's :admin tier.
          const subId = isList ? ERR : req.subId;
          return or(grantAdminRead,
            () => and(() => (isErr(subId) ? ERR : subId === uid), () => readByIndex(p, c, parent)));
        }
        return readByIndex(p, c, k === 'tenant' ? parent : {});
      }
      // A governed subcollection's selfKeyed config travels in its policy.
      const cfg = (subPolicies[key] && subPolicies[key].selfKeyed) || selfKeyed[key] || { fields: [], selfCreate: false, selfDelete: false };
      const selfWrite = () => and(req.subId === uid, () => {
        if (op === 'create') {
          return and(cfg.selfCreate, () => hasOnly(Object.keys(req.after), [...cfg.fields, ...SHIM_IDENTITY_FIELDS]),
            () => eq(getOr(req.after, 'userId', uid), uid),
            () => eq(getOr(req.after, 'creatorId', uid), uid),
            () => eq(getOr(req.after, 'ownerIds', [uid]), [uid]));
        }
        if (op === 'update') {
          return and(() => hasOnly(affectedKeys(req.after, req.before), cfg.fields), () => eq(getOr(req.after, 'userId', uid), uid));
        }
        return cfg.selfDelete;
      });
      const parentReader = () => or(() => grantTenant(p, 'read', c, parent), () => grantStewardRead(p, parent), () => grantAdminComment(p));
      // governedSubWrite(): a subcollection the table governs.
      const sp = subPolicies[key];
      const governed = () => {
        const author = pget(sp, 'authorField', '');
        const touched = op === 'create' ? Object.keys(req.after || {}) : op === 'update' ? affectedKeys(req.after, req.before) : [];
        const emailField = pget(sp, 'authorEmailField', '');
        const bounded = pget(sp, 'boundedList', {});
        const cleared = pget(sp, 'softDeleteClears', '');
        const createdAt = pget(sp, 'createdAtField', '');
        const fieldsOk = () => and(
          () => auditStampOk(sp, req.after, touched),
          // A new doc carries the parent's tenant and, with authorEmailField, the caller's token email.
          () => or(op !== 'create', () => and(
            () => eq(getOr(req.after, 'groupId', ''), getOr(parent, 'groupId', '')),
            () => eq(getOr(req.after, 'appId', ''), getOr(parent, 'appId', '')),
            () => or(emailField === '', () => eq(getOr(req.after, emailField, null), req.email == null ? null : req.email)),
            () => or(createdAt === '', () => eq(getOr(req.after, createdAt, null), REQUEST_TIME)))),
          () => or(!bounded.field, () => not(hasAny(touched, [bounded.field])), () => {
            const v = getOr(req.after, bounded.field, null);
            return Array.isArray(v) && v.length <= bounded.max;
          }),
          () => or(!pget(sp, 'softDelete', false), () => (op === 'create'
            ? not(hasAny(touched, ['deletedAt', 'deletedBy', 'moderationReason']))
            : and(() => eq(getOr(req.before, 'deletedAt', null), null), () => or(
              () => not(hasAny(touched, ['deletedAt', 'deletedBy'])),
              () => and(() => eq(getOr(req.after, 'deletedAt', null), REQUEST_TIME), () => eq(getOr(req.after, 'deletedBy', ''), uid),
                () => or(cleared === '', () => eq(getOr(req.after, cleared, ''), ''))))))),
        );
        const keyed = Boolean(sp.selfKeyed);
        // selfArrayFields / selfMapFields: a reader marks only their own uid.
        // A list (no duplicates) gains that uid at its end or loses its one
        // copy, the rest unchanged and in order; a map changes only that
        // uid's entry, which is null/absent or a string of at most 64 characters.
        const lists = pget(sp, 'selfArrayFields', []);
        const maps = pget(sp, 'selfMapFields', []);
        const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v) && !isErr(v);
        const selfListOk = (f) => {
          const a = getOr(req.after, f, []);
          const b = getOr(req.before, f, []);
          if (deepEq(a, b)) return true;
          if (!Array.isArray(a) || !Array.isArray(b)) return ERR;
          if (new Set(a.map((x) => JSON.stringify(x))).size !== a.length) return false;
          if (!b.includes(uid)) return deepEq(a, [...b, uid]);
          const without = b.filter((x) => x !== uid);
          return a.length === b.length - 1 && deepEq(a, without);
        };
        const selfEntryOk = (v) => v == null || (typeof v === 'string' && [...v].length <= 64);
        const selfMapOk = (f) => {
          const a = getOr(req.after, f, {});
          const b = getOr(req.before, f, {});
          if (!isMap(a) || !isMap(b)) return ERR;
          return and(() => hasOnly(affectedKeys(a, b), [uid]), () => selfEntryOk(a[uid]));
        };
        const stamps = pget(sp, 'auditTrail', false) ? ['lastModifiedAt', 'lastModifiedBy'] : [];
        const selfFieldsUpdateOk = () => and(lists.length + maps.length > 0,
          () => hasOnly(affectedKeys(req.after, req.before), [...lists, ...maps, ...stamps]),
          ...lists.map((f) => () => selfListOk(f)), ...maps.map((f) => () => selfMapOk(f)));
        const selfFieldsCreateOk = () => and(
          ...lists.map((f) => () => { const v = getOr(req.after, f, []); return deepEq(v, []) || deepEq(v, [uid]); }),
          ...maps.map((f) => () => { const v = getOr(req.after, f, {}); return isMap(v) ? and(() => hasOnly(Object.keys(v), [uid]), () => selfEntryOk(v[uid])) : ERR; }));
        const mayWrite = () => (keyed ? and(selfWrite, sp.selfKeyed.threadReaders ? parentReader : () => grantTenant(p, 'read', c, parent)) : author === ''
          ? mayMutate(p, c, parent)
          : and(() => (op === 'create'
            ? and(() => eq(getOr(req.after, author, ''), uid), selfFieldsCreateOk)
            : or(() => and(() => eq(getOr(req.before, author, ''), uid), () => or(op === 'delete',
              () => hasOnly(affectedKeys(req.after, req.before), [...pget(sp, 'authorMayUpdate', []), 'lastModifiedAt', 'lastModifiedBy']))),
            () => and(op === 'update', selfFieldsUpdateOk))),
          parentReader));
        return and(op === 'delete' ? !pget(sp, 'blockDelete', false) : fieldsOk, mayWrite);
      };
      return and(!serverWrittenSubs[key], () => {
        if (k === 'tenant') {
          // Nothing is written under a soft-deleted parent, whatever the subcollection.
          return and(() => eq(getOr(parent, 'deletedAt', null), null), () => {
            if (sp) return governed();
            return or(
              () => and(!selfKeyed[key] || Boolean(selfKeyed[key].editorsWrite), () => mayMutate(p, c, parent)),
              () => and(Boolean(selfKeyed[key]), selfWrite, () => grantTenant(p, 'read', c, parent)),
              () => and(op === 'create', req.sub === 'comments', () => eq(getOr(req.after, 'authorId', ''), uid), parentReader),
            );
          });
        }
        if (k === 'personal') return parentId === uid;
        if (k === 'platform' || k === 'platform_admin') return platformWrite(p);
        return false;
      });
    }

    // collectionGroupRead(): generated per declared collection group.
    function collectionGroupRead(name, d) {
      return or(...(groups[name] || []).map((cfg) => () => or(
        () => and(Boolean(cfg.readerField), () => eq(getOr(d, cfg.readerField || '', ''), uid)),
        () => and(Boolean(cfg.readApps), () => inTenant(getOr(d, 'groupId', '')),
          () => hasAny(idx('entitlements', []), (cfg.readApps || []).map((a) => concat(getOr(d, 'groupId', ''), `:${a}`)))),
      )));
    }

    // -- the match blocks -------------------------------------------------
    const { op, collection: c } = req;
    const isRead = op === 'get' || op === 'list';
    const p = policy(c);
    const blocks = [];

    if (req.collectionGroup) {
      // match /{path=**}/{group}/{id}: the only block a collection-group query matches.
      const name = req.collectionGroup;
      blocks.push(() => and(auth, () => collectionGroupRead(name, req.before)));
    } else {
      if (!req.sub && !req.deep) {
        // match /{path=**}/{group}/{id} also matches a top-level list.
        if (op === 'list') blocks.push(() => and(auth, () => collectionGroupRead(c, req.before)));
        // match /{collection}/{id}: allow get of a missing tenant-tagged or
        // singleton (id == groupId) doc
        if (op === 'get' && req.before == null) {
          blocks.push(() => and(auth, pget(p, 'kind', 'tenant') === 'tenant', () => or(
            () => inTenant(id),
            () => and(() => matches(id, '^[a-z0-9][a-z0-9-]*__.+$'), () => inTenant(String(id).split('__')[0])))));
        }
        // match /{collection}/{id}
        blocks.push(() => and(auth, () => {
          if (isRead) return docRead(c, req.before, p);
          if (op === 'create') return docCreate(c, req.after, p);
          if (op === 'update') return docUpdate(c, req.before, req.after, p);
          return docDelete(c, req.before, p);
        }));
      } else if (req.sub && !req.deep) {
        // match /{collection}/{id}/{subcollection}/{subId}
        blocks.push(() => and(auth, () => subRule(c, p)));
      }
    }
    const allow = blocks.some((b) => b() === true);
    return { allow, knownIssues: [] };
  };
}

module.exports = { createEvaluator, KNOWN_ISSUES, ERR, REQUEST_TIME, affectedKeys };
