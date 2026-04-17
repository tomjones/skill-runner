#!/usr/bin/env bash
# Logging helpers — writes to both stderr (with color) and log file (plain)

_CLR_RED='\033[0;31m'
_CLR_GREEN='\033[0;32m'
_CLR_YELLOW='\033[0;33m'
_CLR_CYAN='\033[0;36m'
_CLR_DIM='\033[2m'
_CLR_RESET='\033[0m'

LOG_FILE=""

_log() {
  local level="$1" color="$2" msg="$3"
  local ts
  ts=$(date '+%H:%M:%S')
  printf "${color}[%s] [%-7s] %s${_CLR_RESET}\n" "$ts" "$level" "$msg" >&2
  [[ -n "$LOG_FILE" ]] && printf "[%s] [%-7s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE"
}

log_info()    { _log "INFO"    "$_CLR_CYAN"   "$1"; }
log_success() { _log "SUCCESS" "$_CLR_GREEN"  "$1"; }
log_error()   { _log "ERROR"   "$_CLR_RED"    "$1"; }
log_warn()    { _log "WARN"    "$_CLR_YELLOW" "$1"; }
log_dim()     { _log "INFO"    "$_CLR_DIM"    "$1"; }
