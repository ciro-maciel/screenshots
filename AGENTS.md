# Notes for coding agents

Screenshots is a native macOS menu bar app in Swift, AppKit and SwiftUI. It is built by `scripts/build.sh` with `swiftc`, so there is no Xcode project and no Swift package.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/Screenshots/App/` | Entry point, capture flow, global shortcuts, preferences, the capture library (history) |
| `Sources/Screenshots/Capture/` | ScreenCaptureKit capture, the frozen-screen area selector, scrolling capture and stitching, recording, OCR |
| `Sources/Screenshots/Editor/` | The annotation editor: model, canvas, window |
| `Sources/Screenshots/UI/` | Windows and panels; `Theme.swift` holds the design tokens, `MacShell.swift` the app frame, `L10n.swift` the interface language |
| `Sources/Screenshots/Tests/` | `--e2e`, `--memtest` and `--screenshots`, compiled into the app |
| `scripts/` | Build, local install, signing identity, tests, asset regeneration |
| `scripts/release/` | Packing the `.dmg` and publishing it; used by `.github/workflows/release.yml` |

## Before you say it works

```bash
scripts/build.sh
scripts/test.sh e2e /tmp/e2e
scripts/test.sh memtest
```

The tests need a terminal with Screen Recording. They run on a virtual display (`scripts/virtual-display.m`); never call `--e2e` on the binary directly.

## Rules that must hold

- No network code, anywhere: no `URLSession`, no sockets. Captures never leave the Mac.
- The app's own windows (selection layer, Quick Access, bars, notices) are excluded from every capture.
- No pixel of a capture goes through `CGContext.draw` of a system image: Core Graphics would keep a decoded copy of each one. Memory stays flat during recording and scrolling capture; `memtest` holds the ceilings.
- The bundle identifier (`click.ciromaciel.screenshots`) never changes: macOS ties Screen Recording to it.
- Every user-facing string exists in English and Brazilian Portuguese (`Resources/en.lproj` and `Resources/pt-BR.lproj`, read through `L("English text")` in `UI/L10n.swift`); a change that adds text adds both. The app follows the Mac's first language: Portuguese when it starts with `pt`, English otherwise. Code, comments and file names are in English.
