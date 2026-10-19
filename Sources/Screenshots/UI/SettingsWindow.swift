import AppKit
import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, background, shortcuts, quickAccess, recording, screenshots, annotate, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("General")
        case .background: return L("Background")
        case .shortcuts: return L("Shortcuts")
        case .quickAccess: return L("Quick Access")
        case .recording: return L("Recording")
        case .screenshots: return L("tab|Screenshots")
        case .annotate: return L("Annotation")
        case .advanced: return L("Advanced")
        }
    }
    var icon: String {
        switch self {
        case .general: return "settings"
        case .background: return "wallpaper"
        case .shortcuts: return "keyboard"
        case .quickAccess: return "layout-dashboard"
        case .recording: return "video"
        case .screenshots: return "camera"
        case .annotate: return "pencil"
        case .advanced: return "adjustments"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("What happens when your Mac starts up and right after each capture, and the folder where the files go.")
        case .background: return L("A background behind window captures, so the image is ready to send.")
        case .shortcuts: return L("Shortcuts that work in any app, set the way you like.")
        case .quickAccess: return L("The thumbnail that appears in the corner after a capture.")
        case .recording: return L("Format, quality and what goes into a screen recording.")
        case .screenshots: return L("The file each capture makes and how area selection behaves.")
        case .annotate: return L("The color and stroke the editor opens with, and its shortcuts.")
        case .advanced: return L("File names, how long the history keeps captures, and going back to the defaults.")
        }
    }
}

/// The one window of the app (the macOS app frame of the Zen design system, shared with Cleaner): the history and
/// every settings pane in the sidebar. SettingsWindow and HistoryWindow open it on their pane.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static var current: NSWindow? { window }
    static let model = SettingsModel()

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        model.section = .settings
        open()
    }

    static func open() {
        Stage.activate()
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = MacShell.window(title: "Screenshots", size: CGSize(width: 1120, height: 780),
                                minSize: CGSize(width: 980, height: 720), autosave: "ScreenshotsMain",
                                root: SettingsView(model: model, prefs: Prefs.shared, library: Library.shared))
        w.delegate = closer
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// A closed window is gone for good: its views, the history cards and their thumbnails go
    /// with it, and the next open builds a fresh one.
    private static let closer = Closer()
    final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let w = SettingsWindow.window else { return }
                SettingsWindow.window = nil
                DispatchQueue.main.async {
                    w.contentView = nil
                    Memory.trim()
                }
            }
        }
    }
}

@MainActor
@Observable
final class SettingsModel {
    enum Section { case history, settings }
    var section: Section = .settings
    var tab: SettingsTab = .general { didSet { section = .settings } }
    var recording: HotAction?
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var prefs: Prefs
    let library: Library
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        MacShellView {
            MacSidebar(app: "Screenshots") {
                MacSidebarGroup(title: L("Captures")) {
                    MacSidebarItem(icon: "history", title: L("History"),
                                   badge: library.items.isEmpty ? nil : "\(library.items.count)",
                                   active: model.section == .history) { model.section = .history }
                }
                MacSidebarGroup(title: L("Settings")) {
                    ForEach(SettingsTab.allCases) { t in
                        MacSidebarItem(icon: t.icon, title: t.title, active: model.section == .settings && model.tab == t) { model.tab = t }
                    }
                }
            } status: {
                MacStatusLine(on: ScreenGrabber.hasPermission, onText: L("Screen Recording on"), offText: L("Screen Recording off")) {
                    WelcomeWindow.show()
                }
            }
        } content: {
            switch model.section {
            case .history: HistoryView(library: library)
            case .settings:
                MacPage {
                    MacPageHeader(crumb: "Screenshots", title: model.tab.title, subtitle: model.tab.subtitle)
                    content
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .general: general
        case .background: background
        case .shortcuts: shortcuts
        case .quickAccess: quickAccess
        case .recording: recording
        case .screenshots: screenshots
        case .annotate: annotate
        case .advanced: advanced
        }
    }

    // MARK: tabs

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Startup")) {
                ZenToggle(title: L("Open Screenshots at login"), detail: L("It waits in the menu bar, ready for the first shortcut."),
                          isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                ZenToggle(title: L("Play the capture sound"), isOn: $prefs.playSound)
            }
            .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
            SettingsSection(title: L("After Capture")) {
                ZenToggle(title: L("Show Quick Access"), detail: L("The thumbnail in the corner, with copy, save, annotate and pin."), isOn: $prefs.afterShowQuickAccess)
                ZenToggle(title: L("Copy the image"), isOn: $prefs.afterCopy)
                ZenToggle(title: L("Save to the folder"), isOn: $prefs.afterSave)
                ZenToggle(title: L("Open the annotation editor"), isOn: $prefs.afterOpenEditor)
                ZenToggle(title: L("Pin to screen"), isOn: $prefs.afterPin)
            }
            SettingsSection(title: L("Folder")) {
                HStack(spacing: 12) {
                    Icon(name: "folder", size: 16, color: Zen.gray6)
                    Text(prefs.saveFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .zenData(13, color: Zen.gray9).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { chooseFolder() } label: { Text(L("Choose")) }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: prefs.saveFolder)) } label: { Text(L("Open")) }
                        .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
                }
            }
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Window Captures"), note: L("The background goes on window captures only. In the editor, any image gets one from the Background button.")) {
                ZenSegmented(options: Backdrop.Fill.allCases.map { ($0, $0.title) }, selection: $prefs.windowBackground)
                HStack(spacing: 12) {
                    Text(L("Padding")).zenData(13, color: Zen.gray6)
                    Slider(value: Binding(get: { Double(prefs.backgroundPadding) }, set: { prefs.backgroundPadding = Int($0.rounded()) }), in: 8...200)
                        .frame(width: 260)
                        .disabled(prefs.windowBackground == .none)
                    Text("\(prefs.backgroundPadding) pt").zenData(13, color: Zen.gray7).monospacedDigit()
                }
            }
            SettingsSection(title: L("Preview")) {
                BackdropPreview(fill: prefs.windowBackground, padding: CGFloat(prefs.backgroundPadding))
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Keyboard Shortcuts"), note: L("They work in any app. Click a shortcut and press the new combination; Esc cancels, ⌫ clears it.")) {
                VStack(spacing: 0) {
                    ForEach(HotAction.allCases, id: \.self) { a in
                        HStack(spacing: 12) {
                            Icon(name: a.icon, size: 16, color: Zen.gray6)
                            Text(a.title).zenData(13, color: Zen.gray9)
                            Spacer()
                            if Hotkeys.shared.failed.contains(a) {
                                Text(L("In use by another app")).zenData(11, color: Zen.red7)
                            }
                            ShortcutField(action: a, model: model, prefs: prefs)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Zen.gray2).frame(height: 1) }
                    }
                }
                Button { prefs.shortcuts = Shortcut.defaults } label: { ButtonLabel(title: L("Restore Defaults"), icon: "refresh") }
                    .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
            }
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Position")) {
                ZenSegmented(options: [(false, L("Left corner")), (true, L("Right corner"))], selection: $prefs.quickAccessRight)
            }
            SettingsSection(title: L("Close Automatically"), note: L("While the pointer is over it, the thumbnail waits.")) {
                ZenSegmented(options: [(0, L("Never")), (5, "5 s"), (10, "10 s"), (30, "30 s"), (60, "1 min")], selection: $prefs.quickAccessAutoClose)
            }
            SettingsSection(title: L("On the Thumbnail")) {
                VStack(alignment: .leading, spacing: 8) {
                    help(L("Double-click"), L("opens the editor"))
                    help(L("Drag"), L("takes the file to another app (Mail, Slack, Finder)"))
                    help(L("Copy and Save"), L("in the middle, and the thumbnail leaves the corner; in the corners, close, annotate, pin and delete"))
                }
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Format")) {
                ZenSegmented(options: [(false, L("MP4 Video")), (true, "GIF")], selection: $prefs.recordGIF)
                ZenSegmented(options: [(30, L("30 fps")), (60, L("60 fps"))], selection: $prefs.recordFPS)
                ZenToggle(title: L("Record at Retina resolution"), detail: L("Twice the pixels on Retina displays; when off, the file is smaller."), isOn: $prefs.recordRetina)
            }
            SettingsSection(title: L("In the Recording")) {
                ZenToggle(title: L("Show the pointer"), isOn: $prefs.recordCursor)
                ZenToggle(title: L("Show clicks"), detail: L("A ring where the mouse clicks."), isOn: $prefs.recordClicks)
                ZenToggle(title: L("Record the computer's sound"), isOn: $prefs.recordSystemAudio)
                if #available(macOS 15.0, *) {
                    ZenToggle(title: L("Record the microphone"), isOn: $prefs.recordMicrophone)
                }
            }
        }
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("File")) {
                ZenSegmented(options: [(Prefs.ImageFormat.png, "PNG"), (.jpeg, "JPEG")], selection: $prefs.imageFormat)
                ZenToggle(title: L("Save at 1× on Retina displays"), detail: L("Half the pixels: smaller files, less crisp text."), isOn: $prefs.downscaleRetina)
            }
            SettingsSection(title: L("Area Selection")) {
                ZenToggle(title: L("Freeze the screen while selecting"), detail: L("Anything that moves (video, menus) holds still until you choose."), isOn: $prefs.freezeScreen)
                ZenToggle(title: L("Show the magnifier"), isOn: $prefs.showMagnifier)
                ZenToggle(title: L("Show the crosshair"), isOn: $prefs.showCrosshair)
                ZenToggle(title: L("Hide desktop icons while capturing"), isOn: $prefs.hideIconsWhileCapturing)
            }
            SettingsSection(title: L("Window")) {
                ZenToggle(title: L("Capture the window shadow"), isOn: $prefs.windowShadow)
            }
            SettingsSection(title: L("Timer")) {
                ZenSegmented(options: [(3, "3 s"), (5, "5 s"), (10, "10 s")], selection: $prefs.timerSeconds)
            }
        }
    }

    private var annotate: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("Starting Color")) {
                HStack(spacing: 8) {
                    ForEach(Array(Palette.colors.enumerated()), id: \.offset) { i, c in
                        Button { prefs.annotationColor = i } label: {
                            Rectangle().fill(Color(nsColor: c.color)).frame(width: 22, height: 22)
                                .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                                .padding(3)
                                .overlay(Rectangle().strokeBorder(prefs.annotationColor == i ? Zen.gray9 : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(L(c.name))
                    }
                }
            }
            SettingsSection(title: L("Starting Stroke")) {
                ZenSegmented(options: [(0, L("settings|Thin")), (1, L("settings|Medium")), (2, L("settings|Thick"))], selection: $prefs.annotationWidth)
            }
            SettingsSection(title: L("Editor Shortcuts")) {
                VStack(alignment: .leading, spacing: 8) {
                    help("V C A L R F O T P H N B S", L("switch tools"))
                    help("Shift", L("holds lines at 45° and shapes square"))
                    help(L("⌘Z and ⇧⌘Z"), L("undo and redo; ⌫ deletes the selection"))
                    help(L("⌘C, ⌘S, ⇧⌘S and ⌘P"), L("copy, save, save as and pin to screen"))
                }
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: L("File Name"), note: L("Example: %@", "\(Library.fileName(prefix: prefs.fileNamePrefix, date: Date())).\(prefs.imageFormat.ext)")) {
                TextField(L("Screenshot"), text: $prefs.fileNamePrefix)
                    .textFieldStyle(.plain)
                    .font(Zen.font(14, .medium))
                    .frame(width: 280)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Zen.gray3).frame(height: 1) }
            }
            SettingsSection(title: L("History"), note: L("A copy of each capture stays in the history, on this Mac only.")) {
                ZenSegmented(options: [(0, L("Don't keep")), (1, L("1 day")), (7, L("1 week")), (30, L("1 month")), (-1, L("Forever"))], selection: $prefs.historyDays)
                HStack(spacing: 12) {
                    Button { HistoryWindow.show() } label: { ButtonLabel(title: L("Open History"), icon: "history") }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                    HoldButton(title: L("Clear History"), kind: .danger, height: 30) {
                        Library.shared.clear()
                        HUD.shared.toast(L("History cleared"))
                    }
                }
            }
            SettingsSection(title: L("Settings")) {
                HoldButton(title: L("Reset All Settings"), icon: "refresh", kind: .secondary, height: 30) {
                    prefs.reset()
                    HUD.shared.toast(L("Settings back to defaults"))
                }
            }
        }
    }

    // MARK: pieces

    private func help(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(Zen.font(12, .bold)).foregroundStyle(Zen.gray9)
            Text(text).zenData(12, color: Zen.gray6)
        }
    }

    /// Reads the status back from the system after every change, so the box shows what macOS did, not what was clicked.
    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Screenshots: login item: \(error)")
        }
        let status = SMAppService.mainApp.status
        if on && status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = status == .enabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.saveFolder)
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { prefs.saveFolder = url.path }
    }
}

/// A titled block of settings: label 10/800, rows 13/500, 28 between blocks.
struct SettingsSection<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).zenLabel(10, color: Zen.gray5)
            content
            if let note { Text(note).zenData(12, color: Zen.gray5).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small window drawn over the chosen backdrop.
struct BackdropPreview: View {
    let fill: Backdrop.Fill
    let padding: CGFloat
    var body: some View {
        let pad = fill == .none ? 0 : padding / 4
        ZStack {
            switch fill {
            case .none: Color.clear
            case .white: Color.white
            case .gray: Zen.gray3
            case .black: Zen.gray9
            case .wallpaper:
                if let screen = NSScreen.main, let img = DesktopIcons.wallpaper(for: screen) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { Zen.gray3 }
            }
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Zen.gray3).frame(width: 7, height: 7) }
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 18).background(Zen.gray1)
                Rectangle().fill(Zen.gray0)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle().fill(Zen.gray3).frame(width: 120, height: 8)
                            Rectangle().fill(Zen.gray2).frame(width: 180, height: 6)
                            Rectangle().fill(Zen.gray2).frame(width: 150, height: 6)
                        }
                        .padding(12)
                    }
            }
            .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
            .padding(pad)
        }
        .frame(width: 320, height: 200)
        .clipped()
        .overlay(Rectangle().strokeBorder(Zen.gray2, lineWidth: 1))
    }
}

/// Click, then press the new combination.
struct ShortcutField: View {
    let action: HotAction
    let model: SettingsModel
    @Bindable var prefs: Prefs
    @State private var monitor: Any?

    var body: some View {
        let recording = model.recording == action
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Press the shortcut…") : (prefs.shortcuts[action]?.display ?? L("No shortcut")))
                .font(Zen.font(12, recording ? .bold : .medium))
                .foregroundStyle(recording ? Color.white : (prefs.shortcuts[action] == nil ? Zen.gray4 : Zen.gray9))
                .frame(width: 140, height: 28)
                .background(recording ? Zen.gray9 : Zen.gray1)
                .overlay(Rectangle().strokeBorder(recording ? Zen.gray9 : Zen.gray3, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        if model.recording != nil { return }
        model.recording = action
        Hotkeys.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop()
            case 51, 117:
                prefs.shortcuts[action] = nil
                stop()
            default:
                if let sc = Shortcut(event: event) {
                    // One action per combination: the old owner loses it.
                    for (k, v) in prefs.shortcuts where v == sc && k != action { prefs.shortcuts[k] = nil }
                    prefs.shortcuts[action] = sc
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.recording == action { model.recording = nil }
        Hotkeys.shared.paused = false
    }
}
