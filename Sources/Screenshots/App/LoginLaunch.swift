import AppKit
import ServiceManagement

/// Opened by macOS at login ("Open at login"): then the app starts in the menu bar only, with no
/// window (the Ciro, 03/11/2026). Opening it again from Finder or Spotlight brings the window.
@MainActor
enum LoginLaunch {
    /// Call from applicationDidFinishLaunching, while the launch's open event is still current.
    static func isNow() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // A login item registered with SMAppService is not always marked in that event: one that
        // starts in the first ten minutes after the Mac boots is taken as opened at login.
        return SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 600
    }
}
