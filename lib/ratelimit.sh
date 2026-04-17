#!/usr/bin/env bash
# Rate limit detection and auto-pause/resume

THROTTLE_AT="${SKILL_THROTTLE_AT:-85}"
PAUSE_AT="${SKILL_PAUSE_AT:-95}"

# Check rate limit from the most recent stream-json result file (free).
# Falls back to OAuth + Haiku call only if no result files exist yet.
# Outputs: status reset_ts [utilization]
check_rate_limit() {
  local run_dir="$1"

  # Try: parse rate_limit_event from most recent result file
  local latest
  latest=$(ls -t "$run_dir/results/"*.jsonl 2>/dev/null | head -1)
  if [[ -n "$latest" ]]; then
    local rl_line
    rl_line=$(grep 'rate_limit_event' "$latest" 2>/dev/null | tail -1)
    if [[ -n "$rl_line" ]]; then
      echo "$rl_line" | jq -r '
        [
          .rate_limit_info.status // "allowed",
          (.rate_limit_info.resetsAt // 0 | tostring)
        ] | join(" ")
      ' 2>/dev/null
      return
    fi
  fi

  # Fallback: OAuth + minimal Haiku call (only on first run before any results exist)
  _check_rate_limit_api
}

_check_rate_limit_api() {
  local token
  token=$(python3 -c "import json; print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || {
    echo "allowed 0"
    return
  }

  local headers
  headers=$(curl -s -D - -o /dev/null "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' 2>/dev/null)

  local status reset
  status=$(echo "$headers" | grep "unified-5h-status" | awk '{print $2}' | tr -d '\r')
  reset=$(echo "$headers" | grep "unified-5h-reset" | awk '{print $2}' | tr -d '\r')
  echo "${status:-allowed} ${reset:-0}"
}

# Get utilization percentage from the dashboard's subscription check.
# Reads from most recent result file's rate_limit_event.
# Returns integer 0-100 or empty string if unavailable.
get_utilization() {
  local run_dir="$1"
  local latest
  latest=$(ls -t "$run_dir/results/"*.jsonl 2>/dev/null | head -1)
  if [[ -n "$latest" ]]; then
    local rl_line
    rl_line=$(grep 'rate_limit_event' "$latest" 2>/dev/null | tail -1)
    if [[ -n "$rl_line" ]]; then
      # The rate_limit_event doesn't include utilization directly.
      # We get status only. For utilization we need the API call.
      echo ""
      return
    fi
  fi
  echo ""
}

wait_for_reset() {
  local reset_ts="$1"
  local now
  now=$(date +%s)
  local wait_secs=$((reset_ts - now))
  if [[ $wait_secs -gt 0 ]]; then
    log_warn "Rate limit reached. Waiting $(format_duration "$wait_secs") for reset at $(date -d "@$reset_ts" '+%H:%M:%S' 2>/dev/null || date -r "$reset_ts" '+%H:%M:%S' 2>/dev/null || echo "unknown")..."
    sound_task_failed
    # Sleep in 30s intervals so Ctrl+C is responsive
    while [[ $(date +%s) -lt $reset_ts ]]; do
      sleep 30
    done
    log_info "Rate limit window reset. Resuming..."
    sound_run_started
  fi
}

# Check if a failed run_one was a rate limit error.
# Reads the result file and checks for rate limit language.
is_rate_limit_error() {
  local result_file="$1"
  [[ ! -f "$result_file" ]] && return 1
  local result_text
  result_text=$(grep '"type":"result"' "$result_file" 2>/dev/null | tail -1 | jq -r '.result // ""' 2>/dev/null)
  echo "$result_text" | grep -qi "rate.limit\|rate_limit\|overloaded" && return 0
  return 1
}
