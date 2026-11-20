#!/bin/bash
# Adds this computer to bluejay's dispatch worker pool: scheduled jobs that
# claim queued Improve Apps / App Maker / Projects / Security Audit jobs
# from claude_jobs and hand each to the local `claude` CLI, which
# implements it and opens a PR (.claude/skills/implement-claude-job).
# See scripts/dev_worker/README.md.
#
# Runs on:
#   macOS    a launchd job per worker (~/Library/LaunchAgents)
#   Windows  inside WSL2 (setup.ps1 sets that up): a Task Scheduler task per worker (BluejayDevWorker<n>)
#            starts the worker in WSL every minute, so no WSL window has to stay open
#   Linux    a crontab line per worker
# DEV_WORKER_PLATFORM=darwin|wsl|linux overrides the detection.
#
# Usage: scripts/dev_worker/setup.sh <command> [options]
#
#   install [--workers N] [--dir DIR] [--token-stdin] [--replace-legacy]
#       Checks the machine (doctor), saves the worker token if this machine
#       has no admin key, clones one dedicated copy of the repo per worker
#       (DIR/w1, DIR/w2, ...; default ~/bluejay-workers), writes the
#       settings file and schedules one job per worker. Re-running it
#       updates the jobs in place. --token-stdin reads the token from stdin
#       instead of prompting. --replace-legacy (macOS) unloads the older
#       com.bluejay.ticket-dispatch(.w2) jobs (their clones are left alone).
#   doctor         Checks tools, sign-ins and credentials; changes nothing.
#   status         This machine's workers: scheduled or not, paused or not,
#                  whether a job is running, recent log lines.
#   pause|resume   Stop or restart claiming new jobs on this computer (a flag
#                  file every tick checks). A job already running finishes.
#   uninstall [--now]
#                  Removes the scheduled jobs; refuses while a job is running
#                  unless --now. Leaves the clones, the token and the
#                  settings file (paths are printed).
#
# Each worker id is claude-local-<host>-<n>, unique across the pool. The
# pool itself (every machine's workers, tokens, pausing) is in the Dev
# Workers app.
set -uo pipefail

REPO_URL="${BLUEJAY_REPO_URL:-https://github.com/bluejayorg/bluejay.git}"
REPO_SLUG="bluejayorg/bluejay"
CONFIG_DIR="$HOME/.config/bluejay"
TOKEN_FILE="$CONFIG_DIR/dev-worker-token"
SETTINGS_FILE="$CONFIG_DIR/dev-worker.env"
PAUSE_FILE="${DEV_WORKER_PAUSE_FILE:-$CONFIG_DIR/dev-worker.paused}"
ADMIN_KEY="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/bluejay_keys/bluejay-firebase-adminsdk.json}"
LAUNCH_AGENTS="${DEV_WORKER_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
LABEL_PREFIX="com.bluejay.dev-worker"
LEGACY_LABELS="com.bluejay.ticket-dispatch com.bluejay.ticket-dispatch.w2"
TASK_PREFIX='BluejayDevWorker'
CRON_MARK='# bluejay-dev-worker-'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/com.bluejay.dev-worker.plist.template"
WORKER_SCRIPT="$SCRIPT_DIR/../firestore_admin/dev_queue_worker.js"

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/flutter/bin:$PATH"

detect_platform() {
  if [ -n "${DEV_WORKER_PLATFORM:-}" ]; then echo "$DEV_WORKER_PLATFORM"; return; fi
  case "$(uname -s)" in
    Darwin) echo darwin ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *) echo unsupported ;;
  esac
}
PLATFORM="$(detect_platform)"
# Matches poll_and_dispatch.sh's log location.
if [ "$PLATFORM" = darwin ]; then
  LOG_DIR="$HOME/Library/Logs/bluejay-ticket-dispatch"
  INSTALL_HINT="brew install"
  GH_INSTALL_HINT="brew install gh"
else
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/bluejay-ticket-dispatch"
  INSTALL_HINT="sudo apt install"
  # Ubuntu's own gh package is older than GH_MIN_VERSION.
  GH_INSTALL_HINT="install it from GitHub's apt repository: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
fi

# The job skills run gh pr view and gh pr edit, which fail in older gh on GitHub's retired
# Projects (classic) API. wsl_bootstrap.sh installs at least this version on Windows.
GH_MIN_VERSION=2.82.0
gh_version() { gh --version 2>/dev/null | sed -n 's/^gh version \([0-9][0-9.]*\).*/\1/p'; }
# version_at_least <version> <minimum>, for dotted numeric versions; an empty version fails.
version_at_least() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a == "") exit 1
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0
  }'
}

PROBLEMS=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }
die()  { printf '%s\n' "$1" >&2; exit 1; }

# This machine's short name for worker ids: lowercase letters, digits, "-".
host_key() {
  local name
  name="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname)"
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-40
}

# ---------------------------------------------------------------------------
# Schedulers. Each implements <kind>_install <n> <worker key> <clone>,
# <kind>_remove <n>, <kind>_list (installed worker numbers) and
# <kind>_state <n>; sched dispatches to this platform's.
# ---------------------------------------------------------------------------

# launchd (macOS)
launchd_label() { echo "$LABEL_PREFIX.$1"; }
launchd_loaded() { launchctl list 2>/dev/null | awk '{ print $3 }' | grep -qx "$1"; }
launchd_install() {
  local label plist
  label="$(launchd_label "$1")"
  plist="$LAUNCH_AGENTS/$label.plist"
  mkdir -p "$LAUNCH_AGENTS"
  sed -e "s#__LABEL__#$label#g" -e "s#__CLONE__#$3#g" -e "s#__WORKER_KEY__#$2#g" -e "s#__LOG_DIR__#$LOG_DIR#g" \
    "$TEMPLATE" > "$plist"
  launchd_loaded "$label" && launchctl unload "$plist" 2>/dev/null
  launchctl load "$plist"
}
launchd_remove() {
  local plist
  plist="$LAUNCH_AGENTS/$(launchd_label "$1").plist"
  [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null
  rm -f "$plist"
}
launchd_list() {
  ls "$LAUNCH_AGENTS" 2>/dev/null | sed -n "s/^${LABEL_PREFIX}\.\([0-9][0-9]*\)\.plist$/\1/p" | sort -n
}
launchd_state() {
  if launchd_loaded "$(launchd_label "$1")"; then echo scheduled; else echo "not loaded"; fi
}

# Task Scheduler (Windows, driven from inside WSL through interop). Each
# task runs a small VBScript that starts the worker in this WSL distro with
# no console window and waits for it to finish.
win_dir() {
  local appdata
  appdata="$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
  [ -n "$appdata" ] || return 1
  echo "$(wslpath -u "$appdata")/bluejay"
}
# At the top level: a standard user may not be able to create a Task Scheduler folder.
task_name() { printf '%s%s' "$TASK_PREFIX" "$1"; }
wsl_install() {
  local dir vbs distro
  distro="${WSL_DISTRO_NAME:-}"
  [ -n "$distro" ] || die "WSL_DISTRO_NAME is not set: run setup.sh inside WSL."
  dir="$(win_dir)" || die "Could not find %LOCALAPPDATA% through WSL interop."
  mkdir -p "$dir"
  vbs="$dir/dev-worker-$1.vbs"
  # The distro name goes unquoted: wsl.exe takes -d "Ubuntu" to mean a distro named "Ubuntu"
  # with the quotes, and fails with WSL_E_DISTRO_NOT_FOUND. WSL distro names have no spaces.
  {
    printf "' bluejay dispatch worker %s (claude-local-%s). Generated by scripts/dev_worker/setup.sh.\r\n" "$1" "$2"
    printf 'CreateObject("WScript.Shell").Run "wsl.exe -d %s -u %s -- /bin/bash ""%s/scripts/firestore_admin/poll_and_dispatch.sh"" --worker %s", 0, True\r\n' \
      "$distro" "$(id -un)" "$3" "$2"
  } > "$vbs"
  schtasks.exe /Create /F /SC MINUTE /MO 1 /TN "$(task_name "$1")" \
    /TR "wscript.exe //B //Nologo \"$(wslpath -w "$vbs")\"" >/dev/null
}
wsl_remove() {
  local dir
  schtasks.exe /Delete /F /TN "$(task_name "$1")" >/dev/null 2>&1
  dir="$(win_dir)" && rm -f "$dir/dev-worker-$1.vbs"
  return 0
}
wsl_list() {
  schtasks.exe /Query /FO CSV /NH 2>/dev/null | tr -d '\r' \
    | sed -n "s/^\"\\\\${TASK_PREFIX}\([0-9][0-9]*\)\".*/\1/p" | sort -un
}
wsl_state() {
  if schtasks.exe /Query /TN "$(task_name "$1")" >/dev/null 2>&1; then echo scheduled; else echo missing; fi
}

# cron (other Linux)
# The rest of the crontab, read in full before anything is written back.
cron_without() {
  local current
  current="$(crontab -l 2>/dev/null)"
  printf '%s\n' "$current" | grep -v "$CRON_MARK$1\$" | sed '/^$/d'
}
cron_install() {
  local line="* * * * * /bin/bash \"$3/scripts/firestore_admin/poll_and_dispatch.sh\" --worker $2 >/dev/null 2>&1 $CRON_MARK$1"
  local rest
  rest="$(cron_without "$1")"
  { [ -n "$rest" ] && printf '%s\n' "$rest"; echo "$line"; } | crontab -
}
cron_remove() {
  local rest
  rest="$(cron_without "$1")"
  printf '%s\n' "$rest" | sed '/^$/d' | crontab -
}
cron_list() { crontab -l 2>/dev/null | sed -n "s/.*$CRON_MARK\([0-9][0-9]*\)$/\1/p" | sort -n; }
cron_state() {
  if cron_list | grep -qx "$1"; then echo scheduled; else echo missing; fi
}

sched() {
  local op="$1"
  shift
  case "$PLATFORM" in
    darwin) "launchd_$op" "$@" ;;
    wsl) "wsl_$op" "$@" ;;
    linux) "cron_$op" "$@" ;;
    *) die "This platform isn't supported: use macOS, Windows with WSL2, or Linux." ;;
  esac
}

has_admin_key() { [ -f "$ADMIN_KEY" ]; }
# The admin transport needs firebase-admin (scripts/firestore_admin or functions/node_modules).
admin_deps_installed() {
  [ -d "$SCRIPT_DIR/../firestore_admin/node_modules/firebase-admin" ] || [ -d "$SCRIPT_DIR/../../functions/node_modules/firebase-admin" ]
}
has_token() { [ -s "$TOKEN_FILE" ] || [ -n "${BLUEJAY_WORKER_TOKEN:-}" ]; }

is_laptop() {
  pmset -g batt 2>/dev/null | grep -q InternalBattery && return 0
  ls /sys/class/power_supply/BAT* >/dev/null 2>&1
}

cpu_count() { sysctl -n hw.ncpu 2>/dev/null || nproc; }

flutter_path() {
  if [ -n "${FLUTTER:-}" ] && [ -x "$FLUTTER" ]; then echo "$FLUTTER"; return; fi
  if command -v flutter >/dev/null 2>&1; then command -v flutter; return; fi
  if [ -x "$HOME/flutter/bin/flutter" ]; then echo "$HOME/flutter/bin/flutter"; return; fi
  return 1
}

doctor() {
  PROBLEMS=0
  echo "Checking this computer:"
  case "$PLATFORM" in
    darwin) ok "macOS (launchd)" ;;
    wsl)
      if command -v schtasks.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        ok "Windows with WSL ($WSL_DISTRO_NAME); Task Scheduler starts the workers"
      else
        bad "WSL can't reach Windows (schtasks.exe not found): turn on WSL interop"
      fi
      case "$SCRIPT_DIR" in
        /mnt/*) warn "this checkout is on a Windows drive: clone into WSL's own disk (e.g. ~/bluejay) for speed" ;;
      esac
      ;;
    linux)
      if command -v crontab >/dev/null 2>&1; then ok "Linux (cron)"; else bad "crontab is not installed ($INSTALL_HINT cron)"; fi
      ;;
    *) bad "unsupported platform: use macOS, Windows with WSL2, or Linux" ;;
  esac

  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "$major" -ge 18 ]; then ok "node $(node -v)"; else bad "node 18 or newer is required (found $(node -v))"; fi
  else
    bad "node is not installed (version 18 or newer; see scripts/dev_worker/README.md)"
  fi

  if command -v git >/dev/null 2>&1; then ok "git"; else bad "git is not installed ($INSTALL_HINT git)"; fi

  if ! command -v gh >/dev/null 2>&1; then
    bad "GitHub CLI is not installed ($GH_INSTALL_HINT, then gh auth login)"
  elif ! version_at_least "$(gh_version)" "$GH_MIN_VERSION"; then
    bad "GitHub CLI $(gh_version) is too old: jobs need $GH_MIN_VERSION or newer ($GH_INSTALL_HINT)"
  elif ! gh auth status >/dev/null 2>&1; then
    bad "GitHub CLI is not signed in (gh auth login, then gh auth setup-git)"
  elif [ "$(gh api "repos/$REPO_SLUG" --jq .permissions.push 2>/dev/null)" != "true" ]; then
    bad "your GitHub account can't push to $REPO_SLUG (ask for write access)"
  else
    ok "GitHub CLI signed in with push access to $REPO_SLUG"
  fi

  if ! command -v claude >/dev/null 2>&1; then
    bad "Claude Code is not installed (see scripts/dev_worker/README.md)"
  elif claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
    ok "Claude Code signed in ($(claude auth status 2>/dev/null | sed -n 's/.*"email": *"\([^"]*\)".*/\1/p'))"
  else
    bad "Claude Code is not signed in (claude auth login)"
  fi

  if flutter_path >/dev/null; then
    ok "Flutter ($(flutter_path))"
  else
    warn "Flutter not found (PATH, \$FLUTTER or ~/flutter): Flutter changes skip their local checks and rely on CI"
  fi
  if [ -n "${JAVA_HOME:-}" ] || [ -d /opt/homebrew/opt/openjdk@21 ] || command -v java >/dev/null 2>&1; then
    ok "JDK (rules emulator tests)"
  else
    warn "JDK 21 not found: rules changes skip the emulator tests locally"
  fi

  if has_admin_key; then
    ok "Firebase admin key ($ADMIN_KEY): workers also take app jobs"
  elif has_token; then
    ok "worker token ($TOKEN_FILE)"
  else
    bad "no worker token: create one in Dev Workers → Add a computer, then run install"
  fi

  if has_admin_key && ! admin_deps_installed; then
    bad "the admin key needs firebase-admin: run (cd scripts/firestore_admin && npm ci), or install does it"
  elif [ -f "$WORKER_SCRIPT" ] && { has_admin_key || has_token; }; then
    local err
    err="$(mktemp)"
    if (cd "$SCRIPT_DIR/../.." && node scripts/firestore_admin/dev_queue_worker.js list >/dev/null 2>"$err"); then
      ok "the job queue is reachable"
    else
      bad "can't reach the job queue: $(tail -1 "$err")"
    fi
    rm -f "$err"
  fi

  if is_laptop; then
    warn "this is a laptop: consider DEV_WORKER_REQUIRE_AC_POWER=1 in $SETTINGS_FILE"
  fi
  return "$PROBLEMS"
}

save_token() {
  local token="$1"
  case "$token" in
    bjw_*) ;;
    *) die "That doesn't look like a worker token (they start with bjw_)." ;;
  esac
  mkdir -p "$CONFIG_DIR"
  (umask 077 && printf '%s\n' "$token" > "$TOKEN_FILE")
  chmod 600 "$TOKEN_FILE"
  echo "Saved the worker token to $TOKEN_FILE."
}

write_settings() {
  [ -f "$SETTINGS_FILE" ] && return
  mkdir -p "$CONFIG_DIR"
  local laptop=0 cpus
  is_laptop && laptop=1
  cpus="$(cpu_count)"
  cat > "$SETTINGS_FILE" <<EOF
# Settings for this computer's bluejay dispatch workers, read by
# scripts/firestore_admin/poll_and_dispatch.sh on every tick (no reload
# needed). See scripts/dev_worker/README.md.

# Skip a tick when the load average is above this many times the core count.
export TICKET_DISPATCH_MAX_LOAD_PER_CORE=1.0

# 1: only work while plugged in.
export DEV_WORKER_REQUIRE_AC_POWER=$laptop

# Hours to stay idle, local time, e.g. 9-18 for 9:00 to 17:59. Empty: none.
export DEV_WORKER_QUIET_HOURS=

# Parallel Flutter shards in each job's local checks (scripts/ci/local_check.sh).
export LOCAL_CHECK_JOBS=$(( cpus / 4 > 1 ? cpus / 4 : 1 ))

# Tool locations, if not on the default paths.
# export FLUTTER=\$HOME/flutter/bin/flutter
# export JAVA_HOME=/path/to/jdk-21
EOF
  echo "Wrote $SETTINGS_FILE (edit it any time)."
}

prepare_clone() {
  local dir="$1"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q origin main && git -C "$dir" checkout -q main && git -C "$dir" reset -q --hard origin/main \
      || die "Could not update $dir."
  elif [ -e "$dir" ]; then
    die "$dir exists and isn't a clone: pick another --dir."
  else
    mkdir -p "$(dirname "$dir")"
    git clone -q "$REPO_URL" "$dir" || die "Could not clone $REPO_URL into $dir."
  fi
  if has_admin_key; then
    (cd "$dir/scripts/firestore_admin" && npm ci --silent >/dev/null 2>&1) || die "npm ci failed in $dir/scripts/firestore_admin."
  fi
}

install() {
  local workers=1 dir="$HOME/bluejay-workers" token_stdin=0 replace_legacy=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workers) workers="$2"; shift ;;
      --dir) dir="$2"; shift ;;
      --token-stdin) token_stdin=1 ;;
      --replace-legacy) replace_legacy=1 ;;
      *) die "install: unknown option $1" ;;
    esac
    shift
  done
  case "$workers" in ''|*[!0-9]*|0) die "--workers must be a positive number." ;; esac

  if ! has_admin_key && ! has_token; then
    local token=""
    if [ "$token_stdin" = 1 ]; then
      read -r token
    else
      echo "Create a worker token in Dev Workers → Add a computer, then paste it here."
      read -r -s -p "Worker token: " token
      echo
    fi
    save_token "$token"
  fi

  if has_admin_key && ! admin_deps_installed; then
    echo "Installing firebase-admin for the admin key (npm ci in scripts/firestore_admin)..."
    (cd "$SCRIPT_DIR/../firestore_admin" && npm ci --silent >/dev/null 2>&1) || die "npm ci failed in scripts/firestore_admin."
  fi

  if ! doctor; then
    echo
    die "Fix the failures above, then run install again."
  fi
  echo

  local host
  host="$(host_key)"
  [ -n "$host" ] || die "Could not work out a name for this computer."
  mkdir -p "$LOG_DIR"
  write_settings

  local i key clone
  for i in $(seq 1 "$workers"); do
    key="$host-$i"
    clone="$dir/w$i"
    echo "Worker $i: claude-local-$key, clone $clone"
    prepare_clone "$clone"
    sched install "$i" "$key" "$clone" || die "Could not schedule worker $i."
  done

  # Workers numbered above --workers from an earlier install are removed.
  for i in $(sched list); do
    if [ "$i" -gt "$workers" ]; then
      sched remove "$i"
      echo "Removed worker $i (its clone $dir/w$i is left in place)."
    fi
  done

  local legacy
  for legacy in $LEGACY_LABELS; do
    [ -f "$LAUNCH_AGENTS/$legacy.plist" ] || continue
    if [ "$replace_legacy" = 1 ]; then
      launchctl unload "$LAUNCH_AGENTS/$legacy.plist" 2>/dev/null
      rm -f "$LAUNCH_AGENTS/$legacy.plist"
      echo "Unloaded the older $legacy job (its clone is left in place)."
    else
      echo "Note: the older $legacy job is still installed. Re-run with --replace-legacy to retire it."
    fi
  done

  echo
  [ -f "$PAUSE_FILE" ] && echo "Note: this computer is paused; setup.sh resume starts claiming again."
  echo "Done. This computer runs $workers worker(s); they check in within a minute and"
  echo "show in Dev Workers. Logs: $LOG_DIR/dispatch.log"
}

# How many of this computer's workers are in the middle of a job (their lock is held).
running_workers() {
  local n=0 lock
  for lock in /tmp/bluejay-ticket-dispatch*.lock; do
    [ -d "$lock" ] && n=$((n + 1))
  done
  echo "$n"
}

status() {
  local i any=0
  for i in $(sched list); do
    any=1
    echo "worker $i: $(sched state "$i")"
  done
  [ "$any" = 1 ] || echo "No workers are installed on this computer."
  [ -f "$PAUSE_FILE" ] && echo "Paused since $(cat "$PAUSE_FILE"): no new jobs are claimed (setup.sh resume)."
  echo "Jobs running now: $(running_workers)"
  if [ -f "$LOG_DIR/dispatch.log" ]; then
    echo
    echo "Recent activity ($LOG_DIR/dispatch.log):"
    grep -E 'dispatching:|claude exited|released:|stopping:|error:' "$LOG_DIR/dispatch.log" | tail -5
  fi
}

pause() {
  mkdir -p "$CONFIG_DIR"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$PAUSE_FILE"
  echo "Paused: this computer claims no new jobs until setup.sh resume."
  echo "Jobs already running finish on their own ($(running_workers) now)."
}

resume() {
  rm -f "$PAUSE_FILE"
  echo "Resumed: the next tick claims work again."
}

uninstall() {
  local i
  if [ "$(running_workers)" != 0 ] && [ "${1:-}" != "--now" ]; then
    die "A worker is in the middle of a job, and removing it now would lose that attempt. Run setup.sh pause, wait until setup.sh status shows no jobs running, or pass --now."
  fi
  for i in $(sched list); do
    sched remove "$i"
    echo "Removed worker $i."
  done
  echo "Left in place: the clones (default ~/bluejay-workers), $TOKEN_FILE and $SETTINGS_FILE."
  echo "Revoke the token in Dev Workers if this computer is leaving the pool."
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  install) install "$@" ;;
  doctor) doctor; exit $? ;;
  status) status ;;
  pause) pause ;;
  resume) resume ;;
  uninstall) uninstall "$@" ;;
  *) sed -n '2,38p' "$0"; exit 2 ;;
esac
