#!/bin/sh
# Entrypoint wrapper for claude-pod containers.
# Runs Claude Code via the user's login shell (to inherit PATH/config),
# then optionally runs a notification command on exit.

# Detect user's configured login shell, fall back to /bin/bash
USER_SHELL=$(getent passwd "$(id -un)" | cut -d: -f7)
USER_SHELL="${USER_SHELL:-/bin/bash}"

if [ ! -x "$USER_SHELL" ]; then
    echo "warning: $USER_SHELL not found, falling back to /bin/bash" >&2
    USER_SHELL=/bin/bash
fi

# Copy .claude.json from ro staging mount to writable $HOME.
# With per-item home mounts, $HOME/.claude.json lives on the writable
# container layer. Changes won't sync back to host.
if [ -f /mnt/.claude.json ]; then
    cp /mnt/.claude.json "$HOME/.claude.json"
fi

# If CLAUDE_POD_SHELL is set, drop into an interactive shell instead of claude
if [ -n "${CLAUDE_POD_SHELL:-}" ]; then
    exec "$USER_SHELL" -l
fi

CLAUDE_CMD="${CLAUDE_POD_CMD:-claude}"

# Prefer the in-image binary (installed at build time on macOS) over
# any host-mounted Mach-O binary that the login shell's PATH might find.
if [ "$CLAUDE_CMD" = "claude" ] && [ -x /usr/local/bin/claude ]; then
    CLAUDE_CMD=/usr/local/bin/claude
fi

# Determine whether to append --dangerously-skip-permissions.
# AI CLIs get the flag unless CLAUDE_POD_NO_YOLO is set; other commands run raw.
SKIP_PERMS=""
case "$CLAUDE_CMD" in
    *laude|opencode)
        if [ -z "${CLAUDE_POD_NO_YOLO:-}" ]; then
            SKIP_PERMS="--dangerously-skip-permissions"
        fi
        ;;
esac

# Run through a login shell so PATH and env are set up.
case "$USER_SHELL" in
    */fish)
        if [ -n "$SKIP_PERMS" ]; then
            "$USER_SHELL" -l -c '$argv[1] --dangerously-skip-permissions $argv[2..-1]' -- "$CLAUDE_CMD" "$@"
        else
            "$USER_SHELL" -l -c '$argv[1] $argv[2..-1]' -- "$CLAUDE_CMD" "$@"
        fi
        ;;
    *)
        if [ -n "$SKIP_PERMS" ]; then
            "$USER_SHELL" -l -c '"$0" --dangerously-skip-permissions "$@"' "$CLAUDE_CMD" "$@"
        else
            "$USER_SHELL" -l -c '"$0" "$@"' "$CLAUDE_CMD" "$@"
        fi
        ;;
esac
exit_code=$?

# Run notification command if set (receives WORKSPACE and EXIT_CODE as env vars)
if [ -n "${NOTIFY_CMD:-}" ]; then
    WORKSPACE=$(basename "$PWD") EXIT_CODE=$exit_code \
        sh -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
fi

exit "$exit_code"
