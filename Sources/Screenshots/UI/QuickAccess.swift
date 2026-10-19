import AppKit
import SwiftUI

/// The thumbnails that appear in a corner after each capture: copy, save, annotate, pin,
/// drag out, delete. Newest at the bottom; at most five.
@MainActor
@Observable
final class QuickAccess {
    static let shared = QuickAccess()
    private(set) var ids: [UUID] = []
    @ObservationIgnored private var panels: [UUID: NSPanel] = [:]
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    /// Thumbnails the person moved: they stay where they were put.
    @ObservationIgnored private var moved: Set<UUID> = []
    var hovered: UUID? { didSet { if hovered == nil { ids.forEach(scheduleClose) } else { timers[hovered!]?.cancel() } } }
    /// Bumped when a capture changes (the editor saved over it).
    private(set) var revision = 0

    static let width: CGFloat = 240

    func show(_ c: Capture) {
        if ids.count >= 5, let oldest = ids.first { close(oldest) }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: QuickAccessCard(id: c.id))
        CaptureExclusion.add(p)
        panels[c.id] = p
        ids.append(c.id)
        layout(animated: false)
        p.orderFrontRegardless()
        scheduleClose(c.id)
    }

    func close(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        if let p = panels[id] { p.dispose(); DispatchQueue.main.async { Memory.trim() } }
        panels[id] = nil
        moved.remove(id)
        ids.removeAll { $0 == id }
        if hovered == id { hovered = nil }
        layout(animated: true)
    }

    func closeAll() { ids.forEach(close) }

    func refresh(_ id: UUID) {
        guard ids.contains(id) else { return }
        revision += 1
        layout(animated: false)
    }

    func panel(_ id: UUID) -> NSPanel? { panels[id] }

    /// One size for every thumbnail, 240 × 180 (4:3), whatever the capture: a tiny crop, a
    /// whole screen or a long scrolling page all sit whole inside it, centered on gray.1.
    static let height: CGFloat = 180
    static func height(for c: Capture?) -> CGFloat { height }

    private func layout(animated: Bool) {
        guard let screen = (Geometry.mouseScreen ?? NSScreen.main)?.visibleFrame else { return }
        var y = screen.minY + 16
        for id in ids.reversed() {
            guard let p = panels[id], !moved.contains(id) else { continue }
            let h = QuickAccess.height(for: Library.shared.item(id))
            let x = Prefs.shared.quickAccessRight ? screen.maxX - QuickAccess.width - 16 : screen.minX + 16
            let frame = CGRect(x: x, y: y, width: QuickAccess.width, height: h)
            if animated { p.animator().setFrame(frame, display: true) } else { p.setFrame(frame, display: true) }
            y += h + 12
        }
    }

    private func scheduleClose(_ id: UUID) {
        timers[id]?.cancel()
        let s = Prefs.shared.quickAccessAutoClose
        guard s > 0 else { return }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.hovered != id else { return }
            self.close(id)
        }
    }

    func markMoved(_ id: UUID) { moved.insert(id) }

    // MARK: actions (also called by the tests)

    func copy(_ id: UUID) {
        guard let c = Library.shared.item(id) else { return }
        Library.shared.copy(c)
        HUD.shared.toast(c.isImage ? L("Image copied") : L("File copied"))
        // Done with it: the thumbnail leaves the corner.
        close(id)
    }

    @discardableResult
    func save(_ id: UUID) -> URL? {
        guard let c = Library.shared.item(id), let url = Library.shared.save(c) else { return nil }
        HUD.shared.toast(L("Saved to %@", url.deletingLastPathComponent().lastPathComponent))
        close(id)
        return url
    }

    func annotate(_ id: UUID) {
        guard let c = Library.shared.item(id) else { return }
        if c.isImage {
            EditorWindow.show(capture: c)
            close(id)
        } else {
            NSWorkspace.shared.open(c.savedPath.map { URL(fileURLWithPath: $0) } ?? Library.shared.url(c))
        }
    }

    func pin(_ id: UUID) {
        guard let c = Library.shared.item(id), c.isImage, let img = Library.shared.image(c) else { return }
        PinWindow.show(image: img, scale: CGFloat(c.scale))
        close(id)
    }

    func delete(_ id: UUID) {
        guard let c = Library.shared.item(id) else { return }
        close(id)
        Library.shared.delete(c)
    }

    func dragURL(_ id: UUID) -> URL? {
        guard let c = Library.shared.item(id) else { return nil }
        if let saved = c.savedPath, FileManager.default.fileExists(atPath: saved) { return URL(fileURLWithPath: saved) }
        // A readable name for the file that lands in the other app.
        let ext = Library.shared.url(c).pathExtension
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent(Library.fileName(prefix: c.isImage ? Prefs.shared.fileNamePrefix : L("Recording"), date: c.date))
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: named)
        try? FileManager.default.copyItem(at: Library.shared.url(c), to: named)
        return named
    }
}

struct QuickAccessCard: View {
    let id: UUID
    var forceHover = false
    @State private var hoverState = false
    private var hover: Bool { hoverState || forceHover }

    var body: some View {
        let qa = QuickAccess.shared
        let c = Library.shared.item(id)
        let _ = qa.revision
        ZStack {
            Zen.gray1
            if let c, let thumb = Library.shared.thumbnail(c) {
                CardThumbnail(image: thumb, points: CGSize(width: CGFloat(c.width) / CGFloat(c.scale), height: CGFloat(c.height) / CGFloat(c.scale)))
            }
            if let c, !c.isImage, !hover {
                VStack {
                    Spacer()
                    HStack {
                        Text(c.kind == .gif ? "GIF" : L("Video")).zenLabel(9, color: .white)
                            .padding(.horizontal, 8).frame(height: 20).background(Zen.gray9)
                        Spacer()
                    }
                }
                .padding(8)
            }
            if hover, let c {
                Zen.gray9.opacity(0.62)
                VStack(spacing: 8) {
                    Button { qa.copy(id) } label: { Text(L("Copy")).frame(width: 96) }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                    Button { qa.save(id) } label: { Text(c.savedPath == nil ? L("Save") : L("Saved")).frame(width: 96) }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                }
                VStack {
                    HStack {
                        corner("x", L("Close")) { qa.close(id) }
                        Spacer()
                        GripHandle(vertical: false) { qa.markMoved(id) }
                            .frame(height: 26)
                            .background(Zen.gray0)
                        Spacer()
                        if c.isImage { corner("pencil", L("Annotate")) { qa.annotate(id) } }
                        else { corner("external-link", L("Open")) { qa.annotate(id) } }
                    }
                    Spacer()
                    HStack {
                        if c.isImage { corner("pin", L("Pin to screen")) { qa.pin(id) } }
                        Spacer()
                        corner("trash", L("Delete")) { qa.delete(id) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: QuickAccess.width, height: QuickAccess.height(for: c))
        .clipped()
        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in
            hoverState = h
            qa.hovered = h ? id : (qa.hovered == id ? nil : qa.hovered)
        }
        .onTapGesture(count: 2) { qa.annotate(id) }
        .onDrag {
            guard let url = qa.dragURL(id) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }

    private func corner(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 14, color: Zen.gray9)
                .frame(width: 26, height: 26)
                .background(Zen.gray0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// How a capture sits in the fixed 240 × 180 card:
///   - small ones at their real size, centered, never enlarged;
///   - ordinary shapes whole, fitted inside an 8 pt margin;
///   - very long pages (scrolling captures) fill the width and show their top, very wide
///     strips fill the height and show their left side, so they stay readable.
/// A 1 px gray.3 rule outlines the capture, so a white one does not melt into gray.1.
struct CardThumbnail: View {
    let image: NSImage
    let points: CGSize

    var body: some View {
        let box = CGSize(width: QuickAccess.width - 16, height: QuickAccess.height - 16)
        let aspect = points.width / max(points.height, 1)
        let boxAspect = box.width / box.height
        if aspect < boxAspect / 2.2 || aspect > boxAspect * 2.2 {
            let tall = aspect < boxAspect
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: tall ? box.width : nil, height: tall ? nil : box.height)
                .frame(width: box.width, height: box.height, alignment: tall ? .top : .leading)
                .clipped()
                .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
        } else {
            let s = min(1, box.width / max(points.width, 1), box.height / max(points.height, 1))
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: (points.width * s).rounded(), height: (points.height * s).rounded())
                .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
        }
    }
}
