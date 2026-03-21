# claude-pod

A Podman wrapper for running Claude Code in a rootless container sandbox.

## Architecture

- `Containerfile` — Minimal Fedora image with build tools. No Claude/bun installed — they come from the host via bind mounts.
- `entrypoint.sh` — POSIX sh entrypoint that runs `claude --dangerously-skip-permissions` via the user's login shell, optionally notifies via ntfy.sh on exit.
- `claude-pod` — Bash wrapper script. Subcommands: `build`, `run` (default), `shell`, `exec`, `ps`, `clean`.

## Key design decisions

- **Home mounted read-only** with writable overlays for `~/.claude`, `~/.claude.json`, `~/.local/share`. This resolves symlinks, hooks, dotfiles, SSH keys automatically.
- **CWD mounted at the same absolute path** inside the container so file paths match between host and container.
- **`--userns=keep-id`** maps host UID into container. The Containerfile creates a user matching the host user at build time via `--build-arg`.
- **`--security-opt label=disable`** to avoid SELinux relabeling host directories (`:Z` caused credential corruption).
- **Homebrew/linuxbrew** mounted read-only if `$HOMEBREW_PREFIX` is set.
- **No Claude/bun in image** — both are picked up from the host home mount. Entrypoint uses the host user's login shell (bash, zsh, or fish) to inherit PATH config.
- **`--writable-dir` / `-wd` flag** for extra writable mounts on top of the ro home.

## Remaining work

- Update README.md to reflect current state (home mount approach, no in-image installs, etc.)
- Create GitHub repo and push
- Consider: `.gitconfig` might need writable overlay if Claude does git operations
