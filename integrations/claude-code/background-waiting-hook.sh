#!/bin/sh
# Claude Code Stop hook for Herdr: when Claude's turn ends while its own
# background shells still run, report an OSC 7501 record `bg` as working through
# `hc report`, so Herdr shows the agent as "background-waiting" instead of "done". The
# record is cleared once Claude's session is idle again.
#
# Claude Code has no event for "background shell finished", so a small detached
# watcher polls Claude's session file (status "shell" = turn over, background
# shell alive) every 2 s. One watcher per terminal: each Stop takes over from
# the previous turn's.
#
# Install (~/.claude/settings.json):
#   "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/path/to/background-waiting-hook.sh"}]}]}
set -u
[ -n "${HC_TERMINAL_ID:-}" ] || exit 0 # not in a Herdr terminal
HC=${HERDR_HC:-hc}
command -v "$HC" >/dev/null 2>&1 || exit 0
poll=${HERDR_BACKGROUND_WAITING_POLL:-2}
sid=$(jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
# The session's file, by its parsed sessionId (any JSON formatting; unreadable files skipped).
file=
for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json; do
    if jq -e --arg sid "$sid" '.sessionId == $sid' "$f" >/dev/null 2>&1; then
        file=$f
        break
    fi
done
[ -n "$file" ] || exit 0

state() { jq -r '.status // empty' "$file" 2>/dev/null; }
lock="${TMPDIR:-/tmp}/herdr-background-waiting-$(id -u)-$HC_TERMINAL_ID"
reported="$lock/reported" # present while the bg record is set
mkdir -p "$lock"

# This Stop owns the record from now on: end the previous turn's watcher, so
# its view of an older turn can't clear what this one reports.
old=$(cat "$lock/pid" 2>/dev/null)
if [ -n "$old" ] && kill "$old" 2>/dev/null; then
    i=0
    while kill -0 "$old" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.05
        i=$((i + 1))
    done
fi
rm -f "$lock/pid"

report() { "$HC" report state=working:id=bg >/dev/null 2>&1 && : >"$reported"; }
clear() {
    [ -e "$reported" ] && "$HC" report state=clear:id=bg >/dev/null 2>&1
    rm -rf "$lock"
}

# Right after Stop the file may still say busy for a moment. Settle here, before
# returning, so a running shell is reported before Claude's own `done` can reach
# Herdr as a finish.
s=$(state)
i=0
while [ "$s" = busy ] && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
    s=$(state)
done
case $s in
shell) report ;;
busy) ;; # still settling: the watcher decides
*)
    clear # nothing in the background (clears what a replaced watcher left)
    exit 0
    ;;
esac

# Busy is a new turn (Herdr shows it as working either way): keep the record and
# let that turn's Stop take over. Anything else, or no file (Claude exited), ends it.
(
    while s=$(state) && [ -n "$s" ]; do
        case $s in
        shell) [ -e "$reported" ] || report ;;
        busy) ;;
        *) break ;;
        esac
        sleep "$poll"
    done
    clear
) </dev/null >/dev/null 2>&1 &
echo $! >"$lock/pid"
exit 0
