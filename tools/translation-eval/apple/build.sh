#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
output_dir=${1:-"$repo_root/build/apple-translation-eval"}
app_dir="$output_dir/AppleTranslationEval.app"
mkdir -p "$app_dir/Contents/MacOS"

xcrun swiftc -O -swift-version 6 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -target arm64-apple-macos26.4 -parse-as-library \
    "$repo_root/tools/translation-eval/apple/AppleTranslationEval.swift" \
    -framework AppKit -framework SwiftUI -framework Translation \
    -o "$app_dir/Contents/MacOS/AppleTranslationEval"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AppleTranslationEval</string>
<key>CFBundleIdentifier</key><string>local.lore.AppleTranslationEval</string>
<key>CFBundleName</key><string>Apple Translation Evaluation</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.4</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
