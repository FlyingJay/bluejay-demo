# Rules emulator tests (plan T2)

Emulator tests for `firestore.rules` and `storage.rules`, with the raw JS SDK
(`@firebase/rules-unit-testing` contexts, never the Dart shim)
(`plans/firestore-rules/IMPLEMENTATION_PLAN.md` 6.1-6.2).

Every suite runs the committed `firestore.rules` and `storage.rules` (the
staged open/enforced rollout ended with stage 7, plan 8.3; there is no
other variant). `lib/expected.js` and `lib/expected_storage.js` state what
the rules decide, read from the same tables (`security/collections.json`,
`security/storage_paths.json`), and the tests assert the emulator agrees.

## Run

Needs Node 22, a JDK 11+ for the emulator, and `npm ci` in both
`functions/` (the personas' indexes are built by `functions/_shared.js`) and
here.

```sh
brew install openjdk@21                 # macOS, once; or rely on CI
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 PATH=/opt/homebrew/opt/openjdk@21/bin:$PATH
(cd functions && npm ci) && (cd security/rules-tests && npm ci && npm test)
```

Locally, `npm test` (`scripts/run.js`) is safe to run from any number of
checkouts at once:

- It takes a machine-wide lock (`~/.cache/bluejay-rules-tests/run.lock`), so
  one run executes at a time; the others print who holds it and wait.
- It reuses one shared Firestore + Storage emulator on ports 8782/9782 (hub
  4782, logging 4783), away from `firebase.json`'s dev ports. The first run
  starts it with a detached supervisor. It stops after 20 idle minutes, and
  is restarted when a checkout has a different firebase-tools version, when
  its logs pass 1 GB (a full run writes about that much), and after any
  failed run. Its JVMs are capped at a 3 GB heap. Logs:
  `~/.cache/bluejay-rules-tests/`.
- It runs two test files at a time, and stops a run that passes 45 minutes so
  a hung run can't hold the lock.

`npm run emulator:status` shows the lock holder and the emulator;
`npm run emulator:stop` stops the emulator. Knobs: `RULES_TESTS_CONCURRENCY`,
`RULES_TESTS_EMULATOR_HEAP` (e.g. `4g`), `RULES_TESTS_EMULATOR_IDLE_MIN`,
`RULES_TESTS_EMULATOR_MAX_LOG_MB`, `RULES_TESTS_RUN_TIMEOUT_MIN`,
`RULES_TESTS_LOCK_TIMEOUT_MIN` (default 90), and the `RULES_TESTS_*_PORT`
variables. Don't start your own `emulators:exec` with a copied config to get
around a port clash; that brings back the extra JVMs this setup avoids.
`RULES_TESTS_ISOLATED=1 npm test` runs the suite under its own
`firebase emulators:exec` on `firebase.json`'s ports instead, without the
lock.

Every emulator gets its own `TMPDIR`. Storage emulators keep their blobs in
`$TMPDIR/firebase/storage/blobs` and delete that directory when they stop,
so two sharing a `TMPDIR` crash each other's uploads.

The `demo-` project id means the emulator can never reach production. CI:
`.github/workflows/rules-tests.yml`.

All test files share the one Firestore emulator (a single JVM) and the one
Storage emulator, and every suite uses its own project id, so suites never
see each other's data. Locally, `test/matrix.test.js` runs every matrix
shard, one after another.

CI splits the suite into parallel jobs, each with its own emulators (the
`suite` jobs in `rules-tests.yml`): one per matrix shard
(`RULES_MATRIX_SHARDS`, with `RULES_MATRIX_SHARD=<n>` selecting the job's
shard), one for `test/cost.test.js`, and one for every other test file. The
`rules-tests` job passes when all of them passed. The shards split the cases
round-robin, so each gets the same mix of operations and collections and
they take about as long as each other; to rebalance, change the shard list
and `RULES_MATRIX_SHARDS` together (`scripts/ci/workflow_triggers.test.js`
checks they match).

Every suite opens its environment through `lib/test_env.js`, which clears
the project's data on open (the shared emulator outlives a run, and a killed
run never released its environments), and releasing
it (`releaseTestEnv`, which `setup()`'s `teardown()` calls) deletes the
suite's Firestore project data, and its Storage objects when it has Storage,
before cleaning up. Without that, every seeded world stays in the emulator's
heap for the rest of the run, and by the last matrix shard the emulator slows
down and then fails every rules load with HTTP 500. A failed clear only logs
a warning, and an environment a failing test leaves open is released by an
`after()` hook when its file finishes.

The emulator also keeps what it evaluated for every request (about 10 KB
each) for as long as the ruleset that evaluated it stays loaded, and
clearing data doesn't touch rules. Loading a ruleset drops it. So releasing
an environment also loads a deny-all ruleset into its project, and
`runCases` (`lib/run.js`) reloads the rules between its 4000-case chunks
(`refreshRules()` from `setup()`), which keeps the heap at about one chunk's
worth. Before that, a run's ~190k matrix requests stayed in the heap and
every shard ran slower than the one before.

The emulators write their logs to the repo root (`firestore-debug.log`,
`firebase-debug.log`, and the Storage and UI logs when present). In CI the
JVMs also write a GC log per process (`emulator-gc-<pid>.log`) and a heap
dump on an out-of-memory error. Every job prints each JVM's total GC pause
time and its last collections. When a job fails, it prints the tail of each
log and whether a heap dump exists, and uploads the logs (not the heap dump)
as the `rules-tests-emulator-logs-<part>` artifact (`matrix1`, `cost`,
`other`...), kept for 7 days.

Knobs: `RULES_MATRIX_FULL=1` runs the full matrix for every table entry
(nightly in CI); `RULES_MATRIX_ONLY=<regex>` runs only matching case keys;
`RULES_MATRIX_DUMP=<file>` writes every case's decision and expectation;
`RULES_MATRIX_SHARDS=<n>` (default 3) and `RULES_MATRIX_SHARD=<1..n>` pick
one shard.

## What's here

| File | Role |
|---|---|
| `lib/world.js` | Groups, apps, memberships, segments and the personas (plan 6.2 item 1), described the way production describes users |
| `lib/test_env.js` | Opens and releases emulator test environments; releasing clears the env's data (below) |
| `lib/personas.js` | Seeds the world and builds each persona's access index with the real `buildUserAccessIndex` / `computeEntitlements`, reading the emulator |
| `lib/expected.js` | The expected-spec evaluator: the rules (kinds, `inTenant` + `detail`, the reviewed exceptions) as readable JS, reading `security/collections.json` |
| `lib/generate_matrix.js` | The matrix: every table entry and the undeclared `zz_new_app_items`, persona x fixture x operation, plus collection-group queries; `everyCollectionCases()` for the every-collection denials. Writes nothing to disk |
| `fixtures/live-firestore-2025-12-16.rules` | The 2025-12-16 permissive Firestore release, verbatim: the documented emergency rollback (`security/RULES_ROLLBACK.md`); no test runs it |
| `test/every_collection.test.js` | Every declared collection and the undeclared default: no signed-out access, nothing two subcollections down, collection groups only where declared |
| `lib/expected_storage.js` | The same for `storage.rules`: `targetDecision()` per path family in `security/storage_paths.json` |
| `fixtures/live-storage-2025-12-16.rules` | The 2025-12-16 permissive Storage release, verbatim: the documented emergency rollback; no test runs it |
| `lib/cost.js` | Expression headroom of requests under the 1000-expression limit (the binary searches of many requests share each rules load) |
| `lib/emulator_rules.js` | Loads Firestore rules into a running emulator project |
| `lib/guests.js` | Guests of the four embeddable apps, built with the real guest admission and `buildUserAccessIndex` |
| `lib/run.js` | Runs matrix cases against the emulator with the raw JS SDK |
| `lib/request.js` | Turns a matrix case into the request `lib/expected.js` evaluates |
| `lib/matrix_suite.js` | Splits the matrix into shards (`RULES_MATRIX_*` knobs) |
| `test/matrix.test.js` | The matrix: every shard, or the one `RULES_MATRIX_SHARD` names |
| `test/app_query_shapes.test.js` | The apps' real query shapes (launcher groups, memberships, directory, inbox, settings, own profile) |
| `test/public_namespace.test.js` | The public namespace (D2): `public_<source>` readable by any signed-in user, written by no client; `visibility: 'public'` on a tenant doc grants nothing |
| `test/cost.test.js` | Representative and heaviest requests: decisions and headroom |
| `test/storage.test.js` | Storage path families x personas x operations against the committed rules (with the T2 known issues closed), plus the embeddable-app guest flows |
| `test/personas.test.js` | Pins what the real builder gives each persona |
| `test/spikes.test.js`, `spikes/` | T2 phase-1 spikes, kept as tests |
| `test/guard.test.js` | The model covers every match block; the matrix covers every entry |

## When a test fails

- **A matrix case differs:** either the rules changed behaviour (intended?
  then update `lib/expected.js` in the same PR, so the reviewer sees the
  policy change in readable form) or the evaluator is wrong.
- **Headroom or the expression limit:** a rule got more expensive. Keep
  per-request lookup tables small (see the plan, section 10).
- **The emulator hangs on a request:** a `hasAny([...])` list literal with
  several items derived from `collectionPolicy()` makes the emulator explore
  every combination of the policy lookup's branches. Use one-item lists.

The evaluator reads the same table the rules are generated from, so it
checks the rules' logic and cost, not whether a table entry is the right
policy. That's the reviewer's job on `security/collections.json`.
