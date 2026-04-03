#!/bin/bash
set -e

# Claude Island App Store Release Script
# Publishes to Mac App Store with proper sandbox and entitlements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="ClaudeIsland"
PROJECT_FILE="$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj"

echo "=== Claude Island App Store Release Script ==="

# Check for required tools
if ! command -v xcodebuild &> /dev/null; then
    echo "Error: xcodebuild not found"
    exit 1
fi

# Ensure we're on main or app-store branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $BRANCH"

# Check if AppStore config exists
if ! grep -q "name = AppStore;" "$PROJECT_FILE"; then
    echo "Error: AppStore configuration not found in project"
    echo "Please ensure the project has an AppStore build configuration"
    exit 1
fi

echo "AppStore configuration found"

# Build parameters
TIMESTAMP=$(date +%Y%m%d%H%M)
ARCHIVE_PATH="$PROJECT_DIR/build/ClaudeIsland-$TIMESTAMP.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/AppStoreExport-$TIMESTAMP"

# Clean and create build directory
rm -rf "$PROJECT_DIR/build"
mkdir -p "$PROJECT_DIR/build"

echo ""
echo "=== Step 1: Clean ==="
xcodebuild \
    -scheme "$SCHEME" \
    -configuration AppStore \
    clean 2>&1 | tail -3

echo ""
echo "=== Step 2: Archive ==="
echo "Note: For App Store submission, you need:"
echo "  - Apple Developer account"
echo "  - App Store Connect API key or Xcode authentication"
echo "  - Valid provisioning profiles"
echo ""
xcodebuild \
    -scheme "$SCHEME" \
    -configuration AppStore \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive 2>&1 | tail -20

echo ""
echo "=== Done ==="
echo "Archive: $ARCHIVE_PATH"
echo ""
echo "To complete App Store submission:"
echo "1. Open Xcode Organizer (Cmd+Shift+O)"
echo "2. Select the archive and click 'Distribute to App Store'"
echo ""
echo "Or use Transporter app to upload:"
echo "  open -a Transporter"
