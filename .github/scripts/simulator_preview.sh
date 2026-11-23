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
# While one screen is being worked on, a file at .github/preview-only holding
# the start of its shots' names (for example 11 for the camera) limits the run
# to those shots and skips the recording. Delete the file for the full preview.
ONLY=""
if [ -f "$ROOT/.github/preview-only" ]; then
  ONLY=$(tr -d '[:space:]' < "$ROOT/.github/preview-only")
  [ -n "$ONLY" ] && echo "Only the shots starting with: $ONLY"
fi
# shot <name> <seconds> [SIMCTL_CHILD_...=value ...]
shot() {
  local name=$1
  if [ -n "$ONLY" ] && [[ "$name" != "$ONLY"* ]]; then
    return
  fi
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

# The launch animation held at a mid-way frame (LaunchView.swift). Every
# other screen sets a LUMA_ hook, which skips the launch layer.
shot 00-launch 5 "${P}ROUTE=launch"
# Any LUMA_ROUTE value skips onboarding, so "none" gives the plain tab.
shot 01-onboarding 7 "${P}SEED_ONBOARDING=1"
shot 02-home 10 "${P}ROUTE=none" "${P}TAB=Home" "${P}SEED_REELHOLD=1"
shot 02b-home-first-run 10 "${P}ROUTE=none" "${P}TAB=Home" "${P}SEED_HOMEEMPTY=1" "${P}SEED_REELHOLD=1"
shot 02c-home-picked 10 "${P}ROUTE=none" "${P}TAB=Home" "${P}SEED_HOMEPICK=BW32"
shot 03-store 6 "${P}ROUTE=none" "${P}TAB=Store"
shot 04-projects 5 "${P}ROUTE=none" "${P}TAB=Projects"
shot 05-looks 9 "${P}ROUTE=none" "${P}TAB=Looks"
shot 05b-looks-packs 6 "${P}ROUTE=none" "${P}TAB=Looks" "${P}SEED_LOOKSHELF=packs"
shot 06-profile 5 "${P}ROUTE=none" "${P}TAB=Profile"
# The bar once Pro is bought: the yellow Get Pro becomes a quiet Pro badge.
shot 05c-looks-pro 9 "${P}ROUTE=none" "${P}TAB=Looks" "${P}SEED_PRO=1"
# Mine, where New look and Import a LUT live now the top row holds only Pro and You.
shot 05d-looks-mine 6 "${P}ROUTE=none" "${P}TAB=Looks" "${P}SEED_LOOKSHELF=mine"
shot 06b-profile-pro 5 "${P}ROUTE=none" "${P}TAB=Profile" "${P}SEED_PRO=1"
shot 07-select-clip 5 "${P}ROUTE=selectClip"
shot 08-grade-room 9 "${P}ROUTE=applyLook" "${P}SEED_AUTOGRADE=$MEDIA/hero_golden.jpg"
shot 09-before-after 9 "${P}ROUTE=beforeAfter" "${P}SEED_AUTOGRADE=$MEDIA/hero_campaign.jpg"
shot 10-editor 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1"
shot 10b-editor-clip 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_EDITOR_STATE=clip"
shot 10c-editor-look 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_EDITOR_STATE=look"
shot 10d-editor-more 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_EDITOR_STATE=more"
shot 10e-editor-captions 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_EDITOR_STATE=captions"
shot 10f-editor-speed 10 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_RAMP=hero" "${P}SEED_TOOLPANEL=speed"
shot 10g-editor-transition 14 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_TOOLPANEL=transition"
shot 10h-editor-music 14 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" "${P}SEED_TOOLPANEL=audioAdd"
# A music lane selected: its panel (Cut to the beat hidden while the flag is off).
shot 10i-editor-music-lane 14 "${P}ROUTE=editor" "${P}SEED_EDITOR_DEMO=1" \
  "${P}SEED_MUSIC=$ROOT/LumaLook/Resources/AudioLibrary/pad_warm.m4a" "${P}SEED_AUDIOPANEL=music"
shot 11-camera 10 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_campaign.jpg"
shot 11b-camera-photo 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" "${P}SEED_CAMMODE=photo" "${P}SEED_CAMROLL=24" "${P}SEED_CAMFOCUS=1"
# Camera A: pull-up Pro, the looks sheet, the thumb fan, sideways, the ask at
# record for a paid look tried on free, and the swipe between favourites.
shot 11c-camera-pro 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_campaign.jpg" "${P}SEED_CAMPRO=lens"
shot 11d-camera-looks 14 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_campaign.jpg" "${P}SEED_BROWSER=1"
shot 11e-camera-fan 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_neon.jpg" "${P}SEED_CAMFAN=1"
shot 11f-camera-landscape 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_neon.jpg" "${P}SEED_CAMLAND=ccw" "${P}SEED_CAMLOOK=pack:after-dark:AD2"
shot 11g-camera-locked 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" "${P}SEED_CAMLOOK=pack:film-neg-archive:FN400" "${P}SEED_CAMLOCK=1"
shot 11h-camera-swipe 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" "${P}SEED_CAMSWIPE=1"
shot 11i-camera-hint 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_campaign.jpg" "${P}SEED_CAMHINT=1"
shot 11j-camera-locked-land 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_neon.jpg" "${P}SEED_CAMLAND=ccw" "${P}SEED_CAMLOOK=pack:film-neg-archive:FN400" "${P}SEED_CAMLOCK=1"
shot 11k-camera-format 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_campaign.jpg" "${P}SEED_CAMFORMAT=1"
shot 11l-camera-format-land 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_neon.jpg" "${P}SEED_CAMLAND=ccw" "${P}SEED_CAMMODE=portrait" "${P}SEED_CAMROLL=24" "${P}SEED_CAMFORMAT=1"
shot 12-filter-pack 10 "${P}ROUTE=filterPack" "${P}SEED_PACK=after-dark"
# A film archive, now sold on its own as well as with Pro.
shot 12b-archive-pack 8 "${P}ROUTE=filterPack" "${P}SEED_PACK=film-neg-archive"
shot 13-lut-manager 5 "${P}ROUTE=lutManager"
shot 14-settings 5 "${P}ROUTE=settings"
shot 15-paywall 6 "${P}ROUTE=settings" "${P}SEED_PAYWALL=1"
# The export lock with its three ways on, one of them free.
# The photo loads without the auto grade, so the sheet never waits behind it.
shot 16-locked-look 12 "${P}ROUTE=beforeAfter" "${P}SEED_STILL=$MEDIA/hero_party.jpg" \
  "${P}SEED_LOCK=Night Drive"
# A UK buyer before StoreKit answers: no US dollar fallback anywhere, the
# price rows hold a placeholder and the buy buttons drop the amount.
shot 15b-paywall-uk 6 "${P}ROUTE=settings" "${P}SEED_PAYWALL=1" "${P}SEED_STOREFRONT=GBR"
shot 12c-archive-pack-uk 8 "${P}ROUTE=filterPack" "${P}SEED_PACK=film-neg-archive" "${P}SEED_STOREFRONT=GBR"
shot 11m-camera-locked-uk 8 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" \
  "${P}SEED_CAMLOOK=pack:film-neg-archive:FN400" "${P}SEED_CAMLOCK=1" "${P}SEED_STOREFRONT=GBR"

# Home again, last, so no first-boot system banner covers it: the reel held
# on Neon Nights, the same woman as the editor shots (the website uses it).
shot 02d-home-neon 10 "${P}ROUTE=none" "${P}TAB=Home" "${P}SEED_REELHOLD=Neon"
# Home scrolled to the template rail: the top row has become the top bar.
shot 02e-home-scrolled 10 "${P}ROUTE=none" "${P}TAB=Home" "${P}SEED_REELHOLD=1" "${P}SEED_HOMESCROLL=1"
# Seeds five photo projects that stay in the app data, so it runs after
# every other shot that would otherwise show them.
shot 04b-projects-full 10 "${P}ROUTE=none" "${P}TAB=Projects" "${P}SEED_PROJECTS=1"

# A short recording of the app moving: onboarding, the tabs, the grade
# room, the editor playing, and the camera.
if [ -z "$ONLY" ]; then
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/lumalook-preview.mp4" \
  > "$OUT/logs/recording.log" 2>&1 &
RECORDER=$!
sleep 3
launch video-launch 4 "${P}ROUTE=launchLive" || true
launch video-onboarding 8 "${P}SEED_ONBOARDING=1" || true
launch video-home 5 "${P}ROUTE=none" "${P}TAB=Home" || true
launch video-looks 4 "${P}ROUTE=none" "${P}TAB=Looks" || true
launch video-grade 7 "${P}ROUTE=applyLook" "${P}SEED_AUTOGRADE=$MEDIA/hero_party.jpg" || true
launch video-editor 9 "${P}ROUTE=editor" "${P}SEED_PHOTO=$MEDIA/hero_rain.jpg" "${P}SEED_PLAY=1" || true
launch video-camera 6 "${P}ROUTE=camera" "${P}SEED_CAMFRAME=$MEDIA/hero_golden.jpg" || true
kill -INT "$RECORDER" 2>/dev/null
wait "$RECORDER" 2>/dev/null || true
fi

# The app's own log lines for the picked Home and the camera.
for f in "$OUT/logs/02c-home-picked.out.log" "$OUT/logs/02e-home-scrolled.out.log" "$OUT/logs/11-camera.out.log" "$OUT/logs/11h-camera-swipe.out.log" "$OUT/logs/16-locked-look.out.log"; do
  [ -f "$f" ] && { echo "== $(basename "$f")"; grep -a '\[LUMA\]' "$f" | tail -20; }
done

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
