#!/bin/bash
# Genuine signed native app + OS screenshots. No login, account export or UI clone.
set -Eeuo pipefail
umask 077

fail() { printf 'Native macOS capture stopped: %s\n' "$1" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'This probe requires actual macOS; it cannot run on Windows.'
[[ "$(sw_vers -productVersion)" == 26.* ]] || fail 'Use macOS 26 for the actual current native appearance.'
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || fail 'Use a fresh GitHub-hosted macOS runner, not an existing personal desktop.'
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || fail 'RUNNER_TEMP is unavailable.'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
capture_root="$RUNNER_TEMP/native-macos-capture"
[[ ! -e "$capture_root" ]] || fail 'Capture directory already exists; refusing to overwrite a prior attempt.'
artifacts="$capture_root/artifacts"
staging="$capture_root/work"
mount_point="$capture_root/mounted"
mkdir -p "$artifacts" "$staging" "$mount_point"
mounted=false
finish() {
  capture_status=$?
  if [[ "$mounted" == true ]]; then hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true; fi
  if [[ "$capture_status" -ne 0 ]]; then
    printf 'Probe did not complete. Exit code: %s. No native-chat result is claimed.\n' "$capture_status" > "$artifacts/FAILED.txt"
  fi
}
trap finish EXIT

[[ "$(stat -f '%Su' /dev/console)" == "$(id -un)" ]] || fail 'Runner user is not the logged-in GUI console user.'
pgrep -x WindowServer >/dev/null || fail 'WindowServer is not running.'
launchctl print "gui/$(id -u)" >/dev/null 2>&1 || fail 'No Aqua GUI launchd domain.'
if pgrep -x Telegram >/dev/null; then fail 'An existing Telegram process is present; refusing to touch it.'; fi
for profile in \
  "$HOME/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram" \
  "$HOME/Library/Containers/ru.keepcoder.Telegram" \
  "$HOME/Library/Application Support/Telegram"; do
  [[ ! -e "$profile" ]] || fail 'Existing Telegram profile detected; no account data will be read or removed.'
done

sw_vers > "$artifacts/macos-version.txt"
printf 'Architecture: %s\nImageOS: %s\nImageVersion: %s\n' "$(uname -m)" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" > "$artifacts/runner-image.txt"

# Direct link is published by macos.telegram.org and redirects to osx.telegram.org.
download_url='https://telegram.org/dl/macos'
effective_url="$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 120 --retry 1 --output "$staging/Telegram.dmg" --write-out '%{url_effective}' "$download_url")"
case "$effective_url" in
  https://osx.telegram.org/updates/Telegram.dmg) ;;
  *) fail 'Official download redirect changed; review it before proceeding.' ;;
esac
printf 'Requested: %s\nFinal: %s\n' "$download_url" "$effective_url" > "$artifacts/download-source.txt"
shasum -a 256 "$staging/Telegram.dmg" | awk '{print $1 "  Telegram.dmg"}' > "$artifacts/download.sha256"
hdiutil verify "$staging/Telegram.dmg" > "$artifacts/dmg-verification.txt" 2>&1
hdiutil attach "$staging/Telegram.dmg" -mountpoint "$mount_point" -readonly -nobrowse -quiet
mounted=true
[[ -d "$mount_point/Telegram.app" ]] || fail 'Native Telegram.app was not found inside the official DMG.'
application="$staging/Telegram.app"
ditto "$mount_point/Telegram.app" "$application"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$application/Contents/Info.plist")"
[[ "$bundle_id" == ru.keepcoder.Telegram ]] || fail 'Downloaded app is not the native macOS Telegram bundle.'
codesign --verify --deep --strict --verbose=2 "$application" > "$artifacts/signature-verification.txt" 2>&1
codesign --display --verbose=4 "$application" > "$artifacts/signature-details.txt" 2>&1
grep -q '^TeamIdentifier=6N38VWS5BX$' "$artifacts/signature-details.txt" || fail 'Native Telegram signing team differs from the expected official team.'
spctl --assess --type execute --verbose=4 "$application" > "$artifacts/gatekeeper-assessment.txt" 2>&1
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$application/Contents/Info.plist" > "$artifacts/telegram-version.txt"

# This is an inspector/activator, not a custom application or renderer.
xcrun swiftc -framework AppKit -framework CoreGraphics "$script_dir/window_probe.swift" -o "$staging/window_probe"
# Request real system dark appearance; this is not a visual replacement layer.
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' > "$artifacts/appearance-request.txt" 2>&1 || printf 'Dark appearance request was not accepted; inspect actual captured appearance.\n' >> "$artifacts/appearance-request.txt"
open -n -a "$application"
window_found=false
for attempt in {1..30}; do
  "$staging/window_probe" "$application" activate > "$staging/window-probe.json" 2> "$artifacts/window-probe-stderr.txt" || true
  if "$staging/window_probe" "$application" inspect > "$artifacts/window-probe.json" 2>> "$artifacts/window-probe-stderr.txt"; then
    if python3 - "$artifacts/window-probe.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d['frontmost_bundle_identifier']=='ru.keepcoder.Telegram' else 1)
PY
    then window_found=true; break; fi
  fi
  sleep 1
done
[[ "$window_found" == true ]] || fail 'The actual Telegram window did not become visible/frontmost; inspect diagnostics.'
sleep 3
window_id="$(python3 - "$artifacts/window-probe.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['window_id'])
PY
)"

# Raw OS capture only: no HTML, replacement text, compositing or enlargement.
/usr/sbin/screencapture -x -m "$artifacts/native-desktop.png" 2> "$artifacts/screencapture-stderr.txt"
/usr/sbin/screencapture -x -o -l "$window_id" "$artifacts/native-telegram-window.png" 2>> "$artifacts/screencapture-stderr.txt"
for image in "$artifacts/native-desktop.png" "$artifacts/native-telegram-window.png"; do
  [[ -s "$image" ]] || fail 'OS screenshot is empty or was denied by privacy permissions.'
  sips -g pixelWidth -g pixelHeight "$image" >> "$artifacts/screenshot-dimensions.txt"
done
python3 - "$artifacts" <<'PY'
from pathlib import Path
import hashlib,json,struct,sys
p=Path(sys.argv[1]); images=[]
for name in ('native-desktop.png','native-telegram-window.png'):
    bits=(p/name).read_bytes()
    assert bits[:8]==b'\x89PNG\r\n\x1a\n' and bits[12:16]==b'IHDR','Invalid OS PNG'
    w,h=struct.unpack('>II',bits[16:24]);assert w>=200 and h>=160,'Unexpected screenshot size'
    images.append({'file':name,'sha256':hashlib.sha256(bits).hexdigest(),'dimensions':[w,h],'pixel_edits':False})
report={'capture_completed':True,'native_macos_application':True,'native_bundle_identifier':'ru.keepcoder.Telegram',
        'scope':'Unauthenticated genuine app/desktop probe; welcome/login screen only. Not evidence of an authenticated bot chat.',
        'telegram_login_attempted':False,'telegram_messages_sent':0,'ui_reconstruction':False,'image_compositing':False,
        'visual_review_required':True,'screenshots':images}
(p/'capture-metadata.json').write_text(json.dumps(report,indent=2)+'\n')
(p/'screenshots.sha256').write_text(''.join(f"{x['sha256']}  {x['file']}\n" for x in images))
PY
printf 'Genuine app capture files prepared; welcome/login only. Inspect images before accepting the result.\n'
