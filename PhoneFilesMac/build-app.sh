#!/bin/bash
# Builds "Phone Files.app": compiles release, bundles libmtp + libusb so the app runs
# without Homebrew paths baked in, adds the icon and ad-hoc signs everything.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Phone Files.app"
BREW="$(brew --prefix)"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/PhoneFiles "$APP/Contents/MacOS/PhoneFiles"

# Icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Tools/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Bundle the native libraries and point everything at the copies.
MTP_SRC="$BREW/opt/libmtp/lib/libmtp.9.dylib"
USB_SRC="$BREW/opt/libusb/lib/libusb-1.0.0.dylib"
FW="$APP/Contents/Frameworks"
cp "$MTP_SRC" "$USB_SRC" "$FW/"
chmod u+w "$FW"/*.dylib
install_name_tool -id @rpath/libmtp.9.dylib "$FW/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"
install_name_tool -change "$USB_SRC" @rpath/libusb-1.0.0.dylib "$FW/libmtp.9.dylib"
install_name_tool -change "$MTP_SRC" @rpath/libmtp.9.dylib "$APP/Contents/MacOS/PhoneFiles"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/PhoneFiles"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Phone Files</string>
    <key>CFBundleDisplayName</key><string>Phone Files</string>
    <key>CFBundleIdentifier</key><string>local.phonefiles</string>
    <key>CFBundleExecutable</key><string>PhoneFiles</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Phone Files shows and copies the files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Phone Files shows and copies the files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Phone Files shows and copies the files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Phone Files shows and copies the files on external drives.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Phone Files shows and copies the files on network drives.</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.phonefiles.item</string>
            <key>UTTypeDescription</key><string>Phone Files item</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$FW/libusb-1.0.0.dylib" "$FW/libmtp.9.dylib"
codesign --force --sign - "$APP"
echo "Built: $APP"
