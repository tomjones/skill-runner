#!/usr/bin/env bash
# Core execution loop — runs claude -p for each input

# Live stream filter — shows condensed claude activity on the terminal
# Reads stream-json lines, extracts tool use and text output
_stream_filter() {
  local input="$1"
  local log_file="$2"
  local _clr_dim='\033[2m'
  local _clr_cyan='\033[0;36m'
  local _clr_reset='\033[0m'

  while IFS= read -r line; do
    # Extract tool use events (show which tool claude is calling)
    local tool_name
    tool_name=$(echo "$line" | jq -r '
      select(.type == "assistant")
      | .message.content[]?
      | select(.type == "tool_use")
      | .name // empty
    ' 2>/dev/null)
    if [[ -n "$tool_name" ]]; then
      local msg="  [$input] tool: $tool_name"
      printf "${_clr_dim}%s${_clr_reset}\n" "$msg" >&2
      [[ -n "$log_file" ]] && echo "$msg" >> "$log_file"
      continue
    fi

    # Extract text output (show what claude is saying)
    local text
    text=$(echo "$line" | jq -r '
      select(.type == "assistant")
      | .message.content[]?
      | select(.type == "text")
      | .text // empty
    ' 2>/dev/null)
    if [[ -n "$text" ]]; then
      # Show first 200 chars of each text block
      local preview="${text:0:200}"
      preview=$(echo "$preview" | tr '\n' ' ')
      local msg="  [$input] $preview"
      printf "${_clr_cyan}%s${_clr_reset}\n" "$msg" >&2
      [[ -n "$log_file" ]] && echo "$msg" >> "$log_file"
    fi
  done
}

run_one() {
  local input="$1" run_dir="$2"
  local safe_name
  safe_name=$(echo "$input" | tr -c 'a-zA-Z0-9._-' '_')
  local result_file="$run_dir/results/${safe_name}.jsonl"
  local run_log="$run_dir/run.log"

  # Build prompt
  local prompt="${SKILL} ${input}"

  local start_time
  start_time=$(date +%s)

  # Execute claude with stream-json for real-time output
  # tee saves full stream to file while filter shows live activity
  set +e
  (cd "$WORKDIR" && claude -p "$prompt" \
    --output-format stream-json \
    --verbose \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$ALLOWED_TOOLS" \
    </dev/null \
    2>>"$run_log" \
    | tee "$result_file" \
    | _stream_filter "$input" "$run_log"
  )
  local exit_code=$?
  set -e

  local end_time duration
  end_time=$(date +%s)
  duration=$((end_time - start_time))

  # Parse result from stream-json (each line is a JSON object, find the result line)
  local cost="0" turns="0" session="" is_error="false"
  if [[ $exit_code -eq 0 ]] && [[ -s "$result_file" ]]; then
    cost=$(grep '"type":"result"' "$result_file" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
    turns=$(grep '"type":"result"' "$result_file" | jq -r '.num_turns // 0' 2>/dev/null || echo "0")
    session=$(grep '"type":"result"' "$result_file" | jq -r '.session_id // ""' 2>/dev/null || echo "")
    is_error=$(grep '"type":"result"' "$result_file" | jq -r '.is_error // false' 2>/dev/null || echo "false")
  fi

  local duration_fmt
  duration_fmt=$(format_duration "$duration")

  if [[ "$is_error" == "true" ]] || [[ $exit_code -ne 0 ]]; then
    mark_status "$run_dir" "$input" "failed" "$cost" "$turns" "$duration" "$session"
    return 1
  else
    mark_status "$run_dir" "$input" "completed" "$cost" "$turns" "$duration" "$session"
    return 0
  fi
}

run_batch() {
  local run_dir="$1"
  local inputs_file="$run_dir/inputs.txt"
  local total
  total=$(wc -l < "$inputs_file" | tr -d '[:space:]')
  local current=0 completed=0 failed=0

  # Pre-count already completed (for resume)
  completed=$(get_completed_count "$run_dir")

  log_info "Starting batch: $total inputs, $completed already completed"
  sound_run_started
  echo ""

  while IFS= read -r input || [[ -n "$input" ]]; do
    # Skip empty lines
    [[ -z "$input" ]] && continue

    current=$((current + 1))

    # Skip if already completed (resume)
    if is_completed "$run_dir" "$input"; then
      log_dim "[$current/$total] SKIP $input (already completed)"
      continue
    fi

    log_info "[$current/$total] Running: $input"
    mark_status "$run_dir" "$input" "running" "0" "0" "0" ""
    sound_task_starting

    if run_one "$input" "$run_dir"; then
      completed=$((completed + 1))
      local last_cost last_turns last_dur
      last_cost=$(tail -1 "$run_dir/progress.jsonl" | jq -r '.cost_usd // 0')
      last_turns=$(tail -1 "$run_dir/progress.jsonl" | jq -r '.turns // 0')
      last_dur=$(tail -1 "$run_dir/progress.jsonl" | jq -r '.duration_s // 0')
      log_success "[$current/$total] DONE: $input  (${last_turns} turns, $(format_duration "$last_dur"), \$${last_cost})"
      sound_task_completed
    else
      failed=$((failed + 1))
      log_error "[$current/$total] FAILED: $input"
      sound_task_failed
    fi

  done < "$inputs_file"

  log_info "Batch complete: $completed completed, $failed failed out of $total"
  sound_batch_complete
}
