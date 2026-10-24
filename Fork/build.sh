#!/bin/bash
# Fork/build.sh: builds Qusai's copy of Nook from this checkout.
#
# Everything that makes this copy "ours" lives in this one file. Nook's own files
# (project.pbxproj, Info.plist) stay exactly as upstream ships them, so pulling an
# official release (git merge vX.Y.Z) never conflicts with our identity settings.
#
# Usage:  Fork/build.sh            -> Release build
#         Fork/build.sh Debug      -> Debug build
# Output: ~/dev/nook/build/DerivedData/Build/Products/<Config>/Nook.app
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"     # ~/dev/nook/source (this git checkout)
OUT="$(cd "$SRC/.." && pwd)/build"          # ~/dev/nook/build  (outside git, never committed)
CONFIG="${1:-Release}"

# --- Our identity -------------------------------------------------------------
# A different app ID gives this copy its own data folder, settings and logins, so it
# never mixes with an official Nook (com.gstudios.nook) on the same Mac.
BUNDLE_ID="com.qusai.nook"

# --- Updates (Sparkle) --------------------------------------------------------
# Point the updater at OUR feed, so the official feed can never replace this build
# with a plain official one. Our feed does not exist yet (Phase 5), so automatic
# checks stay off until it does.
FEED_URL="https://qusaiisaleem.github.io/Nook/appcast.xml"
AUTO_CHECKS="false"

# --- Signing ------------------------------------------------------------------
# Free "ad-hoc" signing (no Apple account). Uses the same reduced entitlements file
# the official DMGs ship with: push + autofill need a paid team, and official
# downloads lack them too. Must be an absolute path (see CLAUDE.md, Signing).
ENTITLEMENTS="$SRC/Nook/Nook-CI.entitlements"
# Library validation only loads frameworks (Sparkle) signed with the app's Team ID.
# Ad-hoc signatures have no Team ID, so dyld refuses Sparkle and the app dies at
# launch ("different Team IDs"). Nook's own Debug config turns this one check off
# for the same reason; every other hardened-runtime protection stays on.
LIBRARY_VALIDATION_OFF="RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION=YES"

xcodebuild \
  -project "$SRC/Nook.xcodeproj" -scheme Nook -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$OUT/DerivedData" \
  -skipMacroValidation -skipPackagePluginValidation \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "$LIBRARY_VALIDATION_OFF" \
  build

APP="$OUT/DerivedData/Build/Products/$CONFIG/Nook.app"
PLIST="$APP/Contents/Info.plist"

# Patch the finished app, not Nook/Info.plist, so the source stays upstream-identical.
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks $AUTO_CHECKS" "$PLIST"

# Editing Info.plist breaks the signature seal, so seal the app again, keeping the
# entitlements and hardened-runtime flags Xcode just signed it with.
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
echo "App ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
echo "Update feed: $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST") (automatic checks: $AUTO_CHECKS)"
