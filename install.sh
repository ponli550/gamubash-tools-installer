#!/usr/bin/env bash
#
# gamubash installer. Works two ways:
#
#   1. curl|bash (zero clone needed):
#        curl -fsSL https://raw.githubusercontent.com/ponli550/GamuBash/main/scripts/install.sh | bash
#        curl -fsSL …/install.sh | bash -s -- --scripts   # scripts-only mode
#
#   2. clone-first (you already cloned the repo by hand — useful when git
#      credential helpers are misbehaving and you cloned via SSH or by
#      downloading a zip):
#        ./scripts/install.sh
#        ./scripts/install.sh --scripts
#
# Re-run the same command at any time to UPDATE — the script is idempotent.
#
# Flags:
#   --scripts     Install prerequisites only (Go + Make). Skips the gamubash
#                 binary build entirely. Useful when you want a working dev
#                 environment for the bash curriculum without compiling the CLI.
#   --tools-only  Install the full dev toolchain (brew, vim, nvim, tmux, direnv,
#                 jq, shellcheck, bats, docker, nvm+node+npm, pyenv+python3,
#                 gcloud). Skips the gamubash binary entirely. Mirrors the
#                 per-tool RunCmd snippets from cli/internal/doctor/doctor.go,
#                 so pressing 'i' in the TUI and this flag converge on the
#                 same end state.
#                 Mutually exclusive with --scripts.
#   --help, -h    Show this header and exit.
#
# What it does, in order:
#   1. Detects platform (macOS/Linux, arm64/x86_64)
#   2. FAST PATH: downloads the latest release binary from GitHub Releases
#      if available for the platform (no Go required, ~5 sec install)
#   3. FALLBACK: if no release binary, installs Go (if missing), clones the
#      repo into $HOME/.gamubash/src, and builds from source
#   4. Drops the binary into $HOME/.local/bin (no sudo) and auto-adds that
#      dir to PATH in your shell rc file (~/.zshrc / ~/.bashrc / ~/.profile).
#      Idempotent — re-running won't append a second line.
#   5. Prints next steps (incl. how to refresh PATH in your current terminal)
#
# Designed to be readable so trainees can study it as a real-world bootstrap
# script (it's the kind of thing they'll be writing during Module 9).
#
# Override env vars:
#   GAMUBASH_REPO_URL       — git remote for the source/curriculum
#                             (default: github.com/ponli550/GamuBash.git)
#   GAMUBASH_RELEASE_REPO   — owner/name slug on github.com hosting the prebuilt
#                             binary releases. Decoupled from GAMUBASH_REPO_URL,
#                             so you can host source on Bitbucket while still
#                             pulling release tarballs from a public GitHub
#                             mirror (default: ponli550/gamubash-tools-installer)
#   GAMUBASH_FORCE_SOURCE=1 — skip the binary fast-path; always build from source
#   GAMUBASH_NO_PATH_EDIT=1 — skip editing your shell rc; just print instructions
#   GAMUBASH_ALLOW_GIT_PROMPT=1 — allow git to prompt for HTTPS auth (default:
#                                 suppressed; curl|bash can't handle prompts)
#   GAMUBASH_NO_GIT_AUTH=1   — if release-binary path fails, DON'T try the
#                              git-clone source-build fallback (useful when
#                              your machine has stale credentials in osxkeychain
#                              / gh-cli that get silently injected into clones).
#                              Prints manual-install instructions and exits.

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
GO_VERSION_MIN_MAJOR=1
GO_VERSION_MIN_MINOR=22
GO_INSTALL_VERSION="1.23.4"  # bump occasionally; minimum the curriculum needs
# Override-able for forks/testing: GAMUBASH_REPO_URL=... bash install.sh
REPO_URL="${GAMUBASH_REPO_URL:-https://github.com/ponli550/GamuBash.git}"
RELEASE_REPO="${GAMUBASH_RELEASE_REPO:-ponli550/gamubash-tools-installer}"

# Derive host, SSH form, and web URL from REPO_URL so the release-binary host
# gate and error messages adapt to any forge (github, bitbucket, gitlab, …).
# Without this, `curl https://bitbucket.org/.../install.sh | bash` would still
# hit api.github.com and print github.com URLs in every error message, even
# though the user explicitly pointed the installer at Bitbucket.
REPO_HOST=""
REPO_SSH=""
REPO_WEB=""
case "$REPO_URL" in
  https://*|http://*)
    _rest="${REPO_URL#*://}"
    REPO_HOST="${_rest%%/*}"
    REPO_SSH="git@${REPO_HOST}:${_rest#*/}"
    REPO_WEB="${REPO_URL%.git}"
    unset _rest
    ;;
  *@*:*)
    REPO_HOST="${REPO_URL#*@}"
    REPO_HOST="${REPO_HOST%%:*}"
    REPO_SSH="$REPO_URL"
    REPO_WEB="https://${REPO_HOST}/${REPO_URL##*:}"
    REPO_WEB="${REPO_WEB%.git}"
    ;;
  *)
    REPO_SSH="$REPO_URL"
    REPO_WEB="$REPO_URL"
    ;;
esac

SRC_DIR="${HOME}/.gamubash/src"
BIN_DIR="${HOME}/.local/bin"
BIN_NAME="gamubash"
GO_INSTALL_DIR="${HOME}/.local/go"

# ── cleanup registry ──────────────────────────────────────────────────────────
# Functions register tmp dirs here so the EXIT/INT/TERM trap below cleans them
# up even on Ctrl-C. The previous design relied on per-function RETURN traps,
# which leaked tmp dirs when the script was aborted mid-download.
TMP_DIRS=()
cleanup_tmp_dirs() {
  if [ "${#TMP_DIRS[@]}" -eq 0 ]; then
    return
  fi
  local d
  for d in "${TMP_DIRS[@]}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp_dirs EXIT INT TERM

# Set by ensure_on_path() when it appends a PATH export to the user's rc file.
# print_next_steps reads this to surface the `source <rc>` reminder prominently
# at the end of output (otherwise it scrolls past under release/build output).
PATH_RC_EDITED=""

# Guard so `apt-get update` runs at most once per --tools-only invocation,
# instead of once per apt_pkg call (6 redundant refreshes in the worst case).
APT_UPDATED=0

# Captured when the release-binary fast-path bails. print_manual_install_and_die
# surfaces this so a user who lands on the manual screen understands WHY the
# automated path didn't work and whether re-running later might help (e.g.
# "no release yet" = wait for mirror; "rate limited" = set GITHUB_TOKEN).
RELEASE_FAIL_REASON=""

# ── styled output ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
say()  { printf "%s==>%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf "%s!!%s  %s\n" "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()  { printf "%sxx%s  %s\n" "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

# ── platform ──────────────────────────────────────────────────────────────────
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *)      die "unsupported OS: $(uname -s) — only macOS and Linux right now" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *)             die "unsupported arch: $(uname -m)" ;;
  esac
  echo "${os}-${arch}"
}

# ── go ────────────────────────────────────────────────────────────────────────
go_is_recent_enough() {
  command -v go >/dev/null 2>&1 || return 1
  local v
  v="$(go version | awk '{print $3}' | sed 's/^go//')"
  local maj min
  maj="$(echo "$v" | cut -d. -f1)"
  min="$(echo "$v" | cut -d. -f2)"
  [ "$maj" -gt "$GO_VERSION_MIN_MAJOR" ] || \
    { [ "$maj" -eq "$GO_VERSION_MIN_MAJOR" ] && [ "$min" -ge "$GO_VERSION_MIN_MINOR" ]; }
}

install_go() {
  local platform="$1"
  local tarball="go${GO_INSTALL_VERSION}.${platform}.tar.gz"
  local url="https://go.dev/dl/${tarball}"
  say "downloading ${url}"
  mkdir -p "$(dirname "$GO_INSTALL_DIR")"
  rm -rf "$GO_INSTALL_DIR"
  curl -fsSL "$url" | tar -C "$(dirname "$GO_INSTALL_DIR")" -xz
  say "Go ${GO_INSTALL_VERSION} extracted to ${GO_INSTALL_DIR}"
  export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
}

ensure_go() {
  if go_is_recent_enough; then
    say "Go $(go version | awk '{print $3}') already present"
    return
  fi
  warn "Go missing or too old (need >= ${GO_VERSION_MIN_MAJOR}.${GO_VERSION_MIN_MINOR}); installing ${GO_INSTALL_VERSION}"
  install_go "$(detect_platform)"
  if ! go_is_recent_enough; then
    die "Go install failed — please install Go manually from https://go.dev/dl/"
  fi
}

# ── make ──────────────────────────────────────────────────────────────────────
# Make is needed for joiners who'll run `make` later (cli/Makefile targets,
# their own dotfiles build, etc.). We DETECT and instruct — we don't try to
# auto-install because that needs sudo on Linux and an interactive GUI prompt
# on macOS (xcode-select --install), neither of which works cleanly under
# curl|bash. The pattern matches ensure_git.
ensure_make() {
  if command -v make >/dev/null 2>&1; then
    say "make $(make --version 2>/dev/null | head -1 | awk '{print $3}') already present"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    die "make missing — run 'xcode-select --install' then re-run this script"
  fi
  die "make missing — install via your package manager (e.g. 'sudo apt install make' or 'sudo dnf install make') and re-run"
}

# ── git ───────────────────────────────────────────────────────────────────────
ensure_git() {
  if command -v git >/dev/null 2>&1; then
    say "git $(git --version | awk '{print $3}') already present"
    return
  fi
  # macOS: prompt the user; git is part of Xcode CLI tools.
  if [ "$(uname -s)" = "Darwin" ]; then
    die "git missing — run 'xcode-select --install' then re-run this script"
  fi
  die "git missing — install via your package manager (e.g. 'apt install git') then re-run"
}

# ── release binary fast-path ──────────────────────────────────────────────────
# Hits the GitHub releases API and downloads the matching tarball. If anything
# fails (no release yet, no asset for this platform, network blip, checksum
# mismatch), returns non-zero so main() falls through to the source build.
try_install_from_release() {
  local platform="$1"
  local goos goarch
  goos="${platform%-*}"   # darwin or linux
  goarch="${platform#*-}" # amd64 or arm64

  # Release-binary path always hits GitHub Releases on RELEASE_REPO, regardless
  # of where the source/curriculum (REPO_URL) is hosted. This lets us host
  # source on Bitbucket while publishing prebuilt binaries on a public GitHub
  # mirror (default: ponli550/gamubash-tools-installer). Override with
  # GAMUBASH_RELEASE_REPO; disable entirely with GAMUBASH_FORCE_SOURCE=1.
  say "checking for a release binary for ${platform}"
  local api="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
  local release_json=""
  # Use GITHUB_TOKEN when set — bumps the rate limit from 60/hr to 5000/hr.
  # Useful in CI and for users who hit the unauthenticated limit mid-session.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    release_json="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api" 2>/dev/null || true)"
  else
    release_json="$(curl -fsSL "$api" 2>/dev/null || true)"
  fi
  if [ -z "$release_json" ]; then
    # Distinguish rate limit (403) from "no releases yet" (404) by re-fetching
    # without -f so we can read the error body. Costs one extra request only
    # in the failure path.
    local err_body
    err_body="$(curl -sSL "$api" 2>/dev/null || true)"
    if echo "$err_body" | grep -q "API rate limit exceeded"; then
      RELEASE_FAIL_REASON="GitHub API rate limited (60/hr unauthenticated) — set GITHUB_TOKEN or wait"
    else
      RELEASE_FAIL_REASON="no published release on ${RELEASE_REPO} yet"
    fi
    warn "${RELEASE_FAIL_REASON}; falling back to source build"
    return 1
  fi

  local tag asset_url checksum_url
  tag="$(echo "$release_json" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  # Asset name template matches goreleaser: gamubash_<ver>_<os>_<arch>.tar.gz
  # The version in the asset name is the tag with the leading 'v' stripped.
  local version="${tag#v}"

  # Skip the download entirely if the installed binary already reports this
  # version. Best-effort: if --version isn't supported or its output format
  # changes, we just re-install (harmless — this script is idempotent).
  if [ -x "${BIN_DIR}/${BIN_NAME}" ]; then
    local current
    current="$("${BIN_DIR}/${BIN_NAME}" --version 2>/dev/null || true)"
    if [ -n "$current" ] && echo "$current" | grep -qF "$version"; then
      say "already at ${tag} — nothing to do"
      return 0
    fi
  fi

  local asset="gamubash_${version}_${goos}_${goarch}.tar.gz"
  asset_url="$(echo "$release_json" | grep -m1 "\"browser_download_url\":.*${asset}\"" | \
    sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"
  checksum_url="$(echo "$release_json" | grep -m1 '"browser_download_url":.*checksums.txt"' | \
    sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"

  if [ -z "$asset_url" ]; then
    RELEASE_FAIL_REASON="release ${tag} on ${RELEASE_REPO} has no asset for your platform (${platform})"
    warn "${RELEASE_FAIL_REASON}; falling back to source build"
    return 1
  fi

  say "downloading release ${tag} (${asset})"
  local tmp
  tmp="$(mktemp -d -t gamubash-XXXXXX)"
  # Register tmp dir in the global cleanup list so the EXIT/INT/TERM trap
  # removes it — covers Ctrl-C, kill, and normal exit. Replaces the previous
  # RETURN trap, which (a) didn't fire on signals and (b) had a bash 3.2 quirk
  # where it leaked to the caller's scope and tripped set -u on re-fire.
  TMP_DIRS+=("$tmp")

  curl -fsSL "$asset_url" -o "$tmp/${asset}" || {
    RELEASE_FAIL_REASON="download of ${asset} from ${RELEASE_REPO} failed (network or transient outage)"
    warn "${RELEASE_FAIL_REASON}; falling back to source build"
    return 1
  }

  # Checksum verification, when available — protects against MITM and corrupt
  # downloads. Skipped (with a warning) only if checksums.txt isn't published.
  if [ -n "$checksum_url" ]; then
    curl -fsSL "$checksum_url" -o "$tmp/checksums.txt" || true
    if [ -s "$tmp/checksums.txt" ]; then
      local expected actual
      expected="$(grep -F "$asset" "$tmp/checksums.txt" | awk '{print $1}')"
      if command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$tmp/${asset}" | awk '{print $1}')"
      elif command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$tmp/${asset}" | awk '{print $1}')"
      else
        warn "no sha256 utility (shasum/sha256sum) found — integrity check SKIPPED"
        actual=""
      fi
      if [ -z "$expected" ]; then
        warn "asset ${asset} not listed in checksums.txt — integrity check SKIPPED"
      fi
      if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
        die "checksum mismatch on ${asset} — refusing to install (got ${actual}, expected ${expected})"
      fi
      if [ -n "$expected" ] && [ -n "$actual" ]; then
        say "checksum verified (sha256 ${actual:0:12}…)"
      fi
    fi
  else
    warn "no checksums.txt in release — skipping integrity check"
  fi

  tar -C "$tmp" -xzf "$tmp/${asset}"
  mkdir -p "$BIN_DIR"
  mv "$tmp/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
  chmod +x "${BIN_DIR}/${BIN_NAME}"
  say "installed → ${BIN_DIR}/${BIN_NAME} (release ${tag}, no compile needed)"
  return 0
}

# ── repo + build ──────────────────────────────────────────────────────────────
# Shared exit path when automated install can't finish. Called from two places:
#   1. main() — when GAMUBASH_NO_GIT_AUTH=1 and the release-binary path didn't
#      install (user pre-opted-out of the source-build cascade)
#   2. clone_or_update() — when git clone/fetch fails (typically because a
#      credential helper silently injected stale creds for github.com)
# Same output either way, so users get useful next steps regardless of how the
# install fell over.
print_manual_install_and_die() {
  warn "$1"
  # Surface the release-fast-path failure if it was set. Helps a stranded user
  # diagnose whether re-running is likely to help (rate-limit / network blip)
  # or whether they really do need to manual-install (no release published).
  if [ -n "$RELEASE_FAIL_REASON" ]; then
    warn ""
    warn "release fast-path also failed:"
    warn "  ${RELEASE_FAIL_REASON}"
    case "$RELEASE_FAIL_REASON" in
      *"no published release"*)
        warn "  → the public mirror likely hasn't run yet — try again in a few minutes" ;;
      *"rate limited"*)
        warn "  → set GITHUB_TOKEN (any read-scoped PAT) and re-run, or wait an hour" ;;
      *"no asset for your platform"*)
        warn "  → this release lacks a binary for your platform — try source build" ;;
      *"download"*"failed"*)
        warn "  → network or transient outage — re-running the installer may succeed" ;;
    esac
  fi
  warn ""
  warn "to install manually, pick one:"
  # Release binaries always live on GitHub at RELEASE_REPO, independent of
  # where REPO_URL points (so a Bitbucket-hosted source repo still gets
  # prebuilt binaries from the public GitHub releases page).
  warn "  • download a release binary by hand:"
  warn "      https://github.com/${RELEASE_REPO}/releases"
  warn "      drop the gamubash binary into ${BIN_DIR}/${BIN_NAME}, chmod +x"
  warn "  • OR build from source via SSH (bypasses HTTPS credential helpers):"
  warn "      git clone ${REPO_SSH} ${SRC_DIR}"
  warn "      cd ${SRC_DIR}/cli && go build -o ${BIN_DIR}/${BIN_NAME} ./cmd/gamubash"
  warn "  • OR fix the credential helper and re-run this installer:"
  warn "      printf 'protocol=https\\nhost=${REPO_HOST:-github.com}\\n' | git credential-osxkeychain erase"
  die "automated install couldn't complete"
}

clone_or_update() {
  # Suppress git's HTTPS auth prompt by default. The repo is meant to be
  # cloneable anonymously, and a curl|bash session can't sanely interact with
  # a username/password prompt anyway — without this, the script appears to
  # hang on "Username for 'https://github.com':" and ignores keypresses.
  # Opt-out for private forks: GAMUBASH_ALLOW_GIT_PROMPT=1.
  if [ -z "${GAMUBASH_ALLOW_GIT_PROMPT:-}" ]; then
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS=/bin/echo
  fi

  if [ -d "${SRC_DIR}/.git" ]; then
    say "updating existing checkout at ${SRC_DIR}"
    git -C "$SRC_DIR" fetch --quiet origin || \
      print_manual_install_and_die "git fetch failed for ${REPO_URL} — likely a stale credential helper sending bad creds."
    # Resolve upstream's default branch from origin/HEAD instead of hard-coding
    # "main". Forks may use "master"/"trunk", and upstream could be renamed.
    # Falls back to "main" if symbolic-ref isn't set (older clones).
    local default_branch
    default_branch="$(git -C "$SRC_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    default_branch="${default_branch:-main}"
    git -C "$SRC_DIR" checkout --quiet "$default_branch"
    git -C "$SRC_DIR" pull --quiet --ff-only origin "$default_branch"
  else
    say "cloning ${REPO_URL} → ${SRC_DIR}"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --quiet "$REPO_URL" "$SRC_DIR" || \
      print_manual_install_and_die "git clone failed for ${REPO_URL} — likely a stale credential helper sending bad creds."
  fi
}

build_and_install() {
  say "building gamubash"
  # mktemp + cleanup registry: avoids the predictable /tmp/$BIN.$$ path
  # (race-prone across concurrent runs and trivially predictable to other
  # users on shared hosts). Registry pickup means an aborted build cleans up.
  local tmp
  tmp="$(mktemp -d -t gamubash-build-XXXXXX)"
  TMP_DIRS+=("$tmp")
  (cd "${SRC_DIR}/cli" && go build -o "${tmp}/${BIN_NAME}" ./cmd/gamubash)
  mkdir -p "$BIN_DIR"
  mv "${tmp}/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
  chmod +x "${BIN_DIR}/${BIN_NAME}"
  say "installed → ${BIN_DIR}/${BIN_NAME}"
}

# ── PATH setup ────────────────────────────────────────────────────────────────
# Auto-adds $BIN_DIR to the user's shell rc file. Skips the edit if it's already
# on PATH for this process, or if GAMUBASH_NO_PATH_EDIT is set. Idempotent — the
# grep guard means re-running the installer won't append a second export line.
#
# `curl|bash` cannot affect the parent shell's PATH (the script runs in a child
# process), so the user still has to open a new terminal or `source` the rc to
# pick it up in their current session — the footer tells them which command.
ensure_on_path() {
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) return 0 ;;
  esac

  if [ -n "${GAMUBASH_NO_PATH_EDIT:-}" ]; then
    warn "${BIN_DIR} is not on \$PATH (GAMUBASH_NO_PATH_EDIT set — not editing rc)"
    printf "    add manually: %sexport PATH=\"%s:\$PATH\"%s\n" "$C_BOLD" "$BIN_DIR" "$C_RESET"
    return 0
  fi

  local rc shell_name
  shell_name="$(basename "${SHELL:-/bin/zsh}")"
  case "$shell_name" in
    zsh)  rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    fish) rc="$HOME/.config/fish/config.fish"; mkdir -p "$(dirname "$rc")" ;;
    *)    rc="$HOME/.profile" ;;
  esac
  touch "$rc"

  if grep -q '\.local/bin' "$rc" 2>/dev/null; then
    say "${rc} already references .local/bin — not modifying"
  elif [ "$shell_name" = "fish" ]; then
    # Fish doesn't read POSIX export syntax — use fish_add_path, which is the
    # idiomatic and universal-variable-safe way to extend PATH in fish 3+.
    printf '\n# added by gamubash installer\nfish_add_path %s\n' "$BIN_DIR" >> "$rc"
    say "added ${BIN_DIR} to PATH in ${rc} (fish syntax)"
  else
    # SC2016: literal $PATH is intentional — it must expand at shell startup,
    # not at install time, otherwise we'd freeze the user's current PATH into
    # their rc file.
    # shellcheck disable=SC2016
    printf '\n# added by gamubash installer\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
    say "added ${BIN_DIR} to PATH in ${rc}"
  fi

  PATH_RC_EDITED="$rc"
  printf "    %sthis terminal:%s  source %s\n" "$C_BOLD" "$C_RESET" "$rc"
  printf "    %snew terminals:%s  already set\n" "$C_BOLD" "$C_RESET"
}

# ── toolchain installers (--tools-only) ──────────────────────────────────────
# These mirror the per-tool RunCmd snippets in cli/internal/doctor/doctor.go.
# Keep them in sync when adding or changing tools. The TUI installer (press
# `i` on a doctor row) and this `--tools-only` path should produce the same
# final state — only the entry point differs.

tool_step() { printf "\n%s──%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
tool_ok()   { printf "  %s✓%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
tool_warn() { printf "  %s!%s %s (continuing)\n" "$C_YELLOW" "$C_RESET" "$1" >&2; }

# Under `curl | bash`, stdin is the pipe, so sudo (and Homebrew's installer)
# can't prompt for a password and bails. Cache the credential up-front by
# reading from /dev/tty — same trick the pyenv prompt uses below. No-op when
# already cached (or running as root), and returns non-zero when there's no
# TTY at all (CI containers) or the user can't sudo (non-admin account).
ensure_sudo_cached() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    return 1
  fi
  say "caching sudo credentials (some installers need admin rights)"
  sudo -v < /dev/tty
}

# Pick the trainee's rc file and shell flavor. Matches shellDetectPrologue in
# doctor.go so hooks land in the same place either way.
detect_rc() {
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh)  RC="$HOME/.zshrc";   SH=zsh ;;
    bash) RC="$HOME/.bashrc";  SH=bash ;;
    fish) RC="$HOME/.config/fish/config.fish"; SH=fish; mkdir -p "$(dirname "$RC")" ;;
    *)    RC="$HOME/.profile"; SH=bash ;;
  esac
  touch "$RC"
}

install_brew_mac() {
  tool_step "homebrew"
  if command -v brew >/dev/null 2>&1; then
    tool_ok "brew already present: $(brew --version | head -n1)"
    return 0
  fi
  ensure_sudo_cached || {
    tool_warn "sudo unavailable — brew-dependent tools will be skipped"
    return 1
  }
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || { tool_warn "brew install failed — brew-dependent tools will be skipped"; return 1; }

  # Brew doesn't add itself to PATH on Apple Silicon — /opt/homebrew/bin isn't
  # in the default $PATH. Without this, every later brew_pkg / install_docker /
  # install_pyenv call in THIS script would see `brew missing` and skip. Also
  # append the eval to the user's rc so future shells pick it up.
  local brew_path=""
  [ -x /opt/homebrew/bin/brew ] && brew_path=/opt/homebrew/bin/brew
  [ -z "$brew_path" ] && [ -x /usr/local/bin/brew ] && brew_path=/usr/local/bin/brew
  if [ -z "$brew_path" ]; then
    tool_warn "brew installed but binary not found at /opt/homebrew or /usr/local"
    return 1
  fi
  eval "$("$brew_path" shellenv)"
  detect_rc
  if ! grep -q 'brew shellenv' "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      echo "$brew_path shellenv fish | source" >> "$RC"
    else
      echo "eval \"\$($brew_path shellenv)\"" >> "$RC"
    fi
  fi
  tool_ok "brew installed; shellenv sourced and appended to $RC"
}

# Generic brew-install with idempotency. Usage: brew_pkg <binary> <pkg> [cask]
brew_pkg() {
  local bin="$1" pkg="$2" mode="${3:-formula}"
  tool_step "$bin"
  if command -v "$bin" >/dev/null 2>&1; then
    tool_ok "$bin already present"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    tool_warn "$bin: brew missing, skipping"; return 1
  fi
  if [ "$mode" = "cask" ]; then
    brew install --cask "$pkg" || tool_warn "$bin (cask) install failed"
  else
    brew install "$pkg" || tool_warn "$bin install failed"
  fi
}

# Runs `apt-get update` at most once per script invocation. Each apt_pkg /
# install_pyenv call previously refreshed the package index independently — on
# a clean Linux box with the full toolchain that's 6+ network round-trips for
# no benefit. APT_UPDATED is initialized at the top of the file.
apt_update_once() {
  [ "$APT_UPDATED" = 1 ] && return 0
  sudo apt-get update -qq && APT_UPDATED=1
}

apt_pkg() {
  local bin="$1" pkg="$2"
  tool_step "$bin"
  if command -v "$bin" >/dev/null 2>&1; then
    tool_ok "$bin already present"
    return 0
  fi
  apt_update_once
  sudo apt-get install -y "$pkg" \
    || tool_warn "$bin (apt) install failed"
}

# direnv installer — mirrors direnvRunCmd in doctor.go.
install_direnv() {
  tool_step "direnv"
  if command -v direnv >/dev/null 2>&1; then
    tool_ok "direnv already present"
    return 0
  fi
  detect_rc
  mkdir -p "$HOME/.local/bin"
  curl -sfL https://direnv.net/install.sh | bin_path="$HOME/.local/bin" bash \
    || { tool_warn "direnv install failed"; return 1; }
  if ! grep -q '\.local/bin' "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      echo 'fish_add_path $HOME/.local/bin' >> "$RC"
    else
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
    fi
  fi
  if ! grep -q 'direnv hook' "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      echo 'direnv hook fish | source' >> "$RC"
    else
      echo "eval \"\$(direnv hook $SH)\"" >> "$RC"
    fi
  fi
  tool_ok "direnv installed to ~/.local/bin and hook appended to $RC"
}

# docker installer — macOS uses the cask; Linux uses the official convenience
# script. Daemon must still be launched manually (Docker Desktop on macOS,
# `systemctl start docker` on Linux).
install_docker() {
  local platform="$1"
  tool_step "docker"
  if command -v docker >/dev/null 2>&1; then
    tool_ok "docker already present"
    return 0
  fi
  case "$platform" in
    darwin-*)
      brew install --cask docker || { tool_warn "docker cask install failed"; return 1; }
      tool_ok "docker installed — launch Docker Desktop & accept the license"
      ;;
    linux-*)
      curl -fsSL https://get.docker.com | sh || { tool_warn "docker install failed"; return 1; }
      sudo usermod -aG docker "$USER" || tool_warn "could not add $USER to docker group (run manually)"
      tool_ok "docker installed — log out + back in for group membership, or run 'newgrp docker'"
      ;;
  esac
}

# nvm installer — mirrors nvmRunCmd in doctor.go. Installs nvm AND node LTS
# (which brings npm along for the ride) in the same subshell.
install_nvm() {
  tool_step "nvm + node + npm"
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    tool_ok "nvm already present at $NVM_DIR"
  else
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
      || { tool_warn "nvm install failed"; return 1; }
  fi
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    tool_warn "nvm.sh not at $NVM_DIR/nvm.sh after install"
    return 1
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install --lts || tool_warn "nvm install --lts failed"
  nvm use --lts >/dev/null 2>&1 || true
  tool_ok "node LTS installed via nvm (npm bundled)"
}

# pyenv installer — mirrors pyenvRunCmd in doctor.go. Heaviest of the lot:
# installs build deps, then compiles Python 3.12 from source (~3-5 min).
install_pyenv() {
  local platform="$1"
  tool_step "pyenv + python 3.12"
  if command -v python3 >/dev/null 2>&1 && command -v pyenv >/dev/null 2>&1; then
    tool_ok "python3 + pyenv already present"
    return 0
  fi
  detect_rc
  case "$platform" in
    darwin-*)
      if command -v brew >/dev/null 2>&1; then
        echo "  installing Python build deps via brew..."
        brew install openssl readline sqlite3 xz zlib tcl-tk || tool_warn "brew deps install failed"
      else
        tool_warn "brew missing — Python build may produce a broken interpreter"
      fi
      ;;
    linux-*)
      echo "  installing Python build deps via apt..."
      apt_update_once
      sudo apt-get install -y build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev \
        || tool_warn "apt deps install failed"
      ;;
  esac
  curl https://pyenv.run | bash || { tool_warn "pyenv install failed"; return 1; }
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  if ! grep -q 'PYENV_ROOT' "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      {
        echo
        echo "# pyenv"
        echo 'set -gx PYENV_ROOT $HOME/.pyenv'
        echo 'fish_add_path $PYENV_ROOT/bin'
        echo 'pyenv init - fish | source'
      } >> "$RC"
    else
      {
        echo
        echo "# pyenv"
        echo 'export PYENV_ROOT="$HOME/.pyenv"'
        echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        echo "eval \"\$(pyenv init - $SH)\""
      } >> "$RC"
    fi
  fi
  export PATH="$PYENV_ROOT/bin:$PATH"
  # We're in bash regardless of the user's login shell — initialize pyenv in
  # bash mode here so subsequent `pyenv install` calls in this script work.
  eval "$(pyenv init - bash)"
  echo
  echo "  About to compile Python 3.12 from source (3-5 min; skipped if already installed)."
  echo "  Press ENTER to continue, or Ctrl-C to abort."
  # Read from /dev/tty so the prompt works under `curl | bash` (where stdin
  # is the pipe and already at EOF). Falls through silently if no tty.
  if [ -r /dev/tty ]; then
    read -r _ < /dev/tty || true
  fi
  pyenv install -s 3.12 || tool_warn "python 3.12 compile failed"
  pyenv global 3.12 || true
  pyenv rehash || true
  tool_ok "pyenv + Python 3.12 installed (restart shell for shim)"
}

# gcloud installer — mirrors gcloudRunCmd in doctor.go.
install_gcloud() {
  tool_step "gcloud"
  if command -v gcloud >/dev/null 2>&1; then
    tool_ok "gcloud already present"
    return 0
  fi
  detect_rc
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  export CLOUDSDK_INSTALL_DIR="$HOME"
  curl -fsSL https://sdk.cloud.google.com | bash \
    || { tool_warn "gcloud install failed"; return 1; }
  # gcloud ships path.bash.inc/path.zsh.inc/path.fish.inc and matching
  # completion files — pick the one that matches the user's shell.
  local inc="path.$SH.inc" comp="completion.$SH.inc"
  if ! grep -q "google-cloud-sdk/$inc" "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      echo "source \$HOME/google-cloud-sdk/$inc" >> "$RC"
    else
      echo "source \"\$HOME/google-cloud-sdk/$inc\"" >> "$RC"
    fi
  fi
  if ! grep -q "google-cloud-sdk/$comp" "$RC" 2>/dev/null; then
    if [ "$SH" = "fish" ]; then
      echo "source \$HOME/google-cloud-sdk/$comp" >> "$RC"
    else
      echo "source \"\$HOME/google-cloud-sdk/$comp\"" >> "$RC"
    fi
  fi
  tool_ok "gcloud installed to ~/google-cloud-sdk — run 'gcloud init' after restart"
}

install_toolchain() {
  local platform="$1"
  printf "\n%sinstalling training toolchain%s (skipping gamubash binary)\n" "$C_BOLD" "$C_RESET"

  case "$platform" in
    darwin-*)
      install_brew_mac || true
      brew_pkg vim vim
      brew_pkg nvim neovim
      brew_pkg tmux tmux
      install_direnv
      brew_pkg jq jq
      brew_pkg shellcheck shellcheck
      brew_pkg bats bats-core
      install_docker "$platform"
      install_nvm
      install_pyenv "$platform"
      install_gcloud
      ;;
    linux-*)
      warn "Linux support is best-effort — brew-only tools may be skipped"
      ensure_sudo_cached || warn "sudo caching failed — apt/docker steps will likely fail"
      apt_pkg vim vim
      apt_pkg nvim neovim
      apt_pkg tmux tmux
      install_direnv
      apt_pkg jq jq
      apt_pkg shellcheck shellcheck
      apt_pkg bats bats
      install_docker "$platform"
      install_nvm
      install_pyenv "$platform"
      install_gcloud
      ;;
  esac

  printf "\n%s✓ toolchain install complete.%s\n" "$C_GREEN" "$C_RESET"
  printf "  restart your terminal (or 'source %s') so PATH + hooks take effect.\n" "$RC"
}

# ── go ────────────────────────────────────────────────────────────────────────
main() {
  # Argument parsing — kept tiny on purpose (Module 7 reads this script).
  local scripts_only=0
  local tools_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --scripts)    scripts_only=1; shift ;;
      --tools-only) tools_only=1; shift ;;
      -h|--help)
        # When $0 points to a real file (clone-first mode), parse the comment
        # header. Under `curl | bash`, $0 is "bash" and the sed produces
        # nothing — fall back to an inline summary so --help is never silent.
        if [ -f "$0" ] && [ -r "$0" ]; then
          sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
        else
          cat <<HELP
gamubash installer — ${REPO_WEB}

flags:
  --scripts     install Go + Make only (no gamubash binary)
  --tools-only  install full dev toolchain (brew, vim, nvim, tmux, direnv,
                jq, shellcheck, bats, docker, nvm+node+npm, pyenv+python3,
                gcloud). Skips the gamubash binary.
  --help, -h    show this help

env overrides:
  GAMUBASH_FORCE_SOURCE=1     skip the prebuilt-binary fast-path
  GAMUBASH_NO_PATH_EDIT=1     don't touch your shell rc; just print PATH line
  GAMUBASH_NO_GIT_AUTH=1      don't try the git-clone source-build fallback
  GAMUBASH_ALLOW_GIT_PROMPT=1 let git prompt for HTTPS auth (private forks)
  GITHUB_TOKEN=...            bump GitHub API rate limit (60/hr → 5000/hr)

re-run the same command at any time to update (idempotent).
HELP
        fi
        return 0 ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  if [ "$scripts_only" = 1 ] && [ "$tools_only" = 1 ]; then
    die "--scripts and --tools-only are mutually exclusive (they install different things)"
  fi

  printf "%sGamuBash installer%s\n" "$C_BOLD" "$C_RESET"

  local platform
  platform="$(detect_platform)"

  # --tools-only mode: install the full dev toolchain (brew, vim, nvim, tmux,
  # direnv, jq, shellcheck, bats, docker, nvm+node+npm, pyenv+python3, gcloud)
  # without the gamubash binary. Mirrors doctor.go RunCmd snippets.
  if [ "$tools_only" = 1 ]; then
    install_toolchain "$platform"
    return 0
  fi

  # --scripts mode: install prerequisites only, no binary. Stops right after
  # Go + Make are confirmed and PATH is set up.
  if [ "$scripts_only" = 1 ]; then
    say "scripts-only mode: installing Go + Make, no gamubash binary"
    ensure_go
    ensure_make
    ensure_on_path
    print_next_steps_scripts
    return 0
  fi

  # Fast path: try downloading the prebuilt release binary. If it succeeds,
  # we're done — no Go, no git clone, no compile. If it fails for any reason
  # (no releases, no asset for this platform, network issue), fall through.
  if [ -z "${GAMUBASH_FORCE_SOURCE:-}" ]; then
    if try_install_from_release "$platform"; then
      ensure_on_path
      print_next_steps
      return 0
    fi
  else
    say "GAMUBASH_FORCE_SOURCE set — skipping release-binary fast-path"
  fi

  # Pre-emptive escape hatch: skip the source-build cascade entirely. Used by
  # users who know their git auth is broken/unwanted and don't want install.sh
  # to even attempt a clone. Auto-fallback (below, on actual clone failure)
  # routes to the SAME helper, so the user sees identical instructions either
  # way — hybrid behavior: try the automated path, fall back to scripts.
  if [ -n "${GAMUBASH_NO_GIT_AUTH:-}" ]; then
    print_manual_install_and_die \
      "release-binary path didn't install gamubash, and GAMUBASH_NO_GIT_AUTH=1 is set — skipping git-clone fallback."
  fi

  # Source-build path: install Go + Make if needed, clone-or-pull, build,
  # install. Make is required here so `cli/Makefile` is usable post-install.
  printf "%sbuilding from source (Go + Make required)%s\n\n" "$C_DIM" "$C_RESET"
  ensure_git
  ensure_go
  ensure_make
  clone_or_update
  build_and_install
  ensure_on_path
  print_next_steps
}

print_next_steps() {
  printf "\n%s✓ done.%s next steps:\n" "$C_GREEN" "$C_RESET"
  printf "  1. %sgamubash doctor%s   — see which training tools are missing\n" "$C_BOLD" "$C_RESET"
  printf "  2. %sgamubash whoami%s   — verify your push permission\n" "$C_BOLD" "$C_RESET"
  printf "  3. %sgamubash%s          — start the training\n" "$C_BOLD" "$C_RESET"
  if [ -n "${PATH_RC_EDITED:-}" ]; then
    # Surface the `source <rc>` callout last so it doesn't scroll past under
    # release-download output. Without this, users would tab to a new terminal
    # before realizing they could refresh PATH in the current one.
    printf "\n  %s↳ this terminal needs:%s %ssource %s%s\n" "$C_YELLOW" "$C_RESET" "$C_BOLD" "$PATH_RC_EDITED" "$C_RESET"
  fi
  printf "\n  to update: re-run the curl|bash command above (this script is idempotent)\n"
}

print_next_steps_scripts() {
  printf "\n%s✓ done.%s scripts-only setup complete.\n" "$C_GREEN" "$C_RESET"
  printf "  Go + Make installed; no gamubash binary was built.\n"
  printf "  next steps:\n"
  printf "  1. clone the curriculum if you haven't: %sgit clone %s%s\n" "$C_BOLD" "${REPO_URL}" "$C_RESET"
  printf "  2. follow modules in %s./modules/%s\n" "$C_BOLD" "$C_RESET"
  printf "  3. add the gamubash CLI later: %s./scripts/install.sh%s (no --scripts)\n" "$C_BOLD" "$C_RESET"
  if [ -n "${PATH_RC_EDITED:-}" ]; then
    printf "\n  %s↳ this terminal needs:%s %ssource %s%s\n" "$C_YELLOW" "$C_RESET" "$C_BOLD" "$PATH_RC_EDITED" "$C_RESET"
  fi
}

main "$@"
