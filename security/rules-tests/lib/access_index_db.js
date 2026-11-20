'use strict';

/**
 * The emulator's client Firestore, shaped for the server's access-index
 * builder (functions/_shared.js buildUserAccessIndex), which runs on the
 * Admin SDK. The client API has no `getAll`, so batched reads become
 * parallel gets with the same results.
 */
function accessIndexDb(db) {
  if (typeof db.getAll === 'function') return db;
  return new Proxy(db, {
    get(target, prop, receiver) {
      if (prop === 'getAll') return (...refs) => Promise.all(refs.map((ref) => ref.get()));
      const value = Reflect.get(target, prop, receiver);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

module.exports = { accessIndexDb };
