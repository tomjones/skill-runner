#!/usr/bin/env bash
# Mario sound effects — plays via powershell.exe from WSL2

SOUNDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sounds"
SOUNDS_ENABLED="${SOUNDS_ENABLED:-false}"

play_sound() {
  local file="$SOUNDS_DIR/$1"
  if [[ "$SOUNDS_ENABLED" == true ]] && [[ -f "$file" ]]; then
    local win_path
    win_path=$(wslpath -w "$file" 2>/dev/null)
    if [[ -n "$win_path" ]]; then
      # Run PlaySync in a background subshell. Close stdin (<&-) so it
      # doesn't steal the file descriptor from the while-read loop.
      (powershell.exe -c "(New-Object Media.SoundPlayer '$win_path').PlaySync()" </dev/null &>/dev/null) &
      disown 2>/dev/null
    fi
  fi
}

sound_run_started()    { play_sound "smb_powerup.wav"; }
sound_task_starting()  { play_sound "smb_pipe.wav"; }
sound_task_completed() { play_sound "smb_coin.wav"; }
sound_task_failed()    { play_sound "smb_gameover.wav"; }
sound_batch_complete() { play_sound "smb_1-up.wav"; }
sound_interrupted()    { play_sound "smb_mariodie.wav"; }
