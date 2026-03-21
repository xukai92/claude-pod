#!/bin/sh
# Entrypoint wrapper for claude-pod containers.
# Runs Claude Code via the user's login shell (to inherit PATH/config),
# then optionally sends an ntfy.sh notification on exit.

# Detect user's configured login shell, fall back to /bin/bash
USER_SHELL=$(getent passwd "$(id -un)" | cut -d: -f7)
USER_SHELL="${USER_SHELL:-/bin/bash}"

if [ ! -x "$USER_SHELL" ]; then
    echo "warning: $USER_SHELL not found, falling back to /bin/bash" >&2
    USER_SHELL=/bin/bash
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

# If NTFY_TOPIC is set, notify on exit
if [ -n "${NTFY_TOPIC:-}" ]; then
    workspace=$(basename "$PWD")
    curl -s -d "Claude Code session finished in $workspace (exit $exit_code)" \
        "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
fi

exit "$exit_code"
