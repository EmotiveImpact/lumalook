#!/bin/sh
#
# Xcode Cloud post-clone: stamp a UNIQUE build number.
#
# Why this exists: the build number was hardcoded in project.pbxproj, so every
# push archived as the SAME CFBundleVersion. App Store Connect rejects a
# duplicate build number, so builds silently never reached TestFlight —
# 2026-07-10 through 2026-07-17 all shipped "1.0 (1)" and only the first landed.
# CI_BUILD_NUMBER is unique and monotonic per Xcode Cloud build, so stamping it
# here makes every push land, with no manual version bump ever again.
#
# Never fail the build over versioning: if anything is missing, leave the
# committed values alone and carry on.

[ -n "$CI_BUILD_NUMBER" ] || { echo "[ci] no CI_BUILD_NUMBER — leaving version as committed"; exit 0; }

PROJ="${CI_PRIMARY_REPOSITORY_PATH:-$PWD/..}/LumaLook.xcodeproj/project.pbxproj"
if [ ! -f "$PROJ" ]; then
  echo "[ci] pbxproj not found at $PROJ — leaving version as committed"
  exit 0
fi

# CFBundleVersion is generated from INFOPLIST_KEY_CFBundleVersion (it overrides
# CURRENT_PROJECT_VERSION when GENERATE_INFOPLIST_FILE=YES), so stamp both.
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/g" "$PROJ" || true
sed -i '' -E "s/INFOPLIST_KEY_CFBundleVersion = [^;]*;/INFOPLIST_KEY_CFBundleVersion = ${CI_BUILD_NUMBER};/g" "$PROJ" || true

echo "[ci] stamped build number ${CI_BUILD_NUMBER}"
grep -o "CURRENT_PROJECT_VERSION = [^;]*;" "$PROJ" | sort -u
grep -o "INFOPLIST_KEY_CFBundleVersion = [^;]*;" "$PROJ" | sort -u
grep -o "MARKETING_VERSION = [^;]*;" "$PROJ" | sort -u
exit 0
