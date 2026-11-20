#!/bin/bash
# The WSL half of setup.ps1 (Windows): runs inside the WSL distro, installs
# what a worker needs, signs in, clones the repo into WSL's own disk and
# hands over to setup.sh install. Safe to re-run: every step skips what's
# already done. See scripts/dev_worker/README.md.
#
# Usage (setup.ps1 runs it): wsl_bootstrap.sh [setup.sh install options]
#
# From setup.ps1, through WSLENV:
#   BJ_GH_TOKEN      the Windows GitHub CLI's token, so WSL's gh needs no second sign-in
#   BJ_WORKER_TOKEN  the worker token, passed to setup.sh install --token-stdin
set -uo pipefail

CLONE="${BJ_CLONE:-$HOME/bluejay}"
REPO_URL="${BLUEJAY_REPO_URL:-https://github.com/bluejayorg/bluejay.git}"
export PATH="$HOME/.local/bin:$PATH"

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die() { printf '%s\n' "$1" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "WSL runs as root, so the distro has no user of its own yet. Open Ubuntu from the Start menu once to create one (or sudo adduser <name> and make it the default user), then run setup.ps1 again."

step "Tools"
missing=""
command -v git >/dev/null 2>&1 || missing="$missing git"
command -v curl >/dev/null 2>&1 || missing="$missing curl"
if [ -n "$missing" ]; then
  echo "Installing$missing (sudo asks for your Linux password)..."
  sudo apt-get update -qq && sudo apt-get install -y -qq $missing || die "apt-get install$missing failed."
fi
# gh comes from GitHub's own apt repository. Ubuntu's package is older than setup.sh's
# GH_MIN_VERSION (keep the two in step), and older gh fails gh pr view and gh pr edit.
GH_MIN_VERSION=2.82.0
gh_version() { gh --version 2>/dev/null | sed -n 's/^gh version \([0-9][0-9.]*\).*/\1/p'; }
gh_new_enough() {
  awk -v a="$(gh_version)" -v b="$GH_MIN_VERSION" 'BEGIN {
    if (a == "") exit 1
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0
  }'
}
if ! gh_new_enough; then
  echo "Installing gh from GitHub's apt repository (sudo asks for your Linux password)..."
  keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  { sudo mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$keyring" >/dev/null \
    && sudo chmod go+r "$keyring" \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
    && sudo apt-get update -qq && sudo apt-get install -y -qq gh; } || die "Installing gh failed."
  hash -r
  gh_new_enough || die "gh is still $(gh_version) after installing it; $GH_MIN_VERSION or newer is needed."
fi
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [ "$(node_major)" -lt 18 ]; then
  echo "Installing Node 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null && sudo apt-get install -y -qq nodejs \
    || die "Installing Node failed."
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash || die "Installing Claude Code failed."
  hash -r
fi
echo "git, gh, node $(node -v), claude: ok"

step "GitHub sign-in"
if ! gh auth status >/dev/null 2>&1; then
  if [ -n "${BJ_GH_TOKEN:-}" ]; then
    printf '%s\n' "$BJ_GH_TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token \
      || die "Signing in with the Windows GitHub CLI's token failed: run gh auth login here."
  else
    gh auth login --hostname github.com --git-protocol https --web || die "GitHub sign-in failed."
  fi
fi
gh auth setup-git >/dev/null 2>&1
echo "signed in as $(gh api user --jq .login 2>/dev/null)"

step "Claude Code sign-in"
if ! claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  echo "Open the link it prints in your Windows browser to sign in."
  claude auth login || die "Claude Code sign-in failed."
fi
echo "signed in as $(claude auth status 2>/dev/null | sed -n 's/.*"email": *"\([^"]*\)".*/\1/p')"

step "Repository (~/bluejay)"
if [ -d "$CLONE/.git" ]; then
  if [ -z "$(git -C "$CLONE" status --porcelain)" ]; then
    git -C "$CLONE" pull -q --ff-only origin main || echo "Couldn't fast-forward $CLONE; using it as it is."
  else
    echo "$CLONE has local changes; using it as it is."
  fi
else
  git clone -q "$REPO_URL" "$CLONE" || die "Cloning $REPO_URL failed."
fi
echo "$CLONE at $(git -C "$CLONE" log -1 --format=%h)"

step "Workers"
if [ -n "${BJ_WORKER_TOKEN:-}" ]; then
  printf '%s\n' "$BJ_WORKER_TOKEN" | bash "$CLONE/scripts/dev_worker/setup.sh" install --token-stdin "$@"
else
  bash "$CLONE/scripts/dev_worker/setup.sh" install "$@"
fi
