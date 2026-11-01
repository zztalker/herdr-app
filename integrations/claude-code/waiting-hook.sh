#!/bin/sh
# Claude Code Stop hook for Herdr: when Claude's turn ends while its own
# background shells still run, report an OSC 7501 record `bg` as working through
# `hc report`, so Herdr shows the agent as "waiting" instead of "done". The
# record is cleared once the background work ends or a new turn starts.
#
# Claude Code has no event for "background shell finished", so a small
# detached watcher polls Claude's session file (status "shell" = turn over,
# background shell alive) every 2 s. It runs only between a turn's end and
# that background work's end, one per terminal.
#
# Install (~/.claude/settings.json):
#   "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/path/to/waiting-hook.sh"}]}]}
set -u
[ -n "${HC_TERMINAL_ID:-}" ] || exit 0 # not in a Herdr terminal
HC=${HERDR_HC:-hc}
command -v "$HC" >/dev/null 2>&1 || exit 0
sid=$(jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
file=$(grep -l "\"sessionId\":\"$sid\"" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json 2>/dev/null | head -n 1)
[ -n "$file" ] || exit 0

lock="${TMPDIR:-/tmp}/herdr-waiting-$(id -u)-$HC_TERMINAL_ID"
if ! mkdir "$lock" 2>/dev/null; then
    # One watcher per terminal; take over only from one that died.
    kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null && exit 0
fi

(
    reported=0
    settle=0
    while status=$(jq -r '.status // empty' "$file" 2>/dev/null); do
        case $status in
        shell)
            [ "$reported" = 1 ] || { "$HC" report state=working:id=bg && reported=1; }
            ;;
        busy)
            # Right after Stop the file may still say busy; later, busy is a new turn.
            [ "$reported" = 0 ] && [ "$settle" -lt 10 ] || break
            settle=$((settle + 2))
            ;;
        *) break ;;
        esac
        sleep 2
    done
    [ "$reported" = 1 ] && "$HC" report state=clear:id=bg
    rm -rf "$lock"
) </dev/null >/dev/null 2>&1 &
echo $! >"$lock/pid"
exit 0
