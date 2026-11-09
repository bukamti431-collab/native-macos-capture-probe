#!/bin/bash
# Source this optional helper in the same bash step as the native client.
# It never captures pixels, opens a chat, changes TCC, or modifies existing modes.

NATIVE_DISPLAY_STATUS=existing_native_display
NATIVE_DISPLAY_ID=
NATIVE_DISPLAY_HELPER_PID=
NATIVE_DISPLAY_OWNER_PID=$$

native_display_cleanup() {
  local owned_pid="${NATIVE_DISPLAY_HELPER_PID:-}" parent_pid attempt
  NATIVE_DISPLAY_HELPER_PID=
  [[ "$owned_pid" =~ ^[0-9]+$ ]] || return 0
  # Only the direct child created by this shell can be signalled. No broad kill.
  parent_pid="$(/bin/ps -o ppid= -p "$owned_pid" 2>/dev/null)" || parent_pid=
  parent_pid="${parent_pid//[[:space:]]/}"
  if [[ "$parent_pid" == "$NATIVE_DISPLAY_OWNER_PID" ]]; then
    kill -TERM "$owned_pid" 2>/dev/null || true
    for attempt in {1..25}; do
      kill -0 "$owned_pid" 2>/dev/null || break
      /bin/sleep 0.2
    done
    parent_pid="$(/bin/ps -o ppid= -p "$owned_pid" 2>/dev/null)" || parent_pid=
    parent_pid="${parent_pid//[[:space:]]/}"
    if [[ "$parent_pid" == "$NATIVE_DISPLAY_OWNER_PID" ]]; then kill -KILL "$owned_pid" 2>/dev/null || true; fi
    wait "$owned_pid" 2>/dev/null || true
  elif kill -0 "$owned_pid" 2>/dev/null; then
    # Never wait on an unverified PID (or signal an unrelated/reused process).
    printf '%s\n' 'NATIVE_DISPLAY_CLEANUP_OWNERSHIP_UNVERIFIED'
  fi
}

native_display_prepare() {
  local app_path="${1:-}" work_path="${2:-}" source_path attempt display_id
  source_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 0
  if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
    printf '%s\n' 'NATIVE_DISPLAY_FALLBACK_UNSUPPORTED_OS'; return 0
  fi
  if [[ "$app_path" != /*.app || "$work_path" != /* || "$work_path" == *$'\n'* || "$app_path" == *$'\n'* ]]; then
    printf '%s\n' 'NATIVE_DISPLAY_FALLBACK_INVALID_ARGUMENTS'; return 0
  fi
  if ! /bin/mkdir -p -- "$work_path"; then
    printf '%s\n' 'NATIVE_DISPLAY_FALLBACK_WORK_DIRECTORY'; return 0
  fi
  # An offline local compile against the runner's SDK; no packages/downloads.
  if ! /usr/bin/xcrun clang -fobjc-arc -fblocks -Wall -Wextra \
      -framework AppKit -framework CoreGraphics -framework Foundation \
      "$source_path/virtual-display.m" -o "$work_path/virtual-display" \
      >"$work_path/compile-display.log" 2>&1 || \
     ! /usr/bin/xcrun clang -fobjc-arc -fblocks -Wall -Wextra \
      -framework AppKit -framework ApplicationServices -framework CoreGraphics \
      "$source_path/native-display.m" -o "$work_path/native-display" \
      >"$work_path/compile-native.log" 2>&1; then
    printf '%s\n' 'NATIVE_DISPLAY_FALLBACK_COMPILE_UNVERIFIED'; return 0
  fi
  "$work_path/native-display" probe >"$work_path/display-before.json" || true
  "$work_path/virtual-display" create >"$work_path/display-created.json" 2>"$work_path/display-helper.log" &
  NATIVE_DISPLAY_HELPER_PID=$!
  display_id=
  for attempt in {1..10}; do
    if display_id="$(python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); assert x.get("status")=="created_unverified"; n=x["display_id"]; assert type(n) is int and 0<n<=0xffffffff; print(n)' "$work_path/display-created.json" 2>/dev/null)"; then break; fi
    kill -0 "$NATIVE_DISPLAY_HELPER_PID" 2>/dev/null || break
    /bin/sleep 0.5
  done
  if [[ "$display_id" =~ ^[0-9]+$ ]]; then
    for attempt in {1..10}; do
      # Always a new observer process: do not trust the creator's cached modes.
      if "$work_path/native-display" probe >"$work_path/display-after.json" && \
         python3 "$source_path/verify_mode.py" "$work_path/display-after.json" "$display_id" >"$work_path/display-verified.json"; then
        NATIVE_DISPLAY_ID="$display_id"
        NATIVE_DISPLAY_STATUS=verified_native_hidpi
        break
      fi
      /bin/sleep 0.5
    done
  fi
  if [[ "$NATIVE_DISPLAY_STATUS" != verified_native_hidpi ]]; then
    native_display_cleanup
    printf '%s\n' 'NATIVE_DISPLAY_FALLBACK_ACTUAL_MODE_NOT_VERIFIED'; return 0
  fi
  # Explicit bootstrap placement only. Largest is not a private chat selector.
  if "$work_path/native-display" place-telegram "$app_path" "$NATIVE_DISPLAY_ID" --largest >"$work_path/display-placement.json"; then
    printf '%s\n' 'NATIVE_DISPLAY_VERIFIED_3840X2160_1920X1080_2X_TELEGRAM_PLACED'
  else
    NATIVE_DISPLAY_STATUS=verified_native_hidpi_placement_unverified
    printf '%s\n' 'NATIVE_DISPLAY_VERIFIED_HIDPI_TELEGRAM_PLACEMENT_UNVERIFIED'
  fi
  export NATIVE_DISPLAY_STATUS NATIVE_DISPLAY_ID
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'Source prepare-display.sh APP_PATH ABSOLUTE_WORK_DIRECTORY in the client shell; do not execute it.'
  exit 64
fi
native_display_prepare "$@"
