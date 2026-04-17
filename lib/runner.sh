#!/usr/bin/env bash
# Core execution loop — runs claude -p for each input (sequential or parallel)

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

  # Parse result from stream-json (take LAST result event — there can be multiple)
  local cost="0" turns="0" session="" is_error="false"
  if [[ $exit_code -eq 0 ]] && [[ -s "$result_file" ]]; then
    local result_line
    result_line=$(grep '"type":"result"' "$result_file" | tail -1)
    if [[ -n "$result_line" ]]; then
      cost=$(echo "$result_line" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo "0")
      turns=$(echo "$result_line" | jq -r '.num_turns // 0' 2>/dev/null || echo "0")
      session=$(echo "$result_line" | jq -r '.session_id // ""' 2>/dev/null || echo "")
      is_error=$(echo "$result_line" | jq -r '.is_error // false' 2>/dev/null || echo "false")
    fi
  fi

  if [[ "$is_error" == "true" ]] || [[ $exit_code -ne 0 ]]; then
    mark_status "$run_dir" "$input" "failed" "$cost" "$turns" "$duration" "$session"
    return 1
  else
    mark_status "$run_dir" "$input" "completed" "$cost" "$turns" "$duration" "$session"
    return 0
  fi
}

# Worker wrapper — runs one input with logging and sounds
_run_worker() {
  local input="$1" run_dir="$2" idx="$3" total="$4"

  log_info "[$idx/$total] Running: $input"
  mark_status "$run_dir" "$input" "running" "0" "0" "0" ""
  sound_task_starting

  if run_one "$input" "$run_dir"; then
    local last_cost last_turns last_dur
    last_cost=$(grep "\"input\":\"${input}\".*\"completed\"" "$run_dir/progress.jsonl" | tail -1 | jq -r '.cost_usd // 0' 2>/dev/null || echo "0")
    last_turns=$(grep "\"input\":\"${input}\".*\"completed\"" "$run_dir/progress.jsonl" | tail -1 | jq -r '.turns // 0' 2>/dev/null || echo "0")
    last_dur=$(grep "\"input\":\"${input}\".*\"completed\"" "$run_dir/progress.jsonl" | tail -1 | jq -r '.duration_s // 0' 2>/dev/null || echo "0")
    log_success "[$idx/$total] DONE: $input  (${last_turns} turns, $(format_duration "$last_dur"), \$${last_cost})"
    sound_task_completed
  else
    # Check if it was a rate limit error — mark as paused instead of failed
    local safe_name
    safe_name=$(echo "$input" | tr -c 'a-zA-Z0-9._-' '_')
    local result_file="$run_dir/results/${safe_name}.jsonl"
    if is_rate_limit_error "$result_file"; then
      log_warn "[$idx/$total] RATE LIMITED: $input — will retry after reset"
      mark_status "$run_dir" "$input" "paused" "0" "0" "0" ""
    else
      log_error "[$idx/$total] FAILED: $input"
      sound_task_failed
    fi
  fi
}

# ── Sequential batch (default, -j 1) ───────────────────────────────────
run_batch_sequential() {
  local run_dir="$1"
  local inputs_file="$run_dir/inputs.txt"
  local total
  total=$(wc -l < "$inputs_file" | tr -d '[:space:]')
  local current=0

  while IFS= read -r input || [[ -n "$input" ]]; do
    [[ -z "$input" ]] && continue
    current=$((current + 1))

    if is_completed "$run_dir" "$input"; then
      log_dim "[$current/$total] SKIP $input (already completed)"
      continue
    fi

    # Proactive rate limit check
    local rl_status rl_reset rl_util
    read -r rl_status rl_reset rl_util <<< "$(check_rate_limit "$run_dir")"
    if [[ "$rl_status" == "blocked" || "$rl_status" == "rejected" ]]; then
      log_warn "Rate limit blocked — waiting for reset"
      wait_for_reset "$rl_reset"
    elif [[ -n "$rl_util" && "$rl_util" -gt 0 && "$rl_util" -ge "$PAUSE_AT" ]]; then
      log_warn "Utilization at ${rl_util}% (>= ${PAUSE_AT}%) — pausing until reset"
      wait_for_reset "$rl_reset"
    fi

    _run_worker "$input" "$run_dir" "$current" "$total"

    # If last worker was paused (rate limited), wait and retry
    if grep -q "\"input\":\"${input}\".*\"paused\"" "$run_dir/progress.jsonl" 2>/dev/null; then
      read -r rl_status rl_reset <<< "$(check_rate_limit "$run_dir")"
      wait_for_reset "$rl_reset"
      _run_worker "$input" "$run_dir" "$current" "$total"
    fi

  done < "$inputs_file"
}

# ── Parallel batch (-j N where N > 1) ──────────────────────────────────
run_batch_parallel() {
  local run_dir="$1" max_jobs="$2"
  local inputs_file="$run_dir/inputs.txt"
  local total
  total=$(wc -l < "$inputs_file" | tr -d '[:space:]')

  # Build queue of inputs to process (skip completed)
  local -a queue=()
  local -a queue_idx=()
  local current=0
  while IFS= read -r input || [[ -n "$input" ]]; do
    [[ -z "$input" ]] && continue
    current=$((current + 1))
    if is_completed "$run_dir" "$input"; then
      log_dim "[$current/$total] SKIP $input (already completed)"
      continue
    fi
    queue+=("$input")
    queue_idx+=("$current")
  done < "$inputs_file"

  local queue_len=${#queue[@]}
  if [[ $queue_len -eq 0 ]]; then
    log_info "Nothing to process"
    return
  fi

  log_info "Processing $queue_len inputs with $max_jobs parallel workers"

  local -a active_pids=()
  local next=0
  local active_count=0

  while [[ $next -lt $queue_len ]] || [[ $active_count -gt 0 ]]; do
    # Recount active workers (prune dead PIDs)
    local -a still_alive=()
    active_count=0
    for p in "${active_pids[@]}"; do
      [[ -z "$p" ]] && continue
      if kill -0 "$p" 2>/dev/null; then
        still_alive+=("$p")
        active_count=$((active_count + 1))
      fi
    done
    active_pids=("${still_alive[@]+"${still_alive[@]}"}")

    # Launch workers up to max_jobs (with rate limit awareness)
    local effective_max=$max_jobs
    while [[ $active_count -lt $effective_max ]] && [[ $next -lt $queue_len ]]; do
      # Proactive rate limit check before each launch
      local rl_status rl_reset rl_util
      read -r rl_status rl_reset rl_util <<< "$(check_rate_limit "$run_dir")"

      if [[ "$rl_status" == "blocked" || "$rl_status" == "rejected" ]]; then
        log_warn "Rate limit blocked — waiting for reset"
        wait 2>/dev/null
        active_pids=()
        active_count=0
        wait_for_reset "$rl_reset"
        effective_max=$max_jobs
        continue
      fi

      # Percentage-based throttling
      if [[ -n "$rl_util" && "$rl_util" -gt 0 ]]; then
        if [[ "$rl_util" -ge "$PAUSE_AT" ]]; then
          log_warn "Utilization at ${rl_util}% (>= ${PAUSE_AT}%) — pausing until reset"
          wait 2>/dev/null
          active_pids=()
          active_count=0
          wait_for_reset "$rl_reset"
          effective_max=$max_jobs
          continue
        elif [[ "$rl_util" -ge "$THROTTLE_AT" && $effective_max -gt 1 ]]; then
          log_warn "Utilization at ${rl_util}% (>= ${THROTTLE_AT}%) — throttling to 1 worker"
          effective_max=1
        fi
      fi

      local inp="${queue[$next]}"
      local idx="${queue_idx[$next]}"
      next=$((next + 1))

      _run_worker "$inp" "$run_dir" "$idx" "$total" &
      active_pids+=("$!")
      CHILD_PIDS+=("$!")
      active_count=$((active_count + 1))

      # Stagger launches for cache efficiency
      sleep 2
    done

    # Poll interval
    sleep 2
  done

  # Wait for any remaining workers
  wait 2>/dev/null

  # Re-queue any paused inputs (rate limited during this run)
  local -a paused_inputs=()
  local -a paused_idx=()
  for i in "${!queue[@]}"; do
    local inp="${queue[$i]}"
    if grep -q "\"input\":\"${inp}\".*\"paused\"" "$run_dir/progress.jsonl" 2>/dev/null; then
      if ! is_completed "$run_dir" "$inp"; then
        paused_inputs+=("$inp")
        paused_idx+=("${queue_idx[$i]}")
      fi
    fi
  done

  if [[ ${#paused_inputs[@]} -gt 0 ]]; then
    log_info "${#paused_inputs[@]} inputs were rate-limited — retrying after reset"
    local rl_status rl_reset
    read -r rl_status rl_reset <<< "$(check_rate_limit "$run_dir")"
    wait_for_reset "$rl_reset"

    queue=("${paused_inputs[@]}")
    queue_idx=("${paused_idx[@]}")
    queue_len=${#queue[@]}
    next=0
    active_pids=()
    active_count=0

    # Re-run the parallel loop for paused inputs
    while [[ $next -lt $queue_len ]] || [[ $active_count -gt 0 ]]; do
      local -a still_alive=()
      active_count=0
      for p in "${active_pids[@]}"; do
        [[ -z "$p" ]] && continue
        if kill -0 "$p" 2>/dev/null; then
          still_alive+=("$p")
          active_count=$((active_count + 1))
        fi
      done
      active_pids=("${still_alive[@]+"${still_alive[@]}"}")

      while [[ $active_count -lt $max_jobs ]] && [[ $next -lt $queue_len ]]; do
        local inp="${queue[$next]}"
        local idx="${queue_idx[$next]}"
        next=$((next + 1))
        _run_worker "$inp" "$run_dir" "$idx" "$total" &
        active_pids+=("$!")
        CHILD_PIDS+=("$!")
        active_count=$((active_count + 1))
        sleep 2
      done
      sleep 2
    done
    wait 2>/dev/null
  fi
}

# ── Entry point ─────────────────────────────────────────────────────────
run_batch() {
  local run_dir="$1"
  local parallel="${2:-1}"
  local inputs_file="$run_dir/inputs.txt"
  local total
  total=$(wc -l < "$inputs_file" | tr -d '[:space:]')
  local completed
  completed=$(get_completed_count "$run_dir")

  log_info "Starting batch: $total inputs, $completed already completed, $parallel parallel"
  sound_run_started
  echo ""

  if [[ "$parallel" -le 1 ]]; then
    run_batch_sequential "$run_dir"
  else
    run_batch_parallel "$run_dir" "$parallel"
  fi

  completed=$(get_completed_count "$run_dir")
  local failed
  failed=$(get_failed_count "$run_dir")
  log_info "Batch complete: $completed completed, $failed failed out of $total"
  sound_batch_complete
}
