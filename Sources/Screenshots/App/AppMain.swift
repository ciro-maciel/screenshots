import AppKit

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon, the app's own glyph in the menu bar.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Zen.registerFonts()
            // The design system is light-only until 12-modo-escuro.md is approved.
            NSApp.appearance = NSAppearance(named: .aqua)
            let args = CommandLine.arguments
            Stage.guardDisplay()
            if args.contains("--e2e") {
                Task { exit(await E2E.run()) }
                return
            }
            if args.contains("--memtest") {
                Task { exit(await MemTest.run()) }
                return
            }
            if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
                Task { exit(await Screens.run(URL(fileURLWithPath: args[i + 1]))) }
                return
            }
            Migration.run()
            Library.shared.prune()
            Hotkeys.shared.onAction = { a in CaptureController.shared.run(a) }
            Hotkeys.shared.registerAll()
            StatusMenu.shared.install()
            let firstRun = !UserDefaults.standard.bool(forKey: "welcomed")
            if !ScreenGrabber.hasPermission || firstRun {
                UserDefaults.standard.set(true, forKey: "welcomed")
                WelcomeWindow.show()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the settings: there is no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { ScreenGrabber.hasPermission ? SettingsWindow.show() : WelcomeWindow.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// macOS grants Screen Recording to a fresh process only.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
