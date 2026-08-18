#!/usr/bin/env bash
# Stop hook — lives in the PLUGIN at hooks/completion_ping.sh, wired by hooks/hooks.json.
# Runs when the ORCHESTRATOR session ends (workers don't load the plugin, so they never
# fire this). Acts as a dead-man's switch: if the orchestrator never sent a controlled
# success/failure notification (no `.notified` marker), assume it crashed and ping.
#
# Keep the ntfy topic in sync with the notify skill.

TOPIC="patrick-builds-projects-2025_2029"

# Controlled success/failure already reported by the notify skill → stay silent.
[[ -f .notified ]] && exit 0

curl -s \
  -H "Title: ⚠️ Build session ended unexpectedly" \
  -d "The orchestrator stopped without a success/failure notification — it may have crashed. Check the run." \
  "https://ntfy.sh/${TOPIC}" >/dev/null 2>&1

exit 0