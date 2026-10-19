# Contributing

Thanks for helping. Screenshots sits in the menu bar of people's Macs and sees their screen, so the bar is "fast, quiet and never surprising".

## Code

```bash
scripts/build.sh
scripts/test.sh e2e /tmp/e2e
scripts/test.sh memtest
```

Both tests must pass on your Mac before you open the pull request. Run them from a terminal that has Screen Recording; they use an invisible virtual display, so they don't take over your screen. If your change touches a window or panel, attach a capture from `dist/Screenshots.app/Contents/MacOS/Screenshots --screenshots /tmp/screens`.

House rules:

- Swift, AppKit and SwiftUI only, built by `swiftc`. No Xcode project, no package manager, no dependencies.
- No network code. Screenshots never talks to the internet, and that is a promise in the README.
- Memory is a feature: the app idles small, and a long recording or a long scrolling capture must not grow it. Keep `memtest` green.
- Global shortcuts go through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission. Only "scroll by itself" asks for Accessibility.

## Reporting a bug

Say which macOS version, which Mac, which capture mode and what you expected. A capture of the problem helps; for a scrolling capture, say which app and page.

For anything that could expose someone's screen or data, read [SECURITY.md](SECURITY.md) first.
