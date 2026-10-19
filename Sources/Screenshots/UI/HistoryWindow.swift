import AppKit
import SwiftUI

/// Every capture kept on this Mac, newest first: a pane of the app window.
@MainActor
enum HistoryWindow {
    static var current: NSWindow? { SettingsWindow.current }

    static func show() {
        SettingsWindow.model.section = .history
        SettingsWindow.open()
    }
}

struct HistoryView: View {
    let library: Library

    var body: some View {
        MacPage {
            MacPageHeader(crumb: "Screenshots", title: L("History"), subtitle: subtitle)
            if library.items.isEmpty {
                VStack(spacing: 16) {
                    Illustration(name: "camera", size: 168)
                    Text(L("Nothing here yet")).zenLabel(11, color: Zen.gray5)
                    Text(L("Press ⌥⇧⌘4 and drag over an area. Every capture shows up here."))
                        .zenBody(14).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
                    ForEach(library.items) { c in HistoryCard(capture: c) }
                }
            }
        }
    }

    private var subtitle: String {
        let d = Prefs.shared.historyDays
        let span = d < 0 ? L("with no time limit") : (d == 0 ? L("until the app quits") : (d == 1 ? L("for 1 day") : L("for %d days", d)))
        let n = library.items.count
        return L("%@, kept %@. They stay on this Mac only.", n == 1 ? L("1 capture") : L("%d captures", n), span)
    }
}

struct HistoryCard: View {
    let capture: Capture
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Zen.gray1
                if let t = Library.shared.thumbnail(capture) {
                    Image(nsImage: t).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
                }
                if hover {
                    Zen.gray9.opacity(0.55)
                    HStack(spacing: 6) {
                        action(capture.isImage ? "pencil" : "external-link", capture.isImage ? L("Annotate") : L("Open")) {
                            if capture.isImage { EditorWindow.show(capture: capture) }
                            else { NSWorkspace.shared.open(Library.shared.url(capture)) }
                        }
                        action("copy", L("Copy")) { Library.shared.copy(capture); HUD.shared.toast(L("Copied")) }
                        if capture.isImage {
                            action("pin", L("Pin to screen")) {
                                if let img = Library.shared.image(capture) { PinWindow.show(image: img, scale: CGFloat(capture.scale)) }
                            }
                        }
                        action("folder", L("Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([capture.savedPath.map { URL(fileURLWithPath: $0) } ?? Library.shared.url(capture)])
                        }
                        action("trash", L("Remove from History")) { Library.shared.delete(capture) }
                    }
                }
            }
            .frame(height: 150)
            .clipped()
            .onTapGesture(count: 2) { if capture.isImage { EditorWindow.show(capture: capture) } }
            .onDrag {
                NSItemProvider(contentsOf: capture.savedPath.map { URL(fileURLWithPath: $0) } ?? Library.shared.url(capture)) ?? NSItemProvider()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.sourceTitle + (capture.kind == .image ? "" : (capture.kind == .gif ? " · GIF" : " · " + L("Video"))))
                    .font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9)
                Text("\(capture.date.formatted(.relative(presentation: .named).locale(L10n.locale)))  ·  \(capture.width) × \(capture.height)")
                    .zenData(12, color: Zen.gray5)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Zen.gray2).frame(height: 1) }
        }
        .background(Zen.gray0)
        .zenBorder()
        .onHover { hover = $0 }
    }

    private func action(_ icon: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Icon(name: icon, size: 15, color: Zen.gray9)
                .frame(width: 30, height: 30)
                .background(Zen.gray0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
