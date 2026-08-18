#!/usr/bin/env bash
# SessionEnd hook — lives in the PLUGIN at hooks/completion_ping.sh, wired by hooks/hooks.json.
# Runs once when a session that loaded the plugin terminates (workers don't load the
# plugin, so they never fire this). Acts as a dead-man's switch: if a build was in
# progress (`.current_phase` exists) and the orchestrator never sent a controlled
# success/failure notification (no `.notified` marker), assume it crashed and ping.
#
# The topic comes from NTFY_TOPIC, same as the notify skill. No topic → no ping.

# Only alert for a session that actually had a build in flight.
[[ -f .current_phase ]] || exit 0

# Controlled success/failure already reported by the notify skill → stay silent.
[[ -f .notified ]] && exit 0

# A /clear is a deliberate user action, not a crash.
if command -v jq >/dev/null 2>&1; then
  reason=$(jq -r '.reason // empty' 2>/dev/null)
  [[ "$reason" == "clear" ]] && exit 0
fi

[[ -n "$NTFY_TOPIC" ]] || exit 0

curl -s \
  -H "Title: ⚠️ Build session ended unexpectedly" \
  -d "The orchestrator stopped without a success/failure notification — it may have crashed. Check the run." \
  "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1

exit 0
