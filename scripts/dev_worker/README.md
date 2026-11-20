# Dispatch worker pool

Queued development work (Improve Apps bugs and ideas, App Maker requests,
Projects tasks, Security Audit reports) becomes `claude_jobs` when the
development queue's scheduler grants it a slot. Dispatch workers claim those
jobs and run Claude Code on them, one job per worker at a time. Claude
implements the job, runs the local checks, and opens a PR for review
(`.claude/skills/implement-claude-job`).

Any Mac, Windows (through WSL2) or Linux computer with Claude Code can join
the pool. Each worker runs `scripts/firestore_admin/poll_and_dispatch.sh`
every minute from its own dedicated clone. The scheduler depends on the
platform: launchd on macOS, Windows Task Scheduler on Windows, cron on Linux.
More computers means more jobs building at once, and the builds and tests run
on the worker's own machine.

## Join the pool

You need the platform `developer` role (or platform admin), a GitHub
account with push access to `bluejayorg/bluejay`, and a Claude account.
Flutter and JDK 21 are optional: without them, jobs skip those local
checks and CI runs them instead.

Each operating system has its own script:

| | Script | Scheduler |
|---|---|---|
| macOS | `scripts/dev_worker/setup.sh` | launchd |
| Windows | `scripts/dev_worker/setup.ps1` (sets up WSL2, then runs `setup.sh` inside it) | Task Scheduler |
| Linux | `scripts/dev_worker/setup.sh` | cron |

Both take the same commands: `install`, `doctor`, `status`, `pause`,
`resume`, `uninstall`.

First, in the Dev Workers app, choose **Add a computer**, name it, and copy
the worker token. It's shown once; the script asks for it.

### macOS

With [Homebrew](https://brew.sh), skipping anything already set up:
```sh
brew install node gh
npm install -g @anthropic-ai/claude-code
gh auth login          # GitHub.com, HTTPS, sign in with the browser
gh auth setup-git      # git uses the same sign-in for clone and push
claude auth login      # the Claude account this computer's jobs run on
git clone https://github.com/bluejayorg/bluejay.git ~/bluejay
cd ~/bluejay
scripts/dev_worker/setup.sh install    # --workers 2 on a machine with spare cores
```

### Windows

The workers run inside WSL2 (Ubuntu), because the jobs need a Linux shell,
and Windows Task Scheduler starts them every minute, so no window has to
stay open. In PowerShell:
```powershell
winget install --id Git.Git -e
winget install --id GitHub.cli -e
# open a new PowerShell window so both are on PATH, then:
gh auth login
gh repo clone bluejayorg/bluejay $HOME\bluejay
cd $HOME\bluejay
powershell -ExecutionPolicy Bypass -File scripts\dev_worker\setup.ps1    # -Workers 2 for two
```
`setup.ps1`:
1. Installs WSL2 and Ubuntu if they're missing. Approve the administrator
   prompt, restart if Windows asks, open **Ubuntu** from the Start menu once
   to create your Linux user, then run `setup.ps1` again.
2. Inside Ubuntu (`wsl_bootstrap.sh`): installs git, gh, Node and Claude
   Code (sudo asks for your Linux password), signs in to GitHub with the
   sign-in you just made in PowerShell, signs in to Claude Code (open the
   link it prints), and clones the repo into Ubuntu's own disk at
   `~/bluejay`. The jobs build there, which is much faster than a Windows
   drive.
3. Asks for the worker token and runs `setup.sh install` in Ubuntu.
4. Offers to set Windows to never sleep while plugged in. A computer that
   sleeps mid-job loses its lease and uses up one of the job's attempts.

Re-running it is safe: each step skips what's already done.

### Linux

Install git, curl, gh, cron, Node 18+ and Claude Code
(`curl -fsSL https://claude.ai/install.sh | bash`), sign in with
`gh auth login`, `gh auth setup-git` and `claude auth login`, clone the
repo, and run `scripts/dev_worker/setup.sh install` from it.

### What install does

`setup.sh install` checks everything first (`doctor` runs the same checks
on their own) and then:
- saves the token to `~/.config/bluejay/dev-worker-token` (mode 600)
- clones a dedicated copy per worker into `~/bluejay-workers/w<n>`. Every
  run hard-resets that clone to `origin/main`, so never work in it.
- writes `~/.config/bluejay/dev-worker.env`, this machine's settings
- schedules each worker:
  - macOS: `~/Library/LaunchAgents/com.bluejay.dev-worker.<n>.plist`, from
    `com.bluejay.dev-worker.plist.template`
  - Windows: a `BluejayDevWorker<n>` task in Task Scheduler, running a
    hidden `%LOCALAPPDATA%\bluejay\dev-worker-<n>.vbs` that starts the
    worker in WSL. It runs while you're signed in to Windows (a locked
    screen is fine).
  - Linux: a crontab line ending `# bluejay-dev-worker-<n>`

`--workers 2` (`-Workers 2` for `setup.ps1`) runs two workers on a machine
with spare cores. Re-running `install` with a different number adds or
removes workers. If a check fails, fix what it names and run `install`
again.

Within a minute the worker shows as live in Dev Workers.

Other commands: `status` (scheduled workers, jobs running, recent
activity), `pause` / `resume`, and `uninstall`. Uninstall waits for running
jobs (`--now`, or `-Now` for `setup.ps1`, doesn't) and keeps the clones,
token and settings. Revoke the token in Dev Workers if the computer is
leaving the pool.

## Worker ids and credentials

Each worker is `claude-local-<host>-<n>`, for example
`claude-local-studio-mac-1`. Its record is `dev_queue_workers/{workerId}`:
last check-in, machine, capabilities, owner, and whether it's disabled.

A worker reaches the queue in one of two ways
(`scripts/firestore_admin/lib/dev_worker_transport.js`):

- **Worker token**: the default for contributors. Every claim, heartbeat,
  completion and job read goes through the `devWorkerApi` Cloud Function
  (`functions/_dev_worker_api.js`), which runs the claim protocol for the
  token's owner. The token only reaches the queue operations. Revoking it,
  or removing its owner's developer role, stops the worker on its next
  tick.
- **Firebase admin key**: used when `GOOGLE_APPLICATION_CREDENTIALS`
  (default `~/bluejay_keys/bluejay-firebase-adminsdk.json`) exists. Runs the
  same protocol in-process. Only these workers take `app` jobs, because
  registering a new app (`sync_app_manifests.js`) needs the key. This is the
  `admin_sdk` capability in `functions/_dev_queue_worker_core.js`.

Workers on one Claude account share that account's usage limits. A second
machine on your own account makes jobs finish sooner (builds and tests run
in parallel). A contributor's own account adds capacity as well.

## Capacity

The scheduler lets one job build per live worker (`buildingLimit` in
`functions/_dev_queue_model.js`). A worker is live when it checked in within
`platform_config/dev_queue.workerLiveMinutes` (default 15) and isn't
disabled. Idle workers check in on every tick, and busy ones through their
heartbeats. The limit stays between `minBuilding` (default 2), so
interactive and cloud-routine claims still find work, and `maxBuilding`
(default 20).

## This machine's settings

`~/.config/bluejay/dev-worker.env` is read on every tick, so edits apply
without reloading anything:

| Setting | Effect |
|---|---|
| `TICKET_DISPATCH_MAX_LOAD_PER_CORE` | Skip a tick while the load average is above this many times the core count (default 1.0). |
| `DEV_WORKER_REQUIRE_AC_POWER=1` | Only work while plugged in. `install` turns this on for laptops. |
| `DEV_WORKER_QUIET_HOURS=9-18` | Stay idle from 9:00 to 17:59 local time. Ranges past midnight (`22-7`) work. |
| `LOCAL_CHECK_JOBS` | Parallel Flutter shards in each job's `scripts/ci/local_check.sh`. |
| `FLUTTER`, `JAVA_HOME` | Tool locations, if not on the default paths. |

A job runs under `nice -n 10`, so its builds give way to your own work.
On a Mac, `caffeinate` keeps it awake until the job finishes, because a
computer that sleeps mid-job loses its lease and uses up one of the job's
attempts. On Windows and Linux, set the power settings so the computer
doesn't sleep while plugged in.

## Pausing

- One computer: `setup.sh pause` writes `~/.config/bluejay/dev-worker.paused`,
  which every tick checks, and `setup.sh resume` removes it. A paused
  computer stops checking in, so it shows offline and stops counting
  toward the building limit.
- One worker: **Disable** in Dev Workers (its owner or a platform admin).
  A disabled worker keeps checking in and claims nothing.
- Everything: a platform admin's **Pause all** in Dev Workers sets
  `platform_config/dev_queue.workersPaused`.

A job already running finishes either way.

## Offline alerts

Every 15 minutes, `devWorkerHealthCheck` emails the operations alert address
(`ops_alert_email`, default jay@bluejay.gg) when a worker hasn't checked in for
an hour (`platform_config/dev_queue.workerQuietMinutes`, default 60): one email
per computer when all of its workers go quiet together, one per worker when
only some do, and one more when no worker in the pool has checked in. Each
problem emails once, and again with a short "back online" note when it checks
in. A disabled worker and a pool paused with **Pause all** are not watched.
`setup.sh pause` stops a computer checking in, so a computer paused that way
alerts the same as one that is off; the email says so. Disable a worker you
have retired to stop its alerts.

## Safety

The worker runs `claude -p` unattended with `--permission-mode auto`, on
text that end users wrote. It can read anything your user account can,
and it pushes with your GitHub credentials. On a computer you also use for
other work, consider a separate user account for the worker (on Windows,
a separate WSL distro or Windows user): sign in to Claude Code and the
GitHub CLI there and run `install` from it.

## Troubleshooting

- `dispatch.log`: dispatches, skips and errors (silence is normal when
  idle). It's in `~/Library/Logs/bluejay-ticket-dispatch/` on macOS and
  `~/.local/state/bluejay-ticket-dispatch/` on Windows (inside WSL) and
  Linux. Each run's `claude` output goes there too.
- macOS: `launchd.<host>-<n>.{out,err}.log` next to it has launchd's raw
  output.
- Windows: Task Scheduler lists `BluejayDevWorker<n>` with each task's last
  run result. `wsl -l -v` in PowerShell shows the distro name the tasks use.
- `node scripts/firestore_admin/dev_queue_worker.js transport` (from a
  worker's clone) prints which credentials it uses, and `list` shows the open
  jobs.
- The `manage-ticket-dispatch-worker` skill covers status, history and
  auditing.
