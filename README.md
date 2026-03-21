# claude-pod

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a rootless Podman container. The container **is** the security boundary, so Claude runs with `--dangerously-skip-permissions` safely.

## How it works

Each item under your home directory is mounted individually into the container — most are **read-only**, with `~/.claude`, `~/.config`, and `~/.local` mounted **read-write** (shells and tools need to write there). `~/.claude.json` is skipped (the container creates a fresh one). This means Claude picks up your shell config, SSH keys, git credentials, and toolchain automatically — without being able to modify most of them.

The current working directory is mounted **read-write** at the same absolute path, so file paths in Claude's output match the host. (If cwd is `$HOME` or inside an existing writable overlay, the extra mount is skipped to avoid conflicts.)

No Claude Code or bun is installed in the image — they're picked up from your host `$HOME` via the individual bind mounts. The entrypoint runs through your login shell (bash, zsh, or fish) to inherit your PATH.

## Quick start

```bash
# Build the image (once, per user — encodes your UID/GID)
claude-pod build

# Run an interactive session in the current directory
claude-pod
```

## Commands

| Command | Description |
|---------|-------------|
| `claude-pod build` | Build the container image for your user |
| `claude-pod [run] [flags] [-- <claude args>]` | Start an interactive session (default command) |
| `claude-pod shell` | Drop into a bash shell in the container |
| `claude-pod exec <cmd>` | Run a command in a running container |
| `claude-pod ps` | List running claude-pod containers |
| `claude-pod clean` | Remove the container image |

### Run flags

| Flag | Description |
|------|-------------|
| `--detach` | Run in background (print container ID) |
| `--network=none` | Fully air-gapped session |
| `--notify <topic>` | Send an [ntfy.sh](https://ntfy.sh) notification when the session ends |
| `--notify-cmd <cmd>` | Run a custom command on exit (receives `$WORKSPACE` and `$EXIT_CODE` env vars) |
| `-wd, --writable-dir <path>` | Mount an additional directory read-write (repeatable) |

Pass arguments to Claude itself after `--`:

```bash
claude-pod -- --model sonnet --resume
```

## Config file

Optional: `~/.config/claude-pod/config.toml`

```toml
[defaults]
# Notification command — receives $WORKSPACE and $EXIT_CODE as env vars
# (--notify <topic> is a shorthand for ntfy.sh and overrides this)
notify_command = "curl -s -d \"Claude done in $WORKSPACE (exit $EXIT_CODE)\" https://ntfy.sh/my-topic"

# Extra volumes to mount
extra_volumes = ["/data/shared:/data/shared:ro"]

# Extra env vars to pass through from host
extra_env = ["GITHUB_TOKEN"]
```

## Security model

- **Rootless containers** via `podman --userns=keep-id` — no privilege escalation.
- **Home is mostly read-only** — each item under `$HOME` is mounted individually. Only `~/.claude`, `~/.config`, and `~/.local` are writable. `~/.claude.json` is not mounted (fresh copy per session).
- **CWD is read-write** — Claude can only modify files in the directory you launch from (plus any `-wd` paths).
- **SELinux label=disable** instead of `:Z` to avoid relabeling host directories.
- Authentication works via OAuth credentials in `~/.claude` or `ANTHROPIC_API_KEY` env var — nothing is baked into the image.
- Use `--network=none` for tasks that don't need network access.

## Known limitations

- **`~/.claude.json` is copied into the container at startup** — changes during the session don't sync back to the host. File bind-mounts at the real path break on atomic writes (bun's rename-over-target causes EROFS). The file only contains caches and UI state, so not syncing back is acceptable. See [#7](https://github.com/xukai92/claude-pod/issues/7).

## Requirements

- Podman (rootless)
- Linux (tested on Fedora 41)
- Claude Code installed on the host (via Homebrew, npm, etc.)

## Install

```bash
git clone https://github.com/xukai92/claude-pod.git
cd claude-pod
./claude-pod build

# Optional: add to PATH
ln -s "$(pwd)/claude-pod" ~/.local/bin/claude-pod
```

## License

MIT
