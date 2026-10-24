# SiriAssistant

SiriAssistant is a macOS menu bar voice tool. Hold a global shortcut, speak, and the transcript is pasted into the text field that currently has focus. It also supports on-device cleanup and spoken edits to selected text.

## Features

- Push-to-talk dictation with `Cmd+Shift+R`.
- Dictation with on-device text enhancement with `Cmd+Shift+E`.
- Spoken rewriting of the currently selected text with `Cmd+Shift+T`.
- A menu bar orb and floating live-transcription overlay.
- Configurable enhancement styles: clean up, formal, concise, AI prompt, and bullet notes.
- An editable vocabulary list for names, products, and technical terms.
- Clipboard preservation while pasting or rewriting.
- Speech and language-model processing through Apple's on-device APIs when available.

## Requirements

- macOS with the Apple Speech and Foundation Models frameworks available. The current Swift sources target macOS 26 or newer.
- Xcode Command Line Tools, including `clang`, `swiftc`, `codesign`, and `iconutil`.
- Zig installed and available as `zig` in the shell.
- A microphone for dictation. Apple Intelligence availability may vary by Mac, language, and region.

## Build

Build the Zig executable:

```sh
zig build
```

Build the application bundle, including the Swift enhancement library:

```sh
zig build app
```

The bundle is written to `zig-out/SiriAssistant.app`. Launch it with:

```sh
open zig-out/SiriAssistant.app
```

The application is ad-hoc signed locally so macOS can apply the bundle's permissions. It is not a distributable notarized release.

To regenerate the icon after changing the orb artwork:

```sh
scripts/make_icon.sh
```

## Permissions

On first launch, macOS asks for Microphone and Speech Recognition access. Enable SiriAssistant in **System Settings > Privacy & Security > Accessibility** so it can send the keyboard shortcut that pastes text. Without Accessibility access, transcripts are left on the clipboard for manual pasting.

## Use

Hold `Cmd+Shift+R`, speak, and release the keys. The transcript is pasted into the focused application.

Hold `Cmd+Shift+E` to dictate and enhance the text before it is pasted. The selected enhancement style is available from the menu bar item.

To rewrite existing text, select it, hold `Cmd+Shift+T`, and say what to change. For example, say `make this more concise`. The result replaces the selection. Selections larger than 6,000 bytes are left unchanged.

The menu bar item also provides start/stop actions, sound control, enhancement style selection, vocabulary editing, and quit. The vocabulary file is stored at:

```text
~/Library/Application Support/SiriAssistant/vocabulary.txt
```

Put one name or term per line. Lines beginning with `#` are comments.

## Privacy

SiriAssistant prefers Apple's on-device SpeechAnalyzer and Foundation Models APIs. The speech fallback requests on-device recognition when the system supports it. The application does not contain a network service or telemetry component. Apple's availability and permission behavior still applies to the frameworks supplied by macOS.

## Development

The Zig entry point owns application state and timing. The Objective-C shim bridges AppKit, audio, speech, pasteboard, global hotkeys, and the animated overlay. The Swift sources provide the newer speech analyzer and text-model features through a runtime-loaded dylib.

Generated build output belongs in `zig-out/` and `.zig-cache/`; both are ignored by Git. There is currently no automated test suite. At minimum, run `zig build` after changes and manually exercise each shortcut from the bundled app.

## License

SiriAssistant is released under the [MIT License](LICENSE).