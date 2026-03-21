# claude-pod

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in a rootless Podman container. The container **is** the security boundary, so Claude runs with `--dangerously-skip-permissions` safely.

## Install

Requires [Podman](https://podman.io/docs/installation) (rootless) and Claude Code on the host. If Podman is missing, claude-pod will detect your package manager and offer to install it.

```bash
curl -fsSL https://raw.githubusercontent.com/xukai92/claude-pod/main/claude-pod | bash -s -- install
```

This downloads `claude-pod` to `~/.local/bin/`, stages build files in `~/.local/share/claude-pod/`, and builds the container image.

## Usage

```bash
claude-pod                          # interactive session in current directory
claude-pod -- --model sonnet        # pass flags to Claude
claude-pod --network=none           # air-gapped session
claude-pod --detach                 # run in background
claude-pod -wd /extra/dir           # mount extra dir read-write
claude-pod shell                    # drop into a shell in the container
```

## How it works

- Each item under `$HOME` is mounted individually — most **read-only**, with `~/.claude`, `~/.config`, `~/.local` read-write
- CWD is mounted **read-write** at the same absolute path, so file paths match the host
- No Claude Code or bun in the image — picked up from the host via bind mounts
- Entrypoint runs through your login shell (bash, zsh, or fish) to inherit PATH

## Commands

| Command | Description |
|---------|-------------|
| `claude-pod install [--ref <ref>]` | Install claude-pod and build image |
| `claude-pod build` | Build/rebuild the container image |
| `claude-pod [run] [flags] [-- <claude args>]` | Start a session (default) |
| `claude-pod shell` | Shell into the container |
| `claude-pod exec <cmd>` | Run a command in a running container |
| `claude-pod ps` | List running claude-pod containers |
| `claude-pod clean` | Remove the container image |

### Run flags

| Flag | Description |
|------|-------------|
| `--detach` | Run in background |
| `--network=none` | Disable networking |
| `--notify <topic>` | [ntfy.sh](https://ntfy.sh) notification on exit |
| `--notify-cmd <cmd>` | Custom exit command (`$WORKSPACE`, `$EXIT_CODE`) |
| `-wd, --writable-dir <path>` | Extra read-write mount (repeatable) |

## Config

Optional: `~/.config/claude-pod/config.toml`

```toml
[defaults]
notify_command = "curl -s -d \"Claude done in $WORKSPACE (exit $EXIT_CODE)\" https://ntfy.sh/my-topic"
extra_volumes = ["/data/shared:/data/shared:ro"]
extra_env = ["GITHUB_TOKEN"]
```

## Security model

- **Rootless containers** via `podman --userns=keep-id` — no privilege escalation
- **Home is mostly read-only** — `~/.claude`, `~/.config`, `~/.local`, and cwd's parent are writable; everything else is read-only
- **`~/.claude.json` is copied in** at startup (changes don't sync back) — see [#7](https://github.com/xukai92/claude-pod/issues/7)
- **SELinux label=disable** instead of `:Z` to avoid relabeling host directories
- Auth via OAuth credentials in `~/.claude` or `ANTHROPIC_API_KEY` env var
- Use `--network=none` for tasks that don't need network access

## Development

From a local clone:

```bash
git clone https://github.com/xukai92/claude-pod.git
cd claude-pod
./claude-pod build   # uses Containerfile from the clone
./claude-pod         # run a session
./claude-pod install # install local version to ~/.local/bin
```

To test the one-liner from a branch (bypasses CDN caching):

```bash
curl -fsSL -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/xukai92/claude-pod/contents/claude-pod?ref=<branch>" \
  | bash -s -- install --ref <branch>
```

## License

MIT
