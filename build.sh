#!/bin/zsh
set -eu
cd "${0:A:h}"
bundle="$PWD/build/Codex Speed Lite.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$PWD/build/module-cache"
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macos14.0 Localization.swift APIMetrics.swift DesktopClient.swift SelfTests.swift main.swift -o "$bundle/Contents/MacOS/CodexSpeedLite"
cp Info.plist "$bundle/Contents/Info.plist"
cp -R Resources/*.lproj "$bundle/Contents/Resources/"
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" Icon.swift -o build/make-icon
build/make-icon "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 3.2.1' "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 17' "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/CodexSpeedLite" --self-test
