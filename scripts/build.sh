#!/bin/bash
# Build VibeHub for release
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/VibeHub.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "=== Building VibeHub ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

# Build and archive
echo "Archiving..."
xcodebuild archive \
    -scheme VibeHub \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    | xcpretty || xcodebuild archive \
    -scheme VibeHub \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic

# Create ExportOptions.plist if it doesn't exist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

# Optional overrides
# - CLAUDE_ISLAND_TEAM_ID: Apple Developer Team ID
# - CLAUDE_ISLAND_SIGNING_CERTIFICATE: e.g. "Developer ID Application" or "Apple Distribution"
if [ -n "${CLAUDE_ISLAND_TEAM_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string ${CLAUDE_ISLAND_TEAM_ID}" "$EXPORT_OPTIONS" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c "Set :teamID ${CLAUDE_ISLAND_TEAM_ID}" "$EXPORT_OPTIONS"
fi

if [ -n "${CLAUDE_ISLAND_SIGNING_CERTIFICATE:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :signingCertificate string ${CLAUDE_ISLAND_SIGNING_CERTIFICATE}" "$EXPORT_OPTIONS" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c "Set :signingCertificate ${CLAUDE_ISLAND_SIGNING_CERTIFICATE}" "$EXPORT_OPTIONS"
fi

# Export the archive
echo ""
echo "Exporting..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | xcpretty || xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/VibeHub.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
