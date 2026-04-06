#!/bin/bash
# Full release pipeline: build → notarize → DMG → Sparkle → GitHub Release → update appcast
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/VibeHub.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"
SITE_DIR="$PROJECT_DIR/releases"

APP_NAME="VibeHub"
GITHUB_REPO="mtunique/VibeHub"
KEYCHAIN_PROFILE="VibeHub"

# ============================================
# Step 1: Build & Archive
# ============================================
echo "=== Step 1: Building ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

xcodebuild archive \
    -scheme VibeHub \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates

echo ""

# ============================================
# Step 2: Export (Developer ID)
# ============================================
echo "=== Step 2: Exporting ==="

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>894KCRH96Q</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

APP_PATH="$EXPORT_PATH/$APP_NAME.app"

if xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates 2>&1 | tail -5; then
    echo "Export succeeded."
else
    echo "Export failed, using archived app as fallback."
    APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

# Get version
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
echo ""
echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 3: Notarize the app
# ============================================
echo "=== Step 3: Notarizing app ==="

SKIP_NOTARIZATION=""
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"894KCRH96Q\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    read -p "Skip notarization? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZATION=true
    echo "WARNING: Skipping notarization."
else
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$APP_PATH"
    rm "$ZIP_PATH"
    echo "App notarized!"
fi

echo ""

# ============================================
# Step 4: Create DMG
# ============================================
echo "=== Step 4: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

if command -v create-dmg &> /dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "$APP_NAME.app" \
        "$DMG_PATH" \
        "$APP_PATH"
else
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$APP_PATH" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo "DMG created: $DMG_PATH"
echo ""

# ============================================
# Step 5: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 5: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 6: Sign for Sparkle
# ============================================
echo "=== Step 6: Sparkle signing ==="

SPARKLE_SIGN=""
for path in "$HOME/Library/Developer/Xcode/DerivedData/VibeHub-"*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    if [ -x "$path/sign_update" ]; then
        SPARKLE_SIGN="$path/sign_update"
        GENERATE_APPCAST="$path/generate_appcast"
        break
    fi
done

SPARKLE_SIGNATURE=""
if [ -z "$SPARKLE_SIGN" ]; then
    echo "WARNING: Sparkle tools not found. Build in Xcode first."
elif [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "WARNING: No Sparkle private key. Run ./scripts/generate-keys.sh"
else
    SPARKLE_SIGNATURE=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")
    echo "$SPARKLE_SIGNATURE"
fi

echo ""

# ============================================
# Step 7: GitHub Release
# ============================================
echo "=== Step 7: GitHub Release ==="

GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"

if ! command -v gh &> /dev/null; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
else
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        echo "Release v$VERSION exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" \
            --repo "$GITHUB_REPO" \
            --title "$APP_NAME v$VERSION" \
            --notes "## $APP_NAME v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag $APP_NAME to Applications
3. Launch $APP_NAME from Applications

### Auto-updates
$APP_NAME will automatically check for updates after installation."
    fi
    echo "Release: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi

echo ""

# ============================================
# Step 8: Update appcast in releases
# ============================================
echo "=== Step 8: Updating appcast ==="

if [ -z "$SPARKLE_SIGNATURE" ]; then
    echo "No Sparkle signature — skipping appcast update."
else
    # Parse signature components
    ED_SIG=$(echo "$SPARKLE_SIGNATURE" | grep -o 'edSignature="[^"]*"' | cut -d'"' -f2)
    DMG_LENGTH=$(echo "$SPARKLE_SIGNATURE" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
    PUB_DATE=$(date -R)

    if [ ! -d "$SITE_DIR" ]; then
        echo "WARNING: releases dir not found at $SITE_DIR, creating..."
        mkdir -p "$SITE_DIR"
    else
        APPCAST="$SITE_DIR/appcast.xml"

        # If appcast exists, insert new item after <channel> (before first <item>)
        if [ -f "$APPCAST" ]; then
            # Build new item XML
            NEW_ITEM="        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
            <enclosure url=\"$GITHUB_DOWNLOAD_URL\" length=\"$DMG_LENGTH\" type=\"application/octet-stream\" sparkle:edSignature=\"$ED_SIG\"/>
        </item>"

            # Insert after <channel> line, before first <item>
            sed -i '' "/<channel>/a\\
\\
$NEW_ITEM" "$APPCAST"

            # Update title
            sed -i '' 's|<title>.*</title>|<title>VibeHub</title>|' "$APPCAST"
        else
            # Create fresh appcast
            cat > "$APPCAST" << XMLEOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>VibeHub</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
            <enclosure url="$GITHUB_DOWNLOAD_URL" length="$DMG_LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIG"/>
        </item>
    </channel>
</rss>
XMLEOF
        fi

        echo "Appcast updated: $APPCAST"

        # Commit and push
        cd "$SITE_DIR"
        git add appcast.xml
        if git diff --cached --quiet; then
            echo "No changes to appcast."
        else
            git commit -m "update appcast for v$VERSION"
            git push
            echo "Appcast saved to releases directory."
        fi
        cd "$PROJECT_DIR"
    fi
fi

echo ""

# ============================================
# Done
# ============================================
echo "=== Release Complete ==="
echo ""
echo "  Version:  $VERSION (build $BUILD)"
echo "  DMG:      $DMG_PATH"
echo "  Release:  https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
echo "  Download: $GITHUB_DOWNLOAD_URL"
echo "  Appcast:  https://mtunique.github.io/vibehub-site/appcast.xml"
