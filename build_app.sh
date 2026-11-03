#!/bin/bash
# Compila y arma LimpiaMac.app (sin sandbox, para poder leer/borrar caches).
set -euo pipefail
: "${DEVELOPER_DIR:=/Applications/Xcode.app/Contents/Developer}"; export DEVELOPER_DIR
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/LimpiaMac/*.swift -o .build/LimpiaMac
APP="LimpiaMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/LimpiaMac "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LimpiaMac</string>
<key>CFBundleDisplayName</key><string>LimpiaMac</string>
<key>CFBundleIdentifier</key><string>dev.jguerra.limpiamac</string>
<key>CFBundleExecutable</key><string>LimpiaMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>LimpiaMac analiza tus fotos para encontrar las parecidas y que decidas cuáles borrar.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Listo: $(pwd)/$APP"
