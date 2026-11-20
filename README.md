English | [简体中文](README.zh-CN.md)

# Shocrot

Shocrot is a lightweight menu bar app for macOS that puts screenshots, screen recording, annotation, text recognition (OCR) and translation behind a single shortcut. It is written in pure Swift (AppKit + SwiftUI) with no third-party dependencies. Text recognition uses the Vision framework built into macOS and works fully offline.

## Highlights

- **Area capture**: snaps to windows, magnifier with color picker (press C to copy the color), pixel size readout, 8-way resize and drag, arrow-key nudging. ⌥-click captures a single window with its shadow.
- **Annotation**: rectangle, ellipse, arrow, pen, highlighter, mosaic, text, step numbers and a measuring ruler; 8 colors and 3 line widths; undo and redo. Hold ⇧ for squares and 45° arrows.
- **Scrolling capture**: select an area, scroll the page, and Shocrot stitches it into one long image.
- **Screen recording**: record a selection to MP4 (stop with ⌃⌘⎋ or the HUD button), then export a looping GIF from the preview card. Frame rate and maximum width are set in Settings.
- **Beautify**: one click on the preview card adds a gradient background, rounded corners and a shadow.
- **Text recognition**: select an area to recognize text and copy it automatically. In the result window you can edit the text, click a line to copy it, keep line breaks or join lines into paragraphs, translate or search. QR codes and barcodes are read as well.
- **Translation**: translate selected text, a screenshot or typed text in one floating panel. The language is detected automatically (your primary language ↔ your secondary language), single words show the system dictionary definition, and you can read results aloud, copy them or pin the panel.
  - **Apple Translate**: on-device and offline; missing languages can be downloaded right from the panel.
  - **Google Translate**: free with no setup (needs an internet connection, off by default).
  - **LLMs**: any OpenAI-compatible API (OpenAI, DeepSeek, Ollama, LM Studio…), with streaming output. Local reasoning models can skip "thinking" for instant results. API keys are stored in the Keychain.
- **Pins**: keep a capture floating above all windows. Scroll to zoom, ⌥/⌘ + scroll to change opacity, ⌘R / ⇧⌘R to rotate, right-click to flip, double-click or Esc to close.
- **History**: the last 200 captures, searchable by their recognized text.
- Full-screen capture, pinning the clipboard, recognizing text in clipboard images or image files, customizable global shortcuts, and Open at Login.
- **Languages**: English and Simplified Chinese. Shocrot follows the system language by default; to change it, open Settings › General › Language and restart the app.
- **Private by default**: everything is processed on your Mac. Online translation (Google or a cloud LLM) only runs after you turn it on.

## Requirements

- macOS 26 or later
- Apple silicon or Intel Mac (universal binary)
- To build from source: Xcode 26 or later (Swift 6 toolchain)

## Install

1. Open the [latest release](https://github.com/WeaveNeuron/shocrot/releases/latest) on GitHub Releases. All versions are listed on the [Releases page](https://github.com/WeaveNeuron/shocrot/releases).
2. Under **Assets**, download `Shocrot-<version>-macOS-universal.zip`. Optionally, also download the matching `.sha256` file and verify the download:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c Shocrot-<version>-macOS-universal.zip.sha256
   ```

3. Double-click the zip to unpack it, then drag **Shocrot.app** into your **Applications** folder.
4. Open Shocrot from Applications. It runs in the menu bar, not the Dock, and opens a welcome window the first time.
5. Click **Turn On** next to Screen Recording and allow Shocrot in **System Settings › Privacy & Security › Screen & System Audio Recording**, then restart Shocrot when asked.

To update, quit Shocrot and replace the app in Applications with the new version.

## Permissions

| Permission | Needed for | Required |
| --- | --- | --- |
| Screen Recording | Screenshots, screen recording, text recognition and screenshot translation | Yes |
| Accessibility | Translating selected text, and picking controls inside a window with the scroll wheel while capturing | Optional |

Shocrot asks for Accessibility only when you first use a feature that needs it. Both permissions can be checked and granted later in Settings › General.

## Shortcuts

Global shortcuts (change them in Settings › Shortcuts):

| Action | Shortcut |
| --- | --- |
| Capture Area | ⌥⇧A |
| Recognize Text (OCR) | ⌥⇧T |
| Capture Full Screen | ⌥⇧F |
| Pin Clipboard | ⌥⇧P |
| Translate Selection | ⌥⇧D |
| Translate Screenshot | ⌥⇧X |
| Type to Translate | ⌥⇧I |

While capturing:

| Action | Shortcut |
| --- | --- |
| Copy and finish | ↩ / ⌘C / double-click |
| Save / Save As | ⌘S / ⇧⌘S |
| Recognize text / Translate / Pin | ⌘T / ⌘D / ⌘P |
| Scrolling capture / Record screen | ⌘L / ⌘R |
| Stop and save a recording | ⌃⌘⎋ |
| Annotation tools | R O A P H M T N U |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Nudge the selection | Arrow keys (with ⇧ for 10×) |
| Copy color / Select full screen | C / ⌘A |
| Capture a single window | ⌥-click |
| Cancel | Esc / right-click |

## Automation

### URL scheme

`shocrot://capture`, `ocr`, `fullscreen`, `pin`, `ocr-clipboard`, `translate?text=…`, `translate-selection`, `translate-capture`, `history` and `settings` can be called from Shortcuts, Raycast, Alfred or `open`:

```sh
open "shocrot://translate?text=Hello"
```

### Command-line OCR

```sh
/Applications/Shocrot.app/Contents/MacOS/Shocrot --ocr image.png
```

## Build from source

```sh
git clone https://github.com/WeaveNeuron/shocrot.git
cd shocrot
swift build        # debug build
swift test         # unit tests
scripts/build_app.sh            # build/Shocrot.app (release, universal)
scripts/build_app.sh --install  # also install it to /Applications
```

`scripts/build_app.sh` options:

| Option | What it does |
| --- | --- |
| `--install` | Copies the app to /Applications (quits a running Shocrot first). |
| `--package` | Writes `build/Shocrot-<version>-macOS-universal.zip` and its `.sha256`, ready to attach to a GitHub release. |
| `--notarize` | Notarizes and staples the app (needs a Developer ID Application identity and a `notarytool` keychain profile), then packages it. |
| `--adhoc` | Signs ad-hoc without any keychain lookup, for local checks and CI. |

The version comes from `SHOCROT_VERSION` (for example `SHOCROT_VERSION=1.2.0 scripts/build_app.sh --package`); the build number is the git commit count. The signing identity is chosen in this order: `SHOCROT_SIGN_IDENTITY`, a Developer ID Application certificate for `SHOCROT_TEAM_ID`, the self-signed `Shocrot Local Signing` certificate (create it with `scripts/make_local_cert.sh`), then ad-hoc. With a stable certificate, privacy permissions survive rebuilds; with ad-hoc signing you may need to grant them again after each build.

### Localization

User-facing text lives in `Sources/Shocrot/Resources/<language>.lproj/Localizable.strings`, with `InfoPlist.strings` for Info.plist values. English (`en`) is the development language and the fallback; Simplified Chinese (`zh-Hans`) mirrors the same keys. In code, use `L("key")`, `L("key", args…)` or `L10n.plural("key", count)`. The tests check that every key the code uses exists in both languages and that translations keep the same format specifiers.

### Development notes

- Debug the capture overlay without the Screen Recording permission: `SHOCROT_DEMO_IMAGE=<png> .build/debug/Shocrot` uses the image as the screen and starts a capture (debug builds only).
- Text recognition engine: implement `OCREngine` (`Sources/Shocrot/OCR/OCRService.swift`) and assign it to `OCRService.engine`.
- Translation services: implement `TranslationService` (`Sources/Shocrot/Translate/TranslationService.swift`) and add it to `TranslationServices.enabled`.
- `swift build` / `swift test` write `output-file-map.json` to your TemporaryItems folder. If a sandbox blocks that write (EPERM), the error looks like ordinary I/O and stops before the tests start; allow writes to TemporaryItems and run again.

## License

Copyright 2026 WeaveNeuron LTD.

Licensed under the [Apache License, Version 2.0](LICENSE).
