# claude-pod

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a rootless Podman container. The container **is** the security boundary, so Claude runs with `--dangerously-skip-permissions` safely.

## How it works

Each item under your home directory is mounted individually — most are **read-only**, with `~/.claude`, `~/.config`, and `~/.local` mounted read-write. `~/.claude.json` is copied into the container at startup (changes don't sync back). The directory containing your cwd is also mounted read-write.

The current working directory is mounted **read-write** at the same absolute path, so file paths in Claude's output match the host. (If cwd is `$HOME` or inside an existing writable overlay, the extra mount is skipped to avoid conflicts.)

No Claude Code or bun is installed in the image — they're picked up from the host via the home bind mounts. The entrypoint runs through your login shell (bash, zsh, or fish) to inherit your PATH.

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
| `claude-pod install` | Install claude-pod to `~/.local/bin` and build image |
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
- **Home is mostly read-only** — each item under `$HOME` is mounted individually. `~/.claude`, `~/.config`, `~/.local`, and cwd's parent are writable; everything else is read-only. `~/.claude.json` is copied in at startup (changes don't sync back).
- **CWD is read-write** — the top-level `$HOME` directory containing your cwd is mounted read-write (e.g. `~/src` when launching from `~/src/project`). Additional dirs can be made writable with `-wd`.
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

**One-liner** (downloads from GitHub, installs to `~/.local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/xukai92/claude-pod/main/claude-pod | bash -s -- install
```

**From a local clone** (for development):

```bash
git clone https://github.com/xukai92/claude-pod.git
cd claude-pod
./claude-pod install
```

Both paths copy `claude-pod`, `entrypoint.sh`, and `Containerfile` to `~/.local/share/claude-pod/`, install the script to `~/.local/bin/claude-pod`, and build the container image.

### Development

When developing locally, you can run `claude-pod` directly from the clone without installing:

```bash
./claude-pod build   # uses Containerfile from the clone
./claude-pod         # run a session
```

If you previously ran `install`, the installed copy in `~/.local/bin` is independent of the clone. Run `./claude-pod install` again to update it with your local changes.

To test the one-liner install from a branch, use the GitHub API to bypass CDN caching and `--ref` to download all files from the same branch:

```bash
curl -fsSL -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/xukai92/claude-pod/contents/claude-pod?ref=<branch>" \
  | bash -s -- install --ref <branch>
```

Note: `raw.githubusercontent.com` caches aggressively and query-string cache busting does not work. The `--ref` flag ensures `entrypoint.sh` and `Containerfile` are also fetched from the branch.

## License

MIT
