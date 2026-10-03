#!/bin/zsh
# Builds Ugo.app straight from swiftc, without Xcode's build system.
# Usage: scripts/build.sh [debug|release] [--install] [--run]
#   --install moves the built app to ~/Applications/Ugo.app (replacing it)
#   --run     opens the app, the installed copy when --install is given
#
# One Ugo only. macOS treats every bundle path as a separate app, so a copy
# opened beside a running one shows up as a second Ugo in the Dock, and every
# bundle it has ever seen is listed in Spotlight. This script therefore quits
# any running Ugo before --install or --run, and removes and unregisters
# bundles left under build/ that nothing is running from.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
RUN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    release) CONFIG=release ;;
    debug) CONFIG=debug ;;
    --run) RUN=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Quits every running Ugo whatever bundle it came from: a normal quit through
# Apple Events first, SIGTERM for anything still alive after five seconds.
quit_ugo() {
  local i
  for i in {1..20}; do
    pgrep -xq Ugo || return 0
    osascript -e 'with timeout of 2 seconds' \
              -e 'tell application id "app.ugo" to quit' \
              -e 'end timeout' >/dev/null 2>&1 || true
    sleep 0.25
  done
  pkill -x Ugo || true
  for i in {1..20}; do
    pgrep -xq Ugo || return 0
    sleep 0.25
  done
  echo "could not quit the running Ugo" >&2
  return 1
}

# Removes a bundle under build/ that nothing is running from and tells Launch
# Services to forget it, so launchers stop listing it next to the installed copy.
forget_bundle() {
  local bundle=$1
  pgrep -qf "$PWD/$bundle/Contents/MacOS/Ugo" && return 0
  "$LSREGISTER" -u "$PWD/$bundle" >/dev/null 2>&1 || true
  rm -rf "$bundle"
}

if [ "$RUN" = 1 ] || [ "$INSTALL" = 1 ]; then
  quit_ugo
fi
forget_bundle build/debug/Ugo.app
forget_bundle build/release/Ugo.app

XCODE=/Applications/Xcode.app/Contents/Developer
CLT=/Library/Developer/CommandLineTools
if xcrun --show-sdk-path >/dev/null 2>&1; then
  SWIFTC=(xcrun swiftc)
  SDK=$(xcrun --show-sdk-path)
elif [ -x "$XCODE/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
  # Xcode is installed but its license has not been accepted: call the
  # toolchain directly, which does not go through the license check.
  SWIFTC=("$XCODE/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
  SDK="$XCODE/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
  SWIFTC=("$CLT/usr/bin/swiftc")
  SDK="$CLT/SDKs/MacOSX.sdk"
fi

APP=build/$CONFIG/Ugo.app
MACOS_MIN=15.0
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$CONFIG" = release ]; then
  OPT=(-O -whole-module-optimization)
else
  OPT=(-Onone -g)
fi

SOURCES=(${(f)"$(find Ugo -name '*.swift' | sort)"})
"${SWIFTC[@]}" "${OPT[@]}" \
  -sdk "$SDK" \
  -target "arm64-apple-macosx$MACOS_MIN" \
  -swift-version 6 \
  -parse-as-library \
  -module-name Ugo \
  -o "$APP/Contents/MacOS/Ugo" \
  "${SOURCES[@]}"

# App icon: build an .icns from the catalog PNGs so the swiftc build gets the
# same icon Xcode would compile from Assets.xcassets.
ICONSET_SRC=Ugo/Assets.xcassets/AppIcon.appiconset
if [ -f "$ICONSET_SRC/icon_512x512@2x.png" ]; then
  ICONSET=build/$CONFIG/AppIcon.iconset
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for f in icon_16x16 icon_16x16@2x icon_32x32 icon_32x32@2x icon_128x128 icon_128x128@2x \
           icon_256x256 icon_256x256@2x icon_512x512 icon_512x512@2x; do
    cp "$ICONSET_SRC/$f.png" "$ICONSET/$f.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Ugo</string>
	<key>CFBundleIdentifier</key><string>app.ugo</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Ugo</string>
	<key>CFBundleDisplayName</key><string>Ugo</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP"

if [ "$INSTALL" = 1 ]; then
  # One copy only: the build output is moved out of the repo, not copied.
  DEST="$HOME/Applications/Ugo.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
  rm -rf "$APP"
  APP="$DEST"
  echo "installed $APP"
fi

if [ "$RUN" = 1 ]; then
  open "$APP"
fi
