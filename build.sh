#!/usr/bin/env bash
set -euo pipefail

APP="Flight.app"
BINARY_NAME="Flight"
DIST_DIR="dist"

APP_VERSION="${FLIGHT_VERSION:-1.0.0}"
BUILD_NUMBER="${FLIGHT_BUILD_NUMBER:-$APP_VERSION}"
BUNDLE_ID="${FLIGHT_BUNDLE_ID:-ai.miragesecurity.flight}"
MINIMUM_SYSTEM_VERSION="${FLIGHT_MINIMUM_SYSTEM_VERSION:-15.0}"

SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

DO_KILL=0
DO_OPEN=0
DO_ARCHIVE=0
DO_SIGN=0
for arg in "$@"; do
    case "$arg" in
        kill) DO_KILL=1 ;;
        open) DO_OPEN=1 ;;
        archive) DO_ARCHIVE=1 ;;
        sign) DO_SIGN=1 ;;
        *) echo "Unknown arg: $arg (expected: kill, open, archive, sign)" >&2; exit 1 ;;
    esac
done

if [ "$DO_KILL" = 1 ]; then
    echo "Killing running $BINARY_NAME instances..."
    pkill -x "$BINARY_NAME" 2>/dev/null || true
fi

echo "Building release binary..."
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

echo "Packaging $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

cp "$BUILD_DIR/$BINARY_NAME" "$APP/Contents/MacOS/$BINARY_NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
    /usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true
fi

INFO_PLIST="$APP/Contents/Info.plist"

cat > "$INFO_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Flight</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Flight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_SYSTEM_VERSION</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

if [ -n "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool true" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$INFO_PLIST"
else
    echo "Sparkle updates disabled for this build; set SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY to enable them."
fi

if [ "$DO_SIGN" = 1 ] || [ -n "${FLIGHT_CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="${FLIGHT_CODESIGN_IDENTITY:?Set FLIGHT_CODESIGN_IDENTITY or omit the sign argument.}"
    echo "Signing $APP with $SIGNING_IDENTITY..."
    codesign --force --deep --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
fi

echo "Done: $APP"

if [ "$DO_ARCHIVE" = 1 ]; then
    mkdir -p "$DIST_DIR"
    ARCHIVE_PATH="$DIST_DIR/Flight-$APP_VERSION.zip"
    rm -f "$ARCHIVE_PATH"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE_PATH"
    echo "Archived: $ARCHIVE_PATH"
fi

if [ "$DO_OPEN" = 1 ]; then
    echo "Opening $APP..."
    open "$APP"
else
    echo "Run with: open $APP"
fi
