#!/usr/bin/env bash
# Rate limit detection and auto-pause/resume

THROTTLE_AT="${SKILL_THROTTLE_AT:-85}"
PAUSE_AT="${SKILL_PAUSE_AT:-95}"

# Cache file for API rate limit checks (avoids hammering the API)
_RL_CACHE="/tmp/skill-runner-rl-cache"
_RL_CACHE_TTL=30

# Check rate limit via OAuth API call (cached for 30s).
# Outputs: status reset_ts utilization_pct
# Example: "allowed 1776456000 17"
check_rate_limit() {
  local run_dir="$1"

  # Return cached result if fresh enough
  if [[ -f "$_RL_CACHE" ]]; then
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$_RL_CACHE" 2>/dev/null || echo 0) ))
    if [[ $cache_age -lt $_RL_CACHE_TTL ]]; then
      cat "$_RL_CACHE"
      return
    fi
  fi

  # Try stream-json first for status (free, but no utilization %)
  local stream_status="" stream_reset=""
  local latest
  latest=$(ls -t "$run_dir/results/"*.jsonl 2>/dev/null | head -1)
  if [[ -n "$latest" ]]; then
    local rl_line
    rl_line=$(grep 'rate_limit_event' "$latest" 2>/dev/null | tail -1)
    if [[ -n "$rl_line" ]]; then
      stream_status=$(echo "$rl_line" | jq -r '.rate_limit_info.status // ""' 2>/dev/null)
      stream_reset=$(echo "$rl_line" | jq -r '.rate_limit_info.resetsAt // 0' 2>/dev/null)
    fi
  fi

  # If stream says blocked, no need for API call
  if [[ "$stream_status" == "blocked" || "$stream_status" == "rejected" ]]; then
    local result="$stream_status $stream_reset 100"
    echo "$result" > "$_RL_CACHE" 2>/dev/null
    echo "$result"
    return
  fi

  # API call to get utilization percentage
  local api_result
  api_result=$(_check_rate_limit_api)
  echo "$api_result" > "$_RL_CACHE" 2>/dev/null
  echo "$api_result"
}

_check_rate_limit_api() {
  local token
  token=$(python3 -c "import json; print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null) || {
    echo "allowed 0 0"
    return
  }

  local headers
  headers=$(curl -s -D - -o /dev/null "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $token" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' 2>/dev/null)

  local status reset util
  status=$(echo "$headers" | grep "unified-5h-status" | awk '{print $2}' | tr -d '\r')
  reset=$(echo "$headers" | grep "unified-5h-reset" | awk '{print $2}' | tr -d '\r')
  util=$(echo "$headers" | grep "unified-5h-utilization" | awk '{print $2}' | tr -d '\r')

  # Convert utilization float (0.17) to integer percent (17)
  local util_pct=0
  if [[ -n "$util" ]]; then
    util_pct=$(python3 -c "print(int(float('$util') * 100))" 2>/dev/null || echo 0)
  fi

  echo "${status:-allowed} ${reset:-0} ${util_pct}"
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
    # Clear cache so next check gets fresh data
    rm -f "$_RL_CACHE"
    sound_run_started
  fi
}

# Check if a failed run_one was a rate limit error.
is_rate_limit_error() {
  local result_file="$1"
  [[ ! -f "$result_file" ]] && return 1
  local result_text
  result_text=$(grep '"type":"result"' "$result_file" 2>/dev/null | tail -1 | jq -r '.result // ""' 2>/dev/null)
  echo "$result_text" | grep -qi "rate.limit\|rate_limit\|overloaded" && return 0
  return 1
}
