#!/usr/bin/env bash
# Runs every Node test file in the repo — functions/, functions/test/,
# functions/scripts/, mail-proxy/, scripts/ and security/ (any depth) — each in its own `node --test`
# process (except security/rules-tests/, which needs the Firestore emulator and
# runs in .github/workflows/rules-tests.yml), so module-level state (initialised firebase-admin apps, stubbed
# requires) can't leak between files. GOOGLE_APPLICATION_CREDENTIALS is unset
# so no test can reach a real project. functions/ and scripts/security_tier_audit/
# node_modules that are missing, symlinked or behind the lockfile are reinstalled
# first. Prints each failing file's output and exits 1 if any failed.
#
# Usage: scripts/ci/run_node_tests.sh [parallelism]   (default 4)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOBS="${1:-4}"
unset GOOGLE_APPLICATION_CREDENTIALS
cd "$ROOT"

# The dependencies CI installs, as the lockfiles pin them: a node_modules
# borrowed from another checkout fails tests that pass in CI.
node scripts/ci/node_modules_state.js --fix functions scripts/security_tier_audit || exit 1

files=$(
  {
    ls functions/*.test.js functions/test/*.test.js functions/scripts/*.test.js mail-proxy/*.test.js 2>/dev/null
    find scripts security -name '*.test.js' -not -path '*/node_modules/*' -not -path 'security/rules-tests/*'
  } | sort -u
)
logs="$(mktemp -d)"

run_one() {
  local file="$1" logs="$2"
  local log="$logs/$(echo "$file" | tr '/' '_').log"
  if node --test "$file" >"$log" 2>&1; then
    echo "ok   $file"
  else
    echo "FAIL $file"
    touch "$log.failed"
  fi
}
export -f run_one

echo "$files" | xargs -P "$JOBS" -I{} bash -c 'run_one "$1" "$2"' _ {} "$logs"

failed=0
for marker in "$logs"/*.failed; do
  [ -e "$marker" ] || continue
  failed=$((failed + 1))
  log="${marker%.failed}"
  echo "::group::$(basename "$log" .log)"
  cat "$log"
  echo "::endgroup::"
done

total=$(echo "$files" | wc -l | tr -d ' ')
if [ "$failed" -gt 0 ]; then
  echo "::error::$failed of $total Node test file(s) failed"
  exit 1
fi
echo "All $total Node test file(s) passed."
