#!/bin/zsh
# LinkOSC.app をビルドして dist/ に生成する
set -e
cd "$(dirname "$0")"

VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/LinkOSC/AppInfo.swift)
BUILD=$(sed -n 's/.*static let build = "\(.*\)".*/\1/p' Sources/LinkOSC/AppInfo.swift)
echo "version: $VERSION ($BUILD)"

swift build -c release

APP=dist/LinkOSC.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/LinkOSC "$APP/Contents/MacOS/LinkOSC"

# テストデータをバンドルに同梱 (開発モードのデフォルト WAV/MIDI)
mkdir -p "$APP/Contents/Resources"
cp Sources/LinkOSC/Resources/loop-test.wav "$APP/Contents/Resources/"
cp Sources/LinkOSC/Resources/loop-test-effects.wav "$APP/Contents/Resources/"
cp Sources/LinkOSC/Resources/loop-test.mid "$APP/Contents/Resources/"
# SPM リソースバンドル (Bundle.module フォールバック用)
if [ -d .build/release/LinkOSC_LinkOSC.bundle ]; then
  cp -R .build/release/LinkOSC_LinkOSC.bundle "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleName</key><string>LinkOSC</string>
	<key>CFBundleDisplayName</key><string>LinkOSC</string>
	<key>CFBundleIdentifier</key><string>com.fil.linkosc</string>
	<key>CFBundleExecutable</key><string>LinkOSC</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Used to join Ableton Link sessions (UDP multicast) and send OSC to devices on the local network.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Used to analyze audio from the input device selected in LinkOSC and send OSC.</string>
</dict>
</plist>
PLIST

# 拡張属性 (Finder情報など) が残っていると codesign が失敗する
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "built: $APP"
