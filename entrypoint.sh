#!/usr/bin/fish
# Entrypoint wrapper for claude-pod containers.
# Runs Claude Code, then optionally sends an ntfy.sh notification on exit.
# Uses fish shell to pick up the user's PATH and config automatically.

claude --dangerously-skip-permissions $argv
set exit_code $status

# If NTFY_TOPIC is set, notify on exit
if set -q NTFY_TOPIC; and test -n "$NTFY_TOPIC"
    set workspace (basename "$PWD")
    curl -s -d "Claude Code session finished in $workspace (exit $exit_code)" \
        "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1; or true
end

exit $exit_code
