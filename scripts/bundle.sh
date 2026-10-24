#!/bin/sh
# Wraps the built binary in an .app so macOS shows microphone / speech permission prompts.
# Builds via Zig if available, or falls back to clang with src/main.c.
# Pass --package (or set PACKAGE_RELEASE=1) to also create FreeVoiceTranscribe-macOS.dmg and FreeVoiceTranscribe-macOS.zip.
set -e
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"

mkdir -p zig-out/bin
if command -v clang >/dev/null 2>&1; then
    if clang -O2 -arch arm64 -arch x86_64 -fobjc-arc -I src \
        src/main.c src/orb_math.c src/shim.m src/orb.m src/orbview.m \
        -framework Cocoa -framework Speech -framework AVFoundation \
        -framework Carbon -framework ApplicationServices -framework QuartzCore \
        -o zig-out/bin/free-voice-transcribe 2>/dev/null; then
        echo "Built universal (arm64 + x86_64) macOS binary with clang"
    else
        clang -O2 -fobjc-arc -I src \
            src/main.c src/orb_math.c src/shim.m src/orb.m src/orbview.m \
            -framework Cocoa -framework Speech -framework AVFoundation \
            -framework Carbon -framework ApplicationServices -framework QuartzCore \
            -o zig-out/bin/free-voice-transcribe
        echo "Built native macOS binary with clang"
    fi
elif command -v zig >/dev/null 2>&1; then
    zig build -Doptimize=ReleaseSafe
else
    echo "Error: neither clang nor zig compiler found" >&2
    exit 1
fi

if [ ! -f resources/AppIcon.icns ] && [ -x scripts/make_icon.sh ]; then
    scripts/make_icon.sh
fi

APP=zig-out/FreeVoiceTranscribe.app
rm -rf "$APP" zig-out/SiriAssistant.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ -f resources/AppIcon.icns ]; then
    cp resources/AppIcon.icns "$APP/Contents/Resources/"
fi

# Swift-only FoundationModels / SpeechAnalyzer code (macOS 26+ SDK) lives in an optional dylib loaded at runtime.
if command -v swiftc >/dev/null 2>&1 && \
   swiftc -parse-as-library -emit-library -module-name SAEnhance src/enhance.swift src/speech.swift \
       -o "$APP/Contents/Frameworks/libenhance.dylib" -Xlinker -install_name -Xlinker @rpath/libenhance.dylib 2>/dev/null; then
    codesign --force --sign - "$APP/Contents/Frameworks/libenhance.dylib"
else
    echo "Note: macOS 26+ Swift SDK (FoundationModels / SpeechAnalyzer) unavailable on build host; building with SFSpeechRecognizer fallback."
fi

cp zig-out/bin/free-voice-transcribe "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.vk.freevoicetranscribe</string>
  <key>CFBundleName</key><string>FreeVoiceTranscribe</string>
  <key>CFBundleDisplayName</key><string>FreeVoiceTranscribe</string>
  <key>CFBundleExecutable</key><string>free-voice-transcribe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records your voice to transcribe it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribes your voice into text.</string>
</dict></plist>
PLIST
# Pin the designated requirement to the bundle id so the Accessibility grant survives rebuilds
# (a plain ad-hoc signature is tied to the binary hash, which changes on every build).
codesign --force --sign - -r="designated => identifier \"dev.vk.freevoicetranscribe\"" "$APP"
echo "Built $APP — run: open $APP"

if [ "${1:-}" = "--package" ] || [ "${PACKAGE_RELEASE:-0}" = "1" ]; then
    ZIP_OUT="zig-out/FreeVoiceTranscribe-macOS.zip"
    DMG_OUT="zig-out/FreeVoiceTranscribe-macOS.dmg"
    rm -f "$ZIP_OUT" "$DMG_OUT" zig-out/SiriAssistant-macOS.zip zig-out/SiriAssistant-macOS.dmg

    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_OUT"
    echo "Packaged $ZIP_OUT"

    STAGE_DIR=$(mktemp -d)
    cp -R "$APP" "$STAGE_DIR/FreeVoiceTranscribe.app"
    ln -s /Applications "$STAGE_DIR/Applications"
    if command -v hdiutil >/dev/null 2>&1 && \
       hdiutil create -volname "FreeVoiceTranscribe" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_OUT" 2>/dev/null; then
        echo "Packaged $DMG_OUT"
    elif command -v diskutil >/dev/null 2>&1 && \
       diskutil image create from "$STAGE_DIR" "$DMG_OUT" --volumeName "FreeVoiceTranscribe" --format UDZO 2>/dev/null; then
        echo "Packaged $DMG_OUT"
    else
        echo "Note: DMG disk-device creation skipped in restricted environment ($ZIP_OUT is ready)."
    fi
    rm -rf "$STAGE_DIR"
fi
