# claude-pod

A Podman wrapper for running Claude Code in a rootless container sandbox.

## Architecture

- `Containerfile` — Minimal Fedora image with build tools. On Linux, Claude Code comes from the host via bind mounts. On macOS, it is installed in the image at build time (`INSTALL_CLAUDE=1`).
- `entrypoint.sh` — POSIX sh entrypoint that runs `claude --dangerously-skip-permissions` via the user's login shell, optionally notifies via ntfy.sh on exit.
- `claude-pod` — Bash wrapper script. Subcommands: `install`, `build`, `run` (default), `shell`, `exec`, `ps`, `clean`.
- `test.sh` — Test suite (run with `./test.sh`, no podman required).

## Key design decisions

- **Home contents mounted individually** — each item under `$HOME` is bind-mounted separately. `.claude`, `.config`, `.local` are rw; `.claude.json` is staged at `/mnt` and copied by entrypoint; cwd's parent dir is rw; everything else is ro.
- **CWD mounted at the same absolute path** inside the container so file paths match between host and container.
- **`--userns=keep-id`** maps host UID into container. The Containerfile creates a user matching the host user at build time via `--build-arg`.
- **`--security-opt label=disable`** to avoid SELinux relabeling host directories (`:Z` caused credential corruption).
- **Homebrew/linuxbrew** mounted read-only if `$HOMEBREW_PREFIX` is set.
- **No Claude/bun in image (Linux)** — picked up from the host via bind mounts. Entrypoint uses the host user's login shell (bash, zsh, or fish) to inherit PATH config.
- **Claude Code installed in image (macOS)** — host binaries are Mach-O and can't run in the Linux container, so `claude-pod build` passes `INSTALL_CLAUDE=1` to download the compiled Claude Code Linux binary from the official GCS bucket into `/usr/local/bin/claude`.
- **`--writable-dir` / `-wd` flag** for extra writable mounts on top of the ro home.
- **macOS support** — on Darwin, `--userns=keep-id` and `--security-opt label=disable` are skipped; `podman machine` is auto-started; `HOME_DIR` build arg ensures the container user's home matches the host (e.g. `/Users/you`).

## Versioning

`VERSION` is defined at the top of `claude-pod` and shown via `--version` / `--help`. **Bump the version in every PR that changes user-facing behavior** (new flags, changed defaults, install flow changes). Patch for fixes, minor for new features.

## Remaining work

- Consider: `.gitconfig` might need writable overlay if Claude does git operations
