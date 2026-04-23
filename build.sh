#!/bin/bash
set -e

APP="Flight.app"
BINARY_NAME="Flight"

DO_KILL=0
DO_OPEN=0
for arg in "$@"; do
    case "$arg" in
        kill) DO_KILL=1 ;;
        open) DO_OPEN=1 ;;
        *) echo "Unknown arg: $arg (expected: kill, open)" >&2; exit 1 ;;
    esac
done

if [ "$DO_KILL" = 1 ]; then
    echo "Killing running $BINARY_NAME instances..."
    pkill -x "$BINARY_NAME" 2>/dev/null || true
fi

echo "Building release binary..."
swift build -c release

echo "Packaging $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/$BINARY_NAME "$APP/Contents/MacOS/$BINARY_NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Flight</string>
    <key>CFBundleIdentifier</key>
    <string>com.flight.app</string>
    <key>CFBundleName</key>
    <string>Flight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

echo "Done: $APP"

if [ "$DO_OPEN" = 1 ]; then
    echo "Opening $APP..."
    open "$APP"
else
    echo "Run with: open $APP"
fi
