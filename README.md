# FreeVoiceTranscribe

[![Build & Release (macOS & Windows)](https://github.com/vkop007/FreeVoiceTranscribe/actions/workflows/release.yml/badge.svg)](https://github.com/vkop007/FreeVoiceTranscribe/actions/workflows/release.yml)
[![Latest Release](https://img.shields.io/github/v/release/vkop007/FreeVoiceTranscribe?label=Download%20Latest%20Build&color=blue)](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest)

FreeVoiceTranscribe is a cross-platform (macOS menu bar & Windows system tray) voice transcription and dictation tool. Hold a global shortcut, speak, and the transcript is pasted into the text field that currently has focus. It also supports free on-device text cleanup and spoken edits to selected text using Apple's on-device models on macOS and Windows Copilot Runtime (Phi Silica) / built-in Windows AI on Windows.

## Download Prebuilt Releases

Download the latest prebuilt binaries directly from [GitHub Releases](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest):

| Platform | Architecture | Direct Download | Package Type |
| :--- | :--- | :--- | :--- |
| **macOS** | Apple Silicon & Intel | [**FreeVoiceTranscribe-macOS.dmg**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-macOS.dmg) | macOS Disk Image installer (`FreeVoiceTranscribe.app`) |
| **macOS** | Apple Silicon & Intel | [**FreeVoiceTranscribe-macOS.zip**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-macOS.zip) | Portable `.app` bundle archive |
| **Windows** | 64-bit (`x86_64`) | [**FreeVoiceTranscribe-Windows-x64.zip**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-Windows-x64.zip) | Full bundle (`FreeVoiceTranscribe.exe` + `copilot_bridge.ps1` + optional `libenhance.dll`) |
| **Windows** | 64-bit (`x86_64`) | [**FreeVoiceTranscribe-Windows-x64.exe**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-Windows-x64.exe) | Standalone Windows x64 executable |
| **Windows** | ARM64 (Copilot+ PCs) | [**FreeVoiceTranscribe-Windows-arm64.zip**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-Windows-arm64.zip) | Full bundle for Windows on ARM / Copilot+ PCs |
| **Windows** | ARM64 (Copilot+ PCs) | [**FreeVoiceTranscribe-Windows-arm64.exe**](https://github.com/vkop007/FreeVoiceTranscribe/releases/latest/download/FreeVoiceTranscribe-Windows-arm64.exe) | Standalone Windows ARM64 executable |

## Features

- Push-to-talk dictation with `Cmd+Shift+R` (macOS) or `Ctrl+Shift+R` (Windows).
- Dictation with on-device text enhancement with `Cmd+Shift+E` (macOS) or `Ctrl+Shift+E` (Windows).
- Spoken rewriting of the currently selected text with `Cmd+Shift+T` (macOS) or `Ctrl+Shift+T` (Windows).
- A menu bar / system tray orb and floating live-transcription pill overlay.
- Configurable enhancement styles: clean up, formal, concise, AI prompt, and bullet notes.
- An editable vocabulary list for names, products, and technical terms.
- Clipboard preservation while pasting or rewriting.
- 100% free speech and language-model processing through built-in OS APIs:
  - **macOS**: Apple's on-device `SpeechAnalyzer` / `SFSpeechRecognizer` and `FoundationModels` (Apple Intelligence).
  - **Windows**: Built-in Windows Speech Recognition (`Windows.Media.SpeechRecognition` / `System.Speech`) and Windows Copilot Runtime (`Microsoft.Windows.AI` Phi Silica via `libenhance.dll` or `scripts/copilot_bridge.ps1`), with automatic fallback to Windows AI Foundry Local and an offline rule-based grammar/style enhancer on PCs without an NPU.

## Requirements

### macOS
- macOS with the Apple Speech and Foundation Models frameworks available. The current Swift sources target macOS 26 or newer (with automatic `SFSpeechRecognizer` fallback on earlier macOS versions).
- Xcode Command Line Tools, including `clang`, `swiftc`, `codesign`, and `iconutil`.
- Zig installed and available as `zig` in the shell (optional; `scripts/bundle.sh` falls back to `clang` if Zig is not installed).
- A microphone for dictation. Apple Intelligence availability may vary by Mac, language, and region.

### Windows
- Windows 10 or Windows 11 with a microphone and Windows Speech Recognition enabled.
- Zig, MinGW GCC, Clang, or MSVC Build Tools when building from source.
- Optional: .NET 8+ SDK to build the NativeAOT `libenhance.dll` companion library for direct Windows Copilot Runtime (`Microsoft.Windows.AI`) calls (otherwise `scripts/copilot_bridge.ps1` handles Windows Copilot Runtime, Foundry Local, and offline enhancement automatically).

## Build from Source

### macOS

Build the Zig executable:

```sh
zig build
```

Build the application bundle, including the Swift enhancement library:

```sh
zig build app
# or without Zig installed:
./scripts/bundle.sh --package
```

The bundle is written to `zig-out/FreeVoiceTranscribe.app` (and `--package` creates `zig-out/FreeVoiceTranscribe-macOS.dmg` and `zig-out/FreeVoiceTranscribe-macOS.zip`). Launch it with:

```sh
open zig-out/FreeVoiceTranscribe.app
```

To regenerate the icon after changing the orb artwork:

```sh
scripts/make_icon.sh
```

### Windows

Build on Windows (or cross-compile from macOS/Linux):

```sh
# Native build on Windows:
zig build -Doptimize=ReleaseSafe

# Or cross-compile from macOS / Linux (x86_64 or ARM64 for Copilot+ PCs):
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseSafe
```

To build and package the full Windows release bundle on Windows (including the optional NativeAOT `libenhance.dll` for Windows Copilot Runtime):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bundle_windows.ps1 -Package
```

The executable and Copilot bridge script are written to `zig-out\bin\FreeVoiceTranscribe.exe` (`zig-out\bin\free-voice-transcribe.exe`), and the release archives are written to `zig-out\FreeVoiceTranscribe-Windows-x64.zip` and `zig-out\FreeVoiceTranscribe-Windows-arm64.zip`.

## Automated GitHub Releases

The GitHub Actions workflow in [`.github/workflows/release.yml`](.github/workflows/release.yml) automatically builds and publishes macOS and Windows release downloads:
- **Every push to `main`** automatically builds the macOS (`.dmg` and `.zip`) and Windows (`x64` and `arm64` `.zip` and `.exe`) packages and updates the latest GitHub Release so download links are always up to date.
- **Pushing a version tag** (e.g., `git tag v1.0.0 && git push origin v1.0.0`) creates a dedicated versioned GitHub Release with all platform installers and SHA-256 checksums.
- **Manual dispatch**: You can also trigger a release at any time from the **Actions → Build & Release (macOS & Windows) → Run workflow** button in GitHub.

## Permissions

- **macOS**: On first launch, macOS asks for Microphone and Speech Recognition access. Enable FreeVoiceTranscribe in **System Settings > Privacy & Security > Accessibility** so it can send the keyboard shortcut that pastes text. Without Accessibility access, transcripts are left on the clipboard for manual pasting.
- **Windows**: Ensure microphone access is enabled in **Settings > Privacy & security > Microphone** and speech recognition is enabled in **Settings > Privacy & security > Speech**.

## Use

| Action | macOS Shortcut | Windows Shortcut |
| :--- | :--- | :--- |
| Push-to-talk dictation | Hold `Cmd+Shift+R` | Hold `Ctrl+Shift+R` |
| Dictate + AI enhance | Hold `Cmd+Shift+E` | Hold `Ctrl+Shift+E` |
| Spoken rewrite of selection | Hold `Cmd+Shift+T` | Hold `Ctrl+Shift+T` |

To rewrite existing text, select it, hold `Cmd+Shift+T` (macOS) or `Ctrl+Shift+T` (Windows), and say what to change (for example, `make this more concise` or `turn this into bullet points`). The result replaces the selection. Selections larger than 6,000 bytes are left unchanged.

The menu bar / system tray icon also provides start/stop actions, sound control, enhancement style selection, vocabulary editing, and quit. The vocabulary file is stored at:

- **macOS**: `~/Library/Application Support/FreeVoiceTranscribe/vocabulary.txt`
- **Windows**: `%APPDATA%\FreeVoiceTranscribe\vocabulary.txt`

Put one name or term per line. Lines beginning with `#` are comments.

## Privacy

FreeVoiceTranscribe uses built-in on-device OS speech and language models (Apple `SpeechAnalyzer` / `FoundationModels` on macOS, and Windows Speech / Windows Copilot Runtime Phi Silica on Windows). The application does not contain a custom cloud service, paid API key requirement, or telemetry component.

## Development

- `src/main.zig` & `src/main.c`: Cross-platform state machine, timers, and workflow orchestration.
- `src/shim.h`: Platform abstraction C ABI shared between macOS and Windows.
- `src/orb.h` & `src/orb_math.c`: Portable orb animation physics and 32-bit BGRA software rasterizer.
- `src/shim.m`, `src/orb.m`, `src/orbview.m`: macOS AppKit, CoreGraphics, CoreAnimation, AVAudioEngine, and Speech integration.
- `src/enhance.swift`, `src/speech.swift`: macOS runtime-loaded dylib for `SpeechAnalyzer` and `FoundationModels`.
- `src/shim_win.c`: Windows Win32 system tray, layered pill overlay, low-level keyboard hook, clipboard, WinMM audio metering, and speech/Copilot integration.
- `src/enhance_win.cs` & `scripts/copilot_bridge.ps1`: Windows Copilot Runtime (`Microsoft.Windows.AI` Phi Silica), Windows AI Foundry Local, and built-in offline enhancement bridge.

## License

FreeVoiceTranscribe is released under the [MIT License](LICENSE).
