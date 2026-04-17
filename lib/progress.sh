#!/usr/bin/env bash
# JSONL-based progress tracking — append-only, crash-safe

mark_status() {
  local run_dir="$1" input="$2" status="$3"
  local cost="${4:-0}" turns="${5:-0}" duration="${6:-0}" session="${7:-}"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  printf '{"input":"%s","status":"%s","cost_usd":%s,"turns":%s,"duration_s":%s,"session_id":"%s","timestamp":"%s"}\n' \
    "$input" "$status" "$cost" "$turns" "$duration" "$session" "$ts" \
    >> "$run_dir/progress.jsonl"
}

is_completed() {
  local run_dir="$1" input="$2"
  grep -q "\"input\":\"${input}\".*\"status\":\"completed\"" "$run_dir/progress.jsonl" 2>/dev/null
}

get_completed_count() {
  local run_dir="$1"
  local c
  c=$(grep -c '"status":"completed"' "$run_dir/progress.jsonl" 2>/dev/null || true)
  echo "${c:-0}" | tr -d '[:space:]'
}

get_failed_count() {
  local run_dir="$1"
  local c
  c=$(grep -c '"status":"failed"' "$run_dir/progress.jsonl" 2>/dev/null || true)
  echo "${c:-0}" | tr -d '[:space:]'
}

print_summary() {
  local run_dir="$1"
  local progress_file="$run_dir/progress.jsonl"

  if [[ ! -f "$progress_file" ]] || [[ ! -s "$progress_file" ]]; then
    echo "No progress data."
    return
  fi

  local total completed failed total_cost avg_duration total_turns
  total=$(wc -l < "$run_dir/inputs.txt" 2>/dev/null || echo 0)
  completed=$(grep -c '"status":"completed"' "$progress_file" 2>/dev/null || echo 0)
  failed=$(grep -c '"status":"failed"' "$progress_file" 2>/dev/null || echo 0)

  # Use jq for aggregation
  local stats
  stats=$(jq -s '
    {
      total_cost: ([.[] | .cost_usd // 0] | add // 0),
      total_turns: ([.[] | .turns // 0] | add // 0),
      total_duration: ([.[] | .duration_s // 0] | add // 0),
      avg_duration: (
        [.[] | select(.status == "completed") | .duration_s // 0]
        | if length > 0 then (add / length | floor) else 0 end
      )
    }
  ' "$progress_file" 2>/dev/null || echo '{}')

  total_cost=$(echo "$stats" | jq -r '.total_cost // 0')
  total_turns=$(echo "$stats" | jq -r '.total_turns // 0')
  avg_duration=$(echo "$stats" | jq -r '.avg_duration // 0')
  local total_duration
  total_duration=$(echo "$stats" | jq -r '.total_duration // 0')

  # Format duration
  local runtime_fmt avg_fmt
  runtime_fmt=$(format_duration "$total_duration")
  avg_fmt=$(format_duration "$avg_duration")

  echo ""
  echo "  ============================================"
  echo "  Run Complete"
  echo "  ============================================"
  echo ""
  printf "  Completed:   %s / %s\n" "$completed" "$total"
  printf "  Failed:      %s\n" "$failed"
  printf "  Total cost:  \$%.4f\n" "$total_cost"
  printf "  Total turns: %s\n" "$total_turns"
  printf "  Runtime:     %s\n" "$runtime_fmt"
  printf "  Avg/input:   %s\n" "$avg_fmt"
  echo ""
  echo "  Results: $run_dir/"
  echo "  ============================================"
  echo ""
}

format_duration() {
  local secs="$1"
  if (( secs >= 3600 )); then
    printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
  elif (( secs >= 60 )); then
    printf "%dm %ds" $((secs/60)) $((secs%60))
  else
    printf "%ds" "$secs"
  fi
}

find_latest_run() {
  local runs_dir="$1"
  # Find most recent run directory by name (timestamp-sorted)
  ls -1d "$runs_dir"/*/  2>/dev/null | sort -r | head -1
}
