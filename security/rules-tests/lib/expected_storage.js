'use strict';
/**
 * storage.rules as a readable model (the Storage counterpart of
 * lib/expected.js; plan T16): targetDecision() is what each path family
 * allows, per security/storage_paths.json. A missing access index is an
 * error, and an error denies, as in the rules.
 *
 * The T2 suite pinned five known issues of the old repo rules; the target
 * closes all of them, and test/storage.test.js asserts each closure
 * (CLOSED_ISSUES below).
 */

const path = require('path');
const gs = require(path.join(__dirname, '..', '..', 'generate_storage'));

const CLOSED_ISSUES = {
  'KI-STORAGE-BARE-SCOPE-EDIT': 'the bare scope no longer edits or deletes other members\' files (needs :edit/:admin)',
  'KI-STORAGE-OWNERSHIP-OUTSIDE-TENANT': 'create and every other grant require the path\'s group in the caller\'s index (inTenant)',
  'KI-STORAGE-OVERWRITE-AS-CREATE': 'an upload over an existing file is an edit of the stored file, whatever rule evaluates it',
  'KI-STORAGE-PUBLIC-CROSS-TENANT': 'visibility metadata is never read',
  'KI-STORAGE-PROFILE-PICTURES': 'profile_pictures/{uid}/… is written only by {uid}; flat legacy objects are read-only',
};

const ERR = Symbol('error');

/** Operations the matrix performs. */
const READ_OPS = ['get', 'list'];
const OPS = ['get', 'list', 'create', 'forge', 'overwrite', 'update', 'retag', 'delete'];

/**
 * The target for one request.
 * req: { uid, index, op, path, meta (stored metadata, or null if no object),
 *        newMeta (metadata the write sends; for update/retag the merged result) }
 * op: get | list (path = the listed prefix) | create (new object) |
 *     forge (new object, creatorId someone else) | overwrite (upload over an
 *     existing object) | update / retag (metadata update) | delete.
 */
function targetDecision(req, table) {
  const { uid, op } = req;
  if (uid == null) return false;
  const p = req.path;
  const seg = p.split('/');
  const family = gs.familyOfPath(table, p);
  const f = table.families[family];
  const isRead = READ_OPS.includes(op);
  const index = req.index || ERR;
  const stored = req.meta || null;
  const incoming = req.newMeta || {};

  const active = () => (index === ERR ? ERR : (index.status || 'INACTIVE') === 'ACTIVE');
  const hasRole = (role) => (index === ERR ? ERR : active() === true && (index.roles || []).includes(role));
  const entitled = (list) => (index === ERR ? ERR : list.some((e) => (index.entitlements || []).includes(e)));
  const inTenant = (g) => (index === ERR ? ERR
    : active() === true && (index.groups || []).includes(g) && !(index.denied_scopes || []).includes(g));
  const or = (...xs) => (xs.some((x) => x === true) ? true : (xs.some((x) => x === ERR) ? ERR : false));
  const and = (...xs) => (xs.some((x) => x === false) ? false : (xs.some((x) => x === ERR) ? ERR : true));

  if (isRead && f.read === 'signedIn') return true;

  if (family === 'group_apps') {
    const [, g, , a] = seg;
    const scope = `${g}:${a}`;
    const mine = (m) => (m && (m.creatorId || '')) === uid;
    // The guest tier counts only in the app's guestWritableFolders (the path's first folder under the app).
    // ...and, writing there, within the app's guestUploadLimits (the upload's
    // size, default the 3-byte fixture, and content type).
    const limit = (f.guestUploadLimits || {})[a];
    const uploadOk = isRead || op === 'delete' || !limit ||
      ((req.size ?? 3) <= limit.maxBytes && new RegExp(`^(?:${limit.contentTypes})$`).test(req.contentType || 'application/octet-stream'));
    const guestHere = () => and(entitled([`${scope}:guest`]),
      ((f.guestWritableFolders || {})[a] || []).includes(seg[4] || ''), uploadOk);
    const mayEditStored = () => and(inTenant(g), or(
      entitled([`${scope}:edit`, `${scope}:admin`]),
      and(mine(stored), or(entitled([scope]), guestHere())),
    ));
    const metaOk = (incoming.groupId || '') === g && (incoming.appId || '') === a;
    const creatorKept = () => (incoming.creatorId || '') === uid || (incoming.creatorId || '') === ((stored && stored.creatorId) || '');
    // retainedFolders: a stored file there takes no client delete, overwrite or metadata change.
    const retained = stored != null && seg.length > 5 && ((f.retainedFolders || {})[a] || []).includes(seg[4]);
    let v;
    if (!isRead && retained) {
      v = false;
    } else if (isRead) {
      v = or(
        and(inTenant(g), or(
          entitled([scope, `${scope}:edit`, `${scope}:admin`]),
          and(stored != null && op === 'get', mine(stored), guestHere()),
        )),
        hasRole('admin'),
      );
    } else if (op === 'delete') {
      v = mayEditStored();
    } else if (stored == null) { // create / forge of a new object
      v = and(metaOk, (incoming.creatorId || '') === uid, inTenant(g),
        or(entitled([scope, `${scope}:edit`, `${scope}:admin`]), guestHere()));
    } else { // overwrite, update, retag
      v = and(metaOk, mayEditStored(), creatorKept());
    }
    return v === true;
  }

  // group_logo: read is generic (signedIn), handled above; no client writes
  // it (groupAdminSetLogo does, server-side).

  if (family === 'app_icons') {
    if (isRead) return false;
    return or(hasRole('admin'), hasRole('developer')) === true;
  }

  if (family === 'profile_pictures') {
    if (seg.length === 3) { // profile_pictures/{uid}/{file}
      const owner = seg[1];
      if (op === 'get') {
        if (uid === owner) return true;
        const theirs = req.subjectIndex ? (req.subjectIndex.groups || []) : ERR;
        return or(hasRole('admin'), and(active(),
          index === ERR || theirs === ERR ? ERR : (index.groups || []).some((x) => theirs.includes(x)))) === true;
      }
      if (op === 'list') return false;
      return uid === owner && (op === 'delete' || (incoming.creatorId || '') === owner);
    }
    if (seg.length === 2) return op === 'get'; // legacy flat: get only
    return false;
  }

  return false; // `none`, and block families with no grant for this op
}

/** -> { allow, family } for a request (see targetDecision). opts: { table }. */
function evaluateStorage(req, { table = gs.loadStorageTable() } = {}) {
  return { allow: targetDecision(req, table), family: gs.familyOfPath(table, req.path) };
}

module.exports = { evaluateStorage, targetDecision, CLOSED_ISSUES, OPS, READ_OPS };
