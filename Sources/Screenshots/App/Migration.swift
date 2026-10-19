import Foundation

/// The app was called "Screenshot" (bundle click.ciromaciel.screenshot) until 10/10/2026. On the
/// first launch as Screenshots, its settings and history come along; nothing is lost.
enum Migration {
    static let oldDomain = "click.ciromaciel.screenshot"

    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent("Screenshot")
        let newDir = support.appendingPathComponent("Screenshots")
        if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromScreenshot"), let old = UserDefaults(suiteName: oldDomain) else { return }
        for key in Prefs.keys + ["welcomed"] {
            if let v = old.object(forKey: key), defaults.object(forKey: key) == nil { defaults.set(v, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromScreenshot")
    }
}
