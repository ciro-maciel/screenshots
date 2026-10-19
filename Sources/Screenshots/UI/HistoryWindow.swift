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
            MacPageHeader(crumb: "Screenshots", title: "Histórico", subtitle: subtitle)
            if library.items.isEmpty {
                VStack(spacing: 16) {
                    Illustration(name: "camera", size: 168)
                    Text("Nada por aqui ainda").zenLabel(11, color: Zen.gray5)
                    Text("Aperte ⌥⇧⌘4 e arraste uma área. Cada captura aparece aqui.")
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
        let span = d < 0 ? "sem prazo" : (d == 0 ? "até o app fechar" : (d == 1 ? "por 1 dia" : "por \(d) dias"))
        return "\(library.items.count) \(library.items.count == 1 ? "captura" : "capturas"), guardadas \(span). Ficam só neste Mac."
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
                        action(capture.isImage ? "pencil" : "external-link", capture.isImage ? "Anotar" : "Abrir") {
                            if capture.isImage { EditorWindow.show(capture: capture) }
                            else { NSWorkspace.shared.open(Library.shared.url(capture)) }
                        }
                        action("copy", "Copiar") { Library.shared.copy(capture); HUD.shared.toast("Copiada") }
                        if capture.isImage {
                            action("pin", "Fixar na tela") {
                                if let img = Library.shared.image(capture) { PinWindow.show(image: img, scale: CGFloat(capture.scale)) }
                            }
                        }
                        action("folder", "Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([capture.savedPath.map { URL(fileURLWithPath: $0) } ?? Library.shared.url(capture)])
                        }
                        action("trash", "Tirar do histórico") { Library.shared.delete(capture) }
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
                Text(capture.source + (capture.kind == .image ? "" : (capture.kind == .gif ? " · GIF" : " · Vídeo")))
                    .font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9)
                Text("\(capture.date.formatted(.relative(presentation: .named)))  ·  \(capture.width) × \(capture.height)")
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
