#!/bin/sh
# Entrypoint wrapper for claude-pod containers.
# Runs Claude Code via the user's login shell (to inherit PATH/config),
# then optionally sends an ntfy.sh notification on exit.

# Detect user's configured shell
USER_SHELL=$(getent passwd "$(whoami)" | cut -d: -f7)

# Build the claude command
claude_cmd="claude --dangerously-skip-permissions $*"

# Run claude through a login shell so PATH and env are set up
case "$USER_SHELL" in
    */fish)
        $USER_SHELL -l -c "$claude_cmd"
        ;;
    *)
        # bash, zsh, sh — all support -l -c
        $USER_SHELL -l -c "$claude_cmd"
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
