'use strict';
/** Turns a matrix case into the request lib/expected.js evaluates. */

function toRequest(c, indexes) {
  const uid = c.persona === 'anon' ? null : c.persona;
  const req = {
    uid,
    index: indexes[c.persona] || null,
    op: c.op,
    collection: c.collection,
    id: c.id,
    sub: c.sub,
    subId: c.subId,
    docs: c.docs || {},
    deep: Boolean(c.deep),
    collectionGroup: c.collectionGroup,
  };
  if (c.op === 'list') {
    // resource.data in a list query: only the fields the query pins.
    req.before = {};
    for (const [k, op, v] of c.where || []) req.before[k] = op === 'array-contains' ? [v] : v;
    return req;
  }
  if (c.sub) req.parent = c.seed[c.parentPath] || null;
  const stored = c.seed[c.path];
  if (c.op === 'create') req.after = c.data;
  else {
    req.before = stored;
    if (c.op === 'update') req.after = { ...stored, ...c.data };
  }
  return req;
}

module.exports = { toRequest };
