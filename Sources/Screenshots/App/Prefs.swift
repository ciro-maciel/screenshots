import Foundation
import Observation
import AppKit
import Carbon.HIToolbox

/// Everything the Settings window changes, kept in UserDefaults.
@Observable
final class Prefs {
    /// Tests (SCREENSHOT_HOME set) keep their settings apart from the real ones.
    static let shared = Prefs(store: ProcessInfo.processInfo.environment["SCREENSHOT_HOME"] != nil
                              ? UserDefaults(suiteName: "click.ciromaciel.screenshots.tests")! : .standard)
    @ObservationIgnored let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        func b(_ k: String, _ d: Bool) -> Bool { store.object(forKey: k) == nil ? d : store.bool(forKey: k) }
        func i(_ k: String, _ d: Int) -> Int { store.object(forKey: k) == nil ? d : store.integer(forKey: k) }
        func s(_ k: String, _ d: String) -> String { store.string(forKey: k) ?? d }
        saveFolder = s("saveFolder", (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"))
        afterShowQuickAccess = b("afterShowQuickAccess", true)
        afterCopy = b("afterCopy", true)
        afterSave = b("afterSave", false)
        afterOpenEditor = b("afterOpenEditor", false)
        afterPin = b("afterPin", false)
        playSound = b("playSound", true)
        imageFormat = ImageFormat(rawValue: s("imageFormat", "png")) ?? .png
        downscaleRetina = b("downscaleRetina", false)
        windowShadow = b("windowShadow", true)
        freezeScreen = b("freezeScreen", true)
        showMagnifier = b("showMagnifier", true)
        showCrosshair = b("showCrosshair", true)
        hideIconsWhileCapturing = b("hideIconsWhileCapturing", false)
        timerSeconds = i("timerSeconds", 5)
        quickAccessRight = b("quickAccessRight", false)
        quickAccessAutoClose = i("quickAccessAutoClose", 0)
        recordGIF = b("recordGIF", false)
        recordFPS = i("recordFPS", 30)
        recordCursor = b("recordCursor", true)
        recordClicks = b("recordClicks", true)
        recordSystemAudio = b("recordSystemAudio", false)
        recordMicrophone = b("recordMicrophone", false)
        recordRetina = b("recordRetina", true)
        annotationColor = i("annotationColor", 0)
        annotationWidth = i("annotationWidth", 1)
        windowBackground = Backdrop.Fill(rawValue: s("windowBackground", "none")) ?? .none
        backgroundPadding = i("backgroundPadding", 64)
        fileNamePrefix = s("fileNamePrefix", L("Screenshot"))
        historyDays = i("historyDays", 30)
        if let data = store.data(forKey: "shortcuts"), let saved = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = Shortcut.defaults.merging(saved.compactMapKeys { HotAction(rawValue: $0) }) { _, new in new }
        } else {
            shortcuts = Shortcut.defaults
        }
    }

    // General
    var saveFolder: String { didSet { store.set(saveFolder, forKey: "saveFolder") } }
    var afterShowQuickAccess: Bool { didSet { store.set(afterShowQuickAccess, forKey: "afterShowQuickAccess") } }
    var afterCopy: Bool { didSet { store.set(afterCopy, forKey: "afterCopy") } }
    var afterSave: Bool { didSet { store.set(afterSave, forKey: "afterSave") } }
    var afterOpenEditor: Bool { didSet { store.set(afterOpenEditor, forKey: "afterOpenEditor") } }
    var afterPin: Bool { didSet { store.set(afterPin, forKey: "afterPin") } }
    var playSound: Bool { didSet { store.set(playSound, forKey: "playSound") } }

    // Screenshots
    enum ImageFormat: String, CaseIterable { case png, jpeg
        var ext: String { self == .png ? "png" : "jpg" }
    }
    var imageFormat: ImageFormat { didSet { store.set(imageFormat.rawValue, forKey: "imageFormat") } }
    var downscaleRetina: Bool { didSet { store.set(downscaleRetina, forKey: "downscaleRetina") } }
    var windowShadow: Bool { didSet { store.set(windowShadow, forKey: "windowShadow") } }
    var freezeScreen: Bool { didSet { store.set(freezeScreen, forKey: "freezeScreen") } }
    var showMagnifier: Bool { didSet { store.set(showMagnifier, forKey: "showMagnifier") } }
    var showCrosshair: Bool { didSet { store.set(showCrosshair, forKey: "showCrosshair") } }
    var hideIconsWhileCapturing: Bool { didSet { store.set(hideIconsWhileCapturing, forKey: "hideIconsWhileCapturing") } }
    var timerSeconds: Int { didSet { store.set(timerSeconds, forKey: "timerSeconds") } }

    // Quick Access
    var quickAccessRight: Bool { didSet { store.set(quickAccessRight, forKey: "quickAccessRight") } }
    /// Seconds; 0 = stays until closed.
    var quickAccessAutoClose: Int { didSet { store.set(quickAccessAutoClose, forKey: "quickAccessAutoClose") } }

    // Recording
    var recordGIF: Bool { didSet { store.set(recordGIF, forKey: "recordGIF") } }
    var recordFPS: Int { didSet { store.set(recordFPS, forKey: "recordFPS") } }
    var recordCursor: Bool { didSet { store.set(recordCursor, forKey: "recordCursor") } }
    var recordClicks: Bool { didSet { store.set(recordClicks, forKey: "recordClicks") } }
    var recordSystemAudio: Bool { didSet { store.set(recordSystemAudio, forKey: "recordSystemAudio") } }
    var recordMicrophone: Bool { didSet { store.set(recordMicrophone, forKey: "recordMicrophone") } }
    var recordRetina: Bool { didSet { store.set(recordRetina, forKey: "recordRetina") } }

    // Annotate
    var annotationColor: Int { didSet { store.set(annotationColor, forKey: "annotationColor") } }
    var annotationWidth: Int { didSet { store.set(annotationWidth, forKey: "annotationWidth") } }

    // Background (window captures)
    var windowBackground: Backdrop.Fill { didSet { store.set(windowBackground.rawValue, forKey: "windowBackground") } }
    var backgroundPadding: Int { didSet { store.set(backgroundPadding, forKey: "backgroundPadding") } }

    // Advanced
    var fileNamePrefix: String { didSet { store.set(fileNamePrefix, forKey: "fileNamePrefix") } }
    /// Days the capture history keeps; 0 = keeps nothing, -1 = forever.
    var historyDays: Int { didSet { store.set(historyDays, forKey: "historyDays") } }

    // Shortcuts
    var shortcuts: [HotAction: Shortcut] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            store.set(try? JSONEncoder().encode(raw), forKey: "shortcuts")
            Hotkeys.shared.registerAll()
        }
    }

    func reset() {
        for key in Prefs.keys { store.removeObject(forKey: key) }
        let fresh = Prefs(store: store)
        saveFolder = fresh.saveFolder; afterShowQuickAccess = fresh.afterShowQuickAccess; afterCopy = fresh.afterCopy
        afterSave = fresh.afterSave; afterOpenEditor = fresh.afterOpenEditor; afterPin = fresh.afterPin
        playSound = fresh.playSound; imageFormat = fresh.imageFormat; downscaleRetina = fresh.downscaleRetina
        windowShadow = fresh.windowShadow; freezeScreen = fresh.freezeScreen; showMagnifier = fresh.showMagnifier
        showCrosshair = fresh.showCrosshair; hideIconsWhileCapturing = fresh.hideIconsWhileCapturing
        timerSeconds = fresh.timerSeconds; quickAccessRight = fresh.quickAccessRight
        quickAccessAutoClose = fresh.quickAccessAutoClose; recordGIF = fresh.recordGIF; recordFPS = fresh.recordFPS
        recordCursor = fresh.recordCursor; recordClicks = fresh.recordClicks; recordSystemAudio = fresh.recordSystemAudio
        recordMicrophone = fresh.recordMicrophone; recordRetina = fresh.recordRetina
        annotationColor = fresh.annotationColor; annotationWidth = fresh.annotationWidth
        windowBackground = fresh.windowBackground; backgroundPadding = fresh.backgroundPadding
        fileNamePrefix = fresh.fileNamePrefix; historyDays = fresh.historyDays; shortcuts = fresh.shortcuts
    }
}

extension Prefs {
    static let keys = ["saveFolder", "afterShowQuickAccess", "afterCopy", "afterSave", "afterOpenEditor", "afterPin",
                       "playSound", "imageFormat", "downscaleRetina", "windowShadow", "freezeScreen", "showMagnifier",
                       "showCrosshair", "hideIconsWhileCapturing", "timerSeconds", "quickAccessRight", "quickAccessAutoClose",
                       "recordGIF", "recordFPS", "recordCursor", "recordClicks", "recordSystemAudio", "recordMicrophone",
                       "recordRetina", "annotationColor", "annotationWidth", "windowBackground", "backgroundPadding",
                       "fileNamePrefix", "historyDays", "shortcuts"]
}

extension Dictionary {
    func compactMapKeys<T: Hashable>(_ f: (Key) -> T?) -> [T: Value] {
        var out: [T: Value] = [:]
        for (k, v) in self { if let nk = f(k) { out[nk] = v } }
        return out
    }
}

// MARK: - Global actions and their shortcuts

enum HotAction: String, CaseIterable, Codable {
    case area, previousArea, fullscreen, window, scrolling, text, recordVideo, recordGIF, timer, toggleIcons, history

    var title: String {
        switch self {
        case .area: return L("Capture Area")
        case .previousArea: return L("Capture Previous Area")
        case .fullscreen: return L("Capture Entire Screen")
        case .window: return L("Capture Window")
        case .scrolling: return L("Capture Scrolling Area")
        case .text: return L("Capture Text")
        case .recordVideo: return L("Record Screen")
        case .recordGIF: return L("Record GIF")
        case .timer: return L("Capture with Timer")
        case .toggleIcons: return L("Hide Desktop Icons")
        case .history: return L("Open History")
        }
    }

    var icon: String {
        switch self {
        case .area: return "crosshair"
        case .previousArea: return "refresh"
        case .fullscreen: return "device-desktop"
        case .window: return "app-window"
        case .scrolling: return "arrow-autofit-height"
        case .text: return "text-recognition"
        case .recordVideo: return "video"
        case .recordGIF: return "gif"
        case .timer: return "clock-hour-4"
        case .toggleIcons: return "eye-off"
        case .history: return "history"
        }
    }
}

/// A key plus Carbon modifiers (cmdKey, shiftKey, optionKey, controlKey).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let hyper = UInt32(cmdKey | shiftKey | optionKey)
    /// ⌥⇧⌘ plus a digit: free in macOS (which keeps ⇧⌘3–6 for its own capture) and in common apps.
    static let defaults: [HotAction: Shortcut] = [
        .area: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: hyper),
        .previousArea: .init(keyCode: UInt32(kVK_ANSI_2), modifiers: hyper),
        .fullscreen: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: hyper),
        .window: .init(keyCode: UInt32(kVK_ANSI_5), modifiers: hyper),
        .scrolling: .init(keyCode: UInt32(kVK_ANSI_6), modifiers: hyper),
        .text: .init(keyCode: UInt32(kVK_ANSI_7), modifiers: hyper),
        .recordVideo: .init(keyCode: UInt32(kVK_ANSI_8), modifiers: hyper),
        .recordGIF: .init(keyCode: UInt32(kVK_ANSI_9), modifiers: hyper),
    ]

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    /// For NSMenuItem.keyEquivalent.
    var menuKey: String { Shortcut.keyName(keyCode).lowercased() }
    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        let named: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: L("Space"), kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let n = named[Int(code)] { return n }
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        ]
        return letters[Int(code)] ?? "#\(code)"
    }
}
