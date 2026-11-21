#!/bin/bash
# Show the app working without a Mac or an iPhone to hand.
#
# Run by .github/workflows/preview.yml on a GitHub macOS runner. Boots an
# iPhone simulator, installs the Debug build, opens each main screen through
# the app's DEBUG launch hooks (LUMA_TAB and LUMA_ROUTE in
# AppModel.applyDebugRoute, plus the LUMA_SEED_* media seeds), screenshots
# each one, and records a short screen recording of the app in use.
#
# Usage: simulator_preview.sh <path to LumaLook.app> <output folder>
set -uo pipefail

APP=$1
OUT=$2
BUNDLE_ID=${BUNDLE_ID:-com.emotiveimpact.lumalook}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MEDIA="$ROOT/LumaLook/Resources/HeroPhotos"
P=SIMCTL_CHILD_LUMA_
mkdir -p "$OUT/screens" "$OUT/logs"

# The newest iOS runtime, on a current Pro-sized iPhone where one exists.
pick=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    found = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(found.group(1)), int(found.group(2))) if found else (0, 0)
preferred = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]
for runtime in sorted(devices, key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if "iOS" not in runtime or not phones:
        continue
    phones.sort(key=lambda d: preferred.index(d["name"]) if d["name"] in preferred else 99)
    print(phones[0]["udid"], phones[0]["name"], runtime.rsplit(".", 1)[-1], sep="\t")
    break
')
if [ -z "$pick" ]; then
  echo "::error::No iPhone simulator is available on this runner."
  exit 1
fi
IFS=$'\t' read -r UDID DEVICE RUNTIME <<< "$pick"
echo "Simulator: $DEVICE ($RUNTIME) $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"
# Camera, microphone and Photos, so no permission sheet covers a screen.
xcrun simctl privacy "$UDID" grant all "$BUNDLE_ID" || true
xcrun simctl addmedia "$UDID" "$MEDIA"/*.jpg || true
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" hasSeenOnboarding -bool YES || true

# 0 when launchd lists LumaLook, 1 when it positively doesn't (a crash), and
# 2 when the process list couldn't be read, so the screen is unverified.
running() {
  local list
  list=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null) || return 2
  [ -z "$list" ] && return 2
  grep -q "UIKitApplication:$BUNDLE_ID" <<< "$list"
}

# launch <name> <seconds> [SIMCTL_CHILD_...=value ...]
launch() {
  local name=$1 wait=$2
  shift 2
  env "$@" xcrun simctl launch --terminate-running-process \
    --stdout="$OUT/logs/$name.out.log" --stderr="$OUT/logs/$name.err.log" \
    "$UDID" "$BUNDLE_ID" > /dev/null || return 1
  sleep "$wait"
}

FAILED=""
UNVERIFIED=""
CAPTURED=0
# shot <name> <seconds> [SIMCTL_CHILD_...=value ...]
shot() {
  local name=$1
  if ! launch "$@"; then
    echo "::warning::LumaLook would not launch for the $name screen."
    FAILED="$FAILED $name"
    return
  fi
  running
  case $? in
    1)
      echo "::warning::LumaLook had stopped by the time the $name screen was captured, so it probably crashed. See logs/$name.err.log."
      FAILED="$FAILED $name"
      ;;
    2)
      echo "Could not read the simulator's process list for $name; check its screenshot."
      UNVERIFIED="$UNVERIFIED $name"
      ;;
  esac
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/screens/$name.png" > /dev/null 2>&1 \
    && CAPTURED=$((CAPTURED + 1))
  echo "Captured $name"
}

# A freshly booted simulator is busy for a while; the first launch is slow.
launch warmup 12 "${P}ROUTE=none" || true

# Any LUMA_ROUTE value skips onboarding, so "none" gives the plain tab.
shot 01-onboarding 7 "${P}SEED_ONBOARDING=1"
shot 02-home 6 "${P}ROUTE=none" "${P}TAB=Home"
shot 03-store 6 "${P}ROUTE=none" "${P}TAB=Store"
shot 04-projects 5 "${P}ROUTE=none" "${P}TAB=Projects"
shot 05-looks 6 "${P}ROUTE=none" "${P}TAB=Looks"
shot 06-profile 5 "${P}ROUTE=none" "${P}TAB=Profile"
shot 07-select-clip 5 "${P}ROUTE=selectClip"
shot 08-grade-room 9 "${P}ROUTE=applyLook" "${P}SEED_AUTOGRADE=$MEDIA/hero_golden.jpg"
shot 09-before-after 9 "${P}ROUTE=beforeAfter" "${P}SEED_AUTOGRADE=$MEDIA/hero_campaign.jpg"
shot 10-editor 10 "${P}ROUTE=editor" "${P}SEED_PHOTO=$MEDIA/hero_drive.jpg"
shot 11-camera 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_neon.jpg"
shot 12-filter-pack 6 "${P}ROUTE=filterPack" "${P}SEED_PACK=film-neg-archive"
shot 13-lut-manager 5 "${P}ROUTE=lutManager"
shot 14-settings 5 "${P}ROUTE=settings"
shot 15-paywall 6 "${P}ROUTE=settings" "${P}SEED_PAYWALL=1"
# The export lock with its three ways on, one of them free.
shot 16-locked-look 10 "${P}ROUTE=beforeAfter" "${P}SEED_AUTOGRADE=$MEDIA/hero_party.jpg" \
  "${P}SEED_LOCK=Night Drive"

# A short recording of the app moving: onboarding, the tabs, the grade
# room, the editor playing, and the camera.
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/lumalook-preview.mp4" \
  > "$OUT/logs/recording.log" 2>&1 &
RECORDER=$!
sleep 3
launch video-onboarding 8 "${P}SEED_ONBOARDING=1" || true
launch video-home 5 "${P}ROUTE=none" "${P}TAB=Home" || true
launch video-looks 4 "${P}ROUTE=none" "${P}TAB=Looks" || true
launch video-grade 7 "${P}ROUTE=applyLook" "${P}SEED_AUTOGRADE=$MEDIA/hero_party.jpg" || true
launch video-editor 9 "${P}ROUTE=editor" "${P}SEED_PHOTO=$MEDIA/hero_rain.jpg" "${P}SEED_PLAY=1" || true
launch video-camera 6 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" || true
kill -INT "$RECORDER" 2>/dev/null
wait "$RECORDER" 2>/dev/null || true

# Crash reports, if any screen took the app down.
cp ~/Library/Logs/DiagnosticReports/LumaLook* "$OUT/logs/" 2>/dev/null || true

{
  echo "Simulator: $DEVICE ($RUNTIME)"
  echo "Screens captured: $CAPTURED"
  if [ -n "$FAILED" ]; then echo "Screens with problems:$FAILED"; fi
  if [ -n "$UNVERIFIED" ]; then echo "Screens not checked for a crash:$UNVERIFIED"; fi
} | tee "$OUT/summary.txt"

if [ "$CAPTURED" -eq 0 ]; then
  echo "::error::No screen could be captured."
  exit 1
fi
