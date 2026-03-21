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
# File bind-mounts at $HOME/.claude.json break on atomic writes (EROFS),
# so we mount ro at /mnt and copy here. Changes won't sync back to host.
if [ -f /mnt/.claude.json ]; then
    cp /mnt/.claude.json "$HOME/.claude.json"
fi

# Run claude through a login shell so PATH and env are set up.
# Use "$@" to preserve argument boundaries safely.
case "$USER_SHELL" in
    */fish)
        "$USER_SHELL" -l -c 'claude --dangerously-skip-permissions $argv' -- "$@"
        ;;
    *)
        "$USER_SHELL" -l -c 'claude --dangerously-skip-permissions "$@"' claude "$@"
        ;;
esac
exit_code=$?

# Run notification command if set (receives WORKSPACE and EXIT_CODE as env vars)
if [ -n "${NOTIFY_CMD:-}" ]; then
    WORKSPACE=$(basename "$PWD") EXIT_CODE=$exit_code \
        sh -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
fi

exit "$exit_code"
