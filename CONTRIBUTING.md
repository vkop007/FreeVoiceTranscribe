# Contributing

## Before submitting a change

Install Zig and the Xcode Command Line Tools on macOS. Build both the executable and application bundle:

```sh
zig build
zig build app
```

Run the bundle with `open zig-out/FreeVoiceTranscribe.app` and manually check the shortcut or menu flow affected by the change. Changes involving audio, permissions, pasteboard behavior, or Swift model availability should be tested on a real macOS installation.

## Project conventions

- Keep application state and timing in `src/main.zig`.
- Keep Apple framework bridging in the Objective-C sources under `src/`.
- Keep Swift-only SpeechAnalyzer and Foundation Models code in the Swift sources.
- Do not commit `.zig-cache/`, `zig-out/`, ad-hoc signatures, or local vocabulary data.
- Keep changes focused and document user-visible behavior in `README.md`.

There is no automated test suite yet. Include the commands and manual checks you performed in a pull request description.
