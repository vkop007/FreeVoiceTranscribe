#!/bin/sh
# Wraps the built binary in an .app so macOS shows microphone / speech permission prompts.
set -e
cd "$(dirname "$0")/.."
APP=zig-out/SiriAssistant.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/AppIcon.icns "$APP/Contents/Resources/"
# Swift-only FoundationModels code lives in a dylib that the app loads at runtime.
mkdir -p "$APP/Contents/Frameworks"
swiftc -parse-as-library -emit-library -module-name SAEnhance src/enhance.swift src/speech.swift \
    -o "$APP/Contents/Frameworks/libenhance.dylib" -Xlinker -install_name -Xlinker @rpath/libenhance.dylib
codesign --force --sign - "$APP/Contents/Frameworks/libenhance.dylib"
cp zig-out/bin/siri-assistant "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.vk.siriassistant</string>
  <key>CFBundleName</key><string>SiriAssistant</string>
  <key>CFBundleExecutable</key><string>siri-assistant</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records your voice to transcribe it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribes your voice into text.</string>
</dict></plist>
PLIST
# Pin the designated requirement to the bundle id so the Accessibility grant survives rebuilds
# (a plain ad-hoc signature is tied to the binary hash, which changes on every build).
codesign --force --sign - -r="designated => identifier \"dev.vk.siriassistant\"" "$APP"
echo "Built $APP — run: open $APP"
