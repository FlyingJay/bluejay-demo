#!/usr/bin/env bash
# Runs locally what CI would run for this branch, so a PR can be fixed while
# it's still a draft and marked ready once (CLAUDE.md, "Draft PRs and local
# checks"). scripts/ci/local_plan.js decides what runs from the diff against
# the base ref, with the same code tests.yml's plan job and the workflows'
# path filters use:
#
#   copy rules    scripts/ci/copy_lint.js on the lines this branch adds,
#                 as the PR checks job does (always runs; with --committed
#                 only committed lines count)
#   automations   scripts/automations/contract.js --check --diff <base> and
#                 field_check.js, as the PR checks job does (always runs)
#   security      node security/generate.js --check, check_rules_exceptions.js
#                 and check_server_collections.js (rules or tier-audit inputs changed)
#   tier audit    scripts/security_tier_audit/audit.js --diff <base>; with
#                 GOOGLE_APPLICATION_CREDENTIALS set it also fails on a tier
#                 regression, as the PR check does
#   node          scripts/ci/run_node_tests.sh
#   flutter       scripts/ci/check_flutter_packages.sh for the planned packages,
#                 split into shards that run in parallel
#   flutter root  flutter analyze lib + flutter test for the launcher app
#   rules         security/rules-tests in the emulator; opt-in with --rules
#
# Usage: scripts/ci/local_check.sh [--rules] [--base <ref>] [--committed]
#                                  [--jobs N] [--no-fetch] [--plan]
#   --rules      also run the rules emulator tests (needs JDK 21)
#   --base       ref to diff against (default origin/main, fetched first)
#   --committed  plan from commits only, as CI does; by default uncommitted
#                and untracked files count too
#   --jobs N     parallel Flutter package shards (default $LOCAL_CHECK_JOBS, else 4)
#   --no-fetch   don't fetch the base first
#   --plan       print the plan and exit
#
# Tools: Flutter from $FLUTTER, then PATH, then ~/flutter/bin/flutter. JDK
# from $JAVA_HOME, then /opt/homebrew/opt/openjdk@21. Missing, symlinked or
# out-of-date node_modules are installed with npm ci. Exits 1 if any check failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

BASE="origin/main"
RULES=0
COMMITTED=""
JOBS="${LOCAL_CHECK_JOBS:-4}"
FETCH=1
PLAN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rules) RULES=1 ;;
    --base) BASE="$2"; shift ;;
    --committed) COMMITTED="--committed" ;;
    --jobs) JOBS="$2"; shift ;;
    --no-fetch) FETCH=0 ;;
    --plan) PLAN_ONLY=1 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

START=$(date +%s)
STUB=0
remove_stub() { [ "$STUB" = 1 ] && rm -f "$ROOT/lib/firebase_options.dart"; STUB=0; return 0; }
trap remove_stub EXIT
# Stop the parallel Flutter shards too when interrupted.
trap 'kill $(jobs -p) 2>/dev/null; exit 130' INT TERM
LOGS="$(mktemp -d "${TMPDIR:-/tmp}/local_check.XXXXXX")"
RESULTS=()
FAILED=0

record() { # name status seconds
  RESULTS+=("$(printf '%-14s %-5s %4ss' "$1" "$2" "$3")")
  [ "$2" = "FAIL" ] && FAILED=1
  return 0
}

# Runs "$@" as step <name>, timing it.
step() {
  local name="$1"; shift
  local t0; t0=$(date +%s)
  echo
  echo "=== $name ==="
  if "$@"; then record "$name" ok $(( $(date +%s) - t0 ))
  else record "$name" FAIL $(( $(date +%s) - t0 )); fi
}

# Installs node_modules when missing, symlinked from another checkout, or
# behind the lockfile (scripts/ci/node_modules_state.js).
ensure_node_modules() { # dir
  node scripts/ci/node_modules_state.js --fix "$1"
}

if [ "$FETCH" = 1 ] && [[ "$BASE" == origin/* ]]; then
  git fetch --quiet origin "${BASE#origin/}" || echo "warning: could not fetch $BASE; planning against the local copy"
fi

PLAN="$(node scripts/ci/local_plan.js --base "$BASE" --shards "$JOBS" $COMMITTED)" || { echo "planning failed" >&2; exit 2; }
plan_value() { printf '%s\n' "$PLAN" | sed -n "s/^$1=//p" | head -1; }
SHARDS=()
while IFS= read -r line; do SHARDS+=("$line"); done < <(printf '%s\n' "$PLAN" | sed -n 's/^flutter_shard=//p')

echo "Plan against $BASE ($(plan_value files) changed file(s)${COMMITTED:+, commits only}):"
printf '%s\n' "$PLAN" | grep -v '^flutter_shard=' | sed 's/^/  /'
if [ "$(plan_value rules)" = true ] && [ "$RULES" = 0 ]; then
  echo
  echo "NOTICE: this change touches the rules suite's inputs (security/, the rules files"
  echo "        or the access functions). CI runs the rules emulator tests on it; run"
  echo "        them here with --rules before marking the PR ready."
fi
[ "$PLAN_ONLY" = 1 ] && exit 0

# --- tools -------------------------------------------------------------------
resolve_flutter() {
  if [ -n "${FLUTTER:-}" ]; then echo "$FLUTTER"; return; fi
  if command -v flutter >/dev/null 2>&1; then command -v flutter; return; fi
  if [ -x "$HOME/flutter/bin/flutter" ]; then echo "$HOME/flutter/bin/flutter"; return; fi
  return 1
}

NEEDS_FLUTTER=0
{ [ "$(plan_value flutter_count)" != 0 ] || [ "$(plan_value flutter_root)" = true ]; } && NEEDS_FLUTTER=1
if [ "$NEEDS_FLUTTER" = 1 ]; then
  if FLUTTER="$(resolve_flutter)"; then
    export FLUTTER
    want="$(sed -n "s/^  FLUTTER_VERSION: '\(.*\)'/\1/p" .github/workflows/tests.yml)"
    have="$("$FLUTTER" --version 2>/dev/null | sed -n 's/^Flutter \([^ ]*\).*/\1/p')"
    echo "Flutter: $FLUTTER ($have)"
    [ -n "$want" ] && [ "$have" != "$want" ] && echo "warning: CI uses Flutter $want; results can differ."
  else
    echo "Flutter not found (set FLUTTER, put it on PATH, or install it at ~/flutter)."
    record flutter FAIL 0
    NEEDS_FLUTTER=0
  fi
fi

# --- checks ------------------------------------------------------------------
copy_rules() {
  if [ -n "$COMMITTED" ]; then node scripts/ci/copy_lint.js --base "$BASE"
  else node scripts/ci/copy_lint.js --base "$BASE" --worktree; fi
}
step "copy rules" copy_rules

automation_contracts() {
  ensure_node_modules functions || return 1
  local status=0
  node scripts/automations/contract.js --check --diff "$BASE" || status=1
  node scripts/automations/field_check.js || status=1
  return $status
}
step "automations" automation_contracts

security_checks() {
  node security/generate.js --check &&
    node security/check_rules_exceptions.js &&
    node security/check_server_collections.js
}
[ "$(plan_value security)" = true ] && step security security_checks

tier_audit() {
  ensure_node_modules scripts/security_tier_audit || return 1
  local flags=()
  if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    flags=(--with-declared --fail-on-regression)
  else
    echo "(GOOGLE_APPLICATION_CREDENTIALS unset: structural diff only. The PR check also"
    echo " reads apps/{appId} and fails on a tier regression.)"
  fi
  # ${flags[@]+...}: bash 3.2 (macOS) treats an empty array as unset under set -u.
  # The merge base: CI diffs the PR's merge commit against main, which is this
  # branch's own changes. Diffing against the base's tip would also count
  # whatever landed on main since the branch was cut.
  local base_sha
  base_sha="$(git merge-base "$BASE" HEAD)" || return 1
  (cd scripts/security_tier_audit && node audit.js --diff "$base_sha" ${flags[@]+"${flags[@]}"})
}
[ "$(plan_value tier_audit)" = true ] && step "tier audit" tier_audit

node_suite() {
  ensure_node_modules functions && ensure_node_modules scripts/security_tier_audit &&
    scripts/ci/run_node_tests.sh 4
}
[ "$(plan_value node)" = true ] && step node node_suite

flutter_packages() {
  local i=0 pids=() logs=() rc=0
  for shard in "${SHARDS[@]}"; do
    i=$((i + 1))
    local log="$LOGS/flutter_shard_$i.log"
    logs+=("$log")
    echo "shard $i: $shard"
    # shellcheck disable=SC2086 # the shard is a space-separated package list
    scripts/ci/check_flutter_packages.sh $shard >"$log" 2>&1 &
    pids+=($!)
  done
  # Progress every 60s: packages finished so far (one ::endgroup:: each).
  local total
  total="$(plan_value flutter_count)"
  (
    while sleep 60; do
      echo "  flutter: $(cat "${logs[@]}" 2>/dev/null | grep -c '^::endgroup::')/$total package(s) done"
    done
  ) &
  local ticker=$!
  for j in "${!pids[@]}"; do
    if ! wait "${pids[$j]}"; then
      rc=1
      echo "--- shard $((j + 1)) failed; failing packages' output:"
      grep -E '^::error|^Failed packages' "${logs[$j]}"
      echo "    full log: ${logs[$j]}"
    fi
  done
  kill "$ticker" 2>/dev/null
  [ "$rc" = 0 ] && echo "All $total package(s) passed."
  return "$rc"
}
[ "$NEEDS_FLUTTER" = 1 ] && [ "$(plan_value flutter_count)" != 0 ] && step flutter flutter_packages

flutter_root() {
  # As in tests.yml: analysis and tests only need the symbol to exist.
  local rc=0
  if [ ! -f lib/firebase_options.dart ]; then
    STUB=1
    cat > lib/firebase_options.dart <<'EOF'
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform =>
      throw UnsupportedError('CI stub: no Firebase options');
}
EOF
  fi
  # On macOS, pub get copies the iOS/macOS Swift packages into
  # build/<platform>/SourcePackages and fails when those folders don't exist
  # yet (a fresh worktree). CI runs on Linux, which skips that step.
  [ "$(uname)" = Darwin ] && mkdir -p build/ios/SourcePackages build/macos/SourcePackages
  local pub_log="$LOGS/root_pub_get.log"
  "$FLUTTER" pub get >"$pub_log" 2>&1 || { tail -20 "$pub_log"; remove_stub; return 1; }
  "$FLUTTER" analyze --no-pub --no-fatal-infos --no-fatal-warnings lib &&
    "$FLUTTER" test --no-pub --timeout 120s || rc=1
  remove_stub
  return "$rc"
}
[ "$NEEDS_FLUTTER" = 1 ] && [ "$(plan_value flutter_root)" = true ] && step "flutter root" flutter_root

rules_tests() {
  # npm test waits for the machine-wide rules-test lock and reuses the shared
  # emulator (security/rules-tests/scripts/shared_emulator.js), so other
  # checkouts' runs and dev emulators don't get in the way.
  ensure_node_modules functions && ensure_node_modules security/rules-tests &&
    (cd security/rules-tests && npm test)
}
if [ "$RULES" = 1 ]; then
  if [ "$(plan_value rules)" = true ]; then step rules rules_tests
  else echo; echo "(--rules: nothing the rules suite reads changed; skipped, as CI would.)"; fi
fi

# --- summary -----------------------------------------------------------------
echo
echo "=== local check summary ($(( $(date +%s) - START ))s) ==="
if [ "${#RESULTS[@]}" -eq 0 ]; then
  echo "  nothing to run for this diff (CI would skip its suites too)"
else
  printf '  %s\n' "${RESULTS[@]}"
fi
if [ "$(plan_value rules)" = true ] && [ "$RULES" = 0 ]; then
  echo "  rules          not run (pass --rules; CI will run it)"
fi
if [ "$FAILED" = 1 ]; then
  echo "FAILED. Fix these before marking the PR ready. Logs: $LOGS"
  exit 1
fi
echo "PASSED."
rm -rf "$LOGS"
