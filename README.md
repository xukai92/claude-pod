# claude-pod

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a rootless Podman container. The container **is** the security boundary, so Claude runs with `--dangerously-skip-permissions` safely.

## How it works

Your home directory is mounted **read-only** into the container, with writable overlays for `~/.claude`, `~/.claude.json`, and `~/.local/share`. This means Claude picks up your shell config, SSH keys, git credentials, and toolchain automatically — without being able to modify them.

The current working directory is mounted **read-write** at the same absolute path, so file paths in Claude's output match the host.

No Claude Code or bun is installed in the image — they're picked up from the host via the read-only home mount. The entrypoint runs through your login shell (bash, zsh, or fish) to inherit your PATH.

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
- **Home is read-only** — Claude can read your config/keys but can't modify them. Only `~/.claude`, `~/.claude.json`, and `~/.local/share` are writable.
- **CWD is read-write** — Claude can only modify files in the directory you launch from (plus any `-wd` paths).
- **SELinux label=disable** instead of `:Z` to avoid relabeling host directories.
- Authentication works via OAuth credentials in `~/.claude` or `ANTHROPIC_API_KEY` env var — nothing is baked into the image.
- Use `--network=none` for tasks that don't need network access.

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
