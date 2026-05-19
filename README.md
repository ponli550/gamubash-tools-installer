# gamubash-tools-installer

One-shot installer for the GamuBash CLI and its dev toolchain. Re-run any time to update — the script is idempotent.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ponli550/gamubash-tools-installer/main/install.sh | bash
```

### Variants

Prerequisites only (Go + Make, no CLI build):

```bash
curl -fsSL https://raw.githubusercontent.com/ponli550/gamubash-tools-installer/main/install.sh | bash -s -- --scripts
```

Full dev toolchain (brew, vim, nvim, tmux, direnv, jq, shellcheck, bats, docker, nvm+node, pyenv+python3, gcloud — skips the CLI binary):

```bash
curl -fsSL https://raw.githubusercontent.com/ponli550/gamubash-tools-installer/main/install.sh | bash -s -- --tools-only
```

## What it does

1. Detects platform (macOS/Linux, arm64/x86_64).
2. Downloads the latest release binary from GitHub Releases when available (~5 s, no Go needed).
3. Falls back to installing Go and building from source when no release binary matches.
4. Drops the binary into `~/.local/bin` and adds it to `PATH` in your shell rc (`~/.zshrc` / `~/.bashrc` / `~/.profile`).

## Environment overrides

| Var | Effect |
|---|---|
| `GAMUBASH_REPO_URL` | Git remote to clone from (default `ponli550/GamuBash`) |
| `GAMUBASH_RELEASE_REPO` | `owner/name` slug for release downloads |
| `GAMUBASH_FORCE_SOURCE=1` | Skip the binary fast-path; always build from source |
| `GAMUBASH_NO_PATH_EDIT=1` | Don't touch shell rc; just print PATH instructions |
| `GAMUBASH_ALLOW_GIT_PROMPT=1` | Allow git to prompt for HTTPS auth |
| `GAMUBASH_NO_GIT_AUTH=1` | Don't fall back to git-clone source build if the release path fails |

## Clone-first alternative

If `curl | bash` isn't an option (e.g. behind a proxy that mangles redirects):

```bash
git clone https://github.com/ponli550/gamubash-tools-installer.git
cd gamubash-tools-installer
./install.sh            # or: ./install.sh --scripts
```
