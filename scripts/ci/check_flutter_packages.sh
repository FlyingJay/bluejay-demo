#!/usr/bin/env bash
# Runs `flutter pub get`, `flutter analyze` (errors fail; warnings and infos
# don't) and, when the package has a test/ directory, `flutter test` for
# each package named on the command line (names under packages/). A package
# can also list IANA time zones, one per line, in packages/<pkg>/ci_test_time_zones;
# its tests then run again with TZ set to each one, for date code whose bugs
# only show in a zone with daylight saving (CI runners default to UTC). Keeps going
# after a failure so one run reports every broken package, then exits 1 if
# any failed.
#
# Usage: scripts/ci/check_flutter_packages.sh calendar groups shared_services
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
failed=()

for pkg in "$@"; do
  dir="$ROOT/packages/$pkg"
  echo "::group::$pkg"
  ok=1
  if ! (cd "$dir" && "$FLUTTER" pub get); then
    echo "::error title=$pkg::flutter pub get failed"
    ok=0
  else
    if ! (cd "$dir" && "$FLUTTER" analyze --no-pub --no-fatal-infos --no-fatal-warnings); then
      echo "::error title=$pkg::flutter analyze reported errors"
      ok=0
    fi
    # Per-test timeout: a hung test fails in minutes, not testWidgets' 10.
    if [ -d "$dir/test" ] && ! (cd "$dir" && "$FLUTTER" test --no-pub --timeout 120s); then
      echo "::error title=$pkg::flutter test failed"
      ok=0
    fi
    if [ -d "$dir/test" ] && [ -f "$dir/ci_test_time_zones" ]; then
      while IFS= read -r zone || [ -n "$zone" ]; do
        zone="${zone%%#*}"
        zone="$(echo "$zone" | tr -d '[:space:]')"
        [ -n "$zone" ] || continue
        echo "Re-running $pkg tests with TZ=$zone"
        if ! (cd "$dir" && TZ="$zone" "$FLUTTER" test --no-pub --timeout 120s); then
          echo "::error title=$pkg::flutter test failed with TZ=$zone"
          ok=0
        fi
      done < "$dir/ci_test_time_zones"
    fi
  fi
  echo "::endgroup::"
  [ "$ok" = 1 ] || failed+=("$pkg")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Failed packages: ${failed[*]}"
  exit 1
fi
echo "All ${#} package(s) passed."
