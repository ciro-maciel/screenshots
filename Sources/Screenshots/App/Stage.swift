import AppKit

/// Where the app shows itself. Normally: every screen, the general clipboard, activation as
/// usual. Under the isolated tests (SCREENSHOTS_TEST_DISPLAY = a virtual display made by
/// scripts/test.sh), everything happens on that invisible display: windows, overlays and
/// thumbnails go there, nothing takes the keyboard focus, and copies go to a clipboard of the
/// tests, so the person keeps working on their own screen meanwhile.
enum Stage {
    static let testDisplay: CGDirectDisplayID? = ProcessInfo.processInfo.environment["SCREENSHOTS_TEST_DISPLAY"].flatMap { UInt32($0) }
    static var isolated: Bool { testDisplay != nil }

    static var testScreen: NSScreen? {
        guard let id = testDisplay else { return nil }
        return NSScreen.screens.first { Geometry.displayID($0) == id }
    }

    /// The screens the app works on.
    static var screens: [NSScreen] {
        if isolated { return testScreen.map { [$0] } ?? [] }
        return NSScreen.screens
    }

    static var board: NSPasteboard {
        isolated ? NSPasteboard(name: NSPasteboard.Name("click.ciromaciel.screenshots.tests")) : .general
    }

    /// Isolated tests stop the moment their display goes away: their windows would otherwise
    /// land on the person's screen.
    @MainActor
    static func guardDisplay() {
        guard isolated else { return }
        if testScreen == nil { print("test display missing"); exit(3) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            if testScreen == nil { print("test display gone: stopping"); exit(3) }
        }
    }

    @MainActor
    static func activate() {
        if !isolated { NSApp.activate(ignoringOtherApps: true) }
    }
}
