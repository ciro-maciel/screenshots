import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The annotation window. One per open image.
@MainActor
final class EditorWindow: NSWindow, NSWindowDelegate {
    static private(set) var open: [EditorWindow] = []
    let model: EditorModel
    let canvas: CanvasView

    static func show(image: CGImage, scale: CGFloat, captureID: UUID? = nil, backdrop: Backdrop? = nil) {
        let w = EditorWindow(model: EditorModel(base: image, scale: scale, captureID: captureID, backdrop: backdrop))
        open.append(w)
        Stage.activate()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(w.canvas)
    }

    static func show(capture c: Capture) {
        if let existing = open.first(where: { $0.model.captureID == c.id }) {
            Stage.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard c.isImage, let img = Library.shared.image(c) else { return }
        show(image: img, scale: CGFloat(c.scale), captureID: c.id)
    }

    init(model: EditorModel) {
        self.model = model
        canvas = CanvasView(model: model)
        let screen = (Geometry.mouseScreen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pts = CGSize(width: CGFloat(model.base.width) / model.scale, height: CGFloat(model.base.height) / model.scale)
        let w = min(max(pts.width + 64, 860), screen.width * 0.86)
        let h = min(max(pts.height + 64 + 52 + 56 + 28, 580), screen.height * 0.86)
        super.init(contentRect: CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Screenshots"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = CGSize(width: 860, height: 580)
        delegate = self
        contentView = NSHostingView(rootView: EditorView(model: model, canvas: canvas, window: self))
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitText()
        EditorWindow.open.removeAll { $0 === self }
        // The SwiftUI tree holds the model, the canvas and its cached render: let them go.
        DispatchQueue.main.async { self.contentView = nil; Memory.trim() }
    }

    // The app has no menu bar (it lives in the status bar), so the editor's shortcuts are here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if canvas.isEditingText, flags == .command, ["c", "v", "x", "a"].contains(key) {
            return super.performKeyEquivalent(with: event)
        }
        switch (flags, key) {
        case (.command, "z"): model.undo(); canvas.refresh(); return true
        case ([.command, .shift], "z"): model.redo(); canvas.refresh(); return true
        case (.command, "c"): copyAndClose(); return true
        case (.command, "s"): saveAndClose(); return true
        case ([.command, .shift], "s"): saveAs(); return true
        case (.command, "w"): performClose(nil); return true
        case (.command, "p"): pinImage(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: actions

    func finished() -> CGImage? {
        canvas.commitText()
        return model.export()
    }

    func copyImage() {
        guard let img = finished() else { return }
        let pb = Stage.board
        pb.clearContents()
        Library.put(img, scale: model.scale, on: pb)
        HUD.shared.toast(L("Image copied"))
    }

    /// Copy and Save are the end of an edit: the image goes out and the editor closes.
    func copyAndClose() {
        guard finished() != nil else { return }
        copyImage()
        close()
    }

    func saveAndClose() {
        if saveImage() != nil { close() }
    }

    /// Replaces the capture in the history and writes the file in the chosen folder.
    @discardableResult
    func saveImage() -> URL? {
        guard let img = finished() else { return nil }
        let lib = Library.shared
        var capture: Capture
        if let id = model.captureID, let c = lib.item(id) {
            capture = lib.replace(c, with: img)
        } else {
            capture = lib.add(image: img, scale: model.scale, source: "editor")
            model.captureID = capture.id
        }
        guard let url = lib.save(capture) else { return nil }
        QuickAccess.shared.refresh(capture.id)
        HUD.shared.toast(L("Saved to %@", url.deletingLastPathComponent().lastPathComponent))
        return url
    }

    func saveAs() {
        guard let img = finished() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = Library.fileName(prefix: Prefs.shared.fileNamePrefix, date: Date()) + ".png"
        panel.directoryURL = URL(fileURLWithPath: Prefs.shared.saveFolder)
        panel.beginSheetModal(for: self) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let format: Prefs.ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            do {
                try Library.encode(img, format: format, scale: self.model.scale, downscale: Prefs.shared.downscaleRetina).write(to: url)
                HUD.shared.toast(L("Saved to %@", url.deletingLastPathComponent().lastPathComponent))
            } catch {
                HUD.shared.toast(L("Couldn't save."), error: true)
            }
        }
    }

    func pinImage() {
        guard let img = finished() else { return }
        PinWindow.show(image: img, scale: model.scale)
    }

    /// A file for dragging the image into another app.
    func dragFile() -> URL? {
        guard let img = finished() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Library.fileName(prefix: Prefs.shared.fileNamePrefix, date: Date()))
            .appendingPathExtension("png")
        try? Library.encode(img, format: .png, scale: model.scale, downscale: false).write(to: url)
        return url
    }
}

// MARK: - SwiftUI around the canvas

struct CanvasRepresentable: NSViewRepresentable {
    let canvas: CanvasView
    let revision: Int
    let tool: Tool
    let selected: UUID?
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ v: CanvasView, context: Context) {
        v.refresh()
        v.window?.invalidateCursorRects(for: v)
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    let canvas: CanvasView
    weak var window: EditorWindow?
    @State private var showBackdrop = false

    private static let drawingTools: [Tool] = [.arrow, .line, .rect, .filledRect, .ellipse, .text, .pencil, .highlighter, .counter, .blur, .spotlight]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            CanvasRepresentable(canvas: canvas, revision: model.revision, tool: model.tool, selected: model.selectedID)
            footer
        }
        .background(Zen.gray0)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 84, height: 1)
            tool(.select)
            tool(.crop)
            divider
            ForEach(Self.drawingTools, id: \.self) { tool($0) }
            divider
            HStack(spacing: 6) {
                ForEach(Array(Palette.colors.enumerated()), id: \.offset) { i, c in
                    Button { model.colorIndex = i } label: {
                        Rectangle().fill(Color(nsColor: c.color))
                            .frame(width: 16, height: 16)
                            .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                            .padding(3)
                            .overlay(Rectangle().strokeBorder(model.colorIndex == i ? Zen.gray9 : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L(c.name))
                }
            }
            divider
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Button { model.widthIndex = i } label: {
                        Icon(name: "circle-filled", size: [8, 12, 16][i], color: model.widthIndex == i ? .white : Zen.gray7)
                            .frame(width: 28, height: 28)
                            .background(model.widthIndex == i ? Zen.gray9 : Color.clear, ignoresSafeAreaEdges: [])
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L(["Thin", "Medium", "Thick"][i]))
                }
            }
            Spacer(minLength: 8)
            IconButton(icon: "arrow-back-up", help: L("Undo (⌘Z)")) { model.undo(); canvas.refresh() }
                .disabled(!model.canUndo)
            IconButton(icon: "arrow-forward-up", help: L("Redo (⇧⌘Z)")) { model.redo(); canvas.refresh() }
                .disabled(!model.canRedo)
            divider
            IconButton(icon: "background", help: L("Background"), active: showBackdrop || model.state.backdrop.fill != .none) { showBackdrop.toggle() }
                .popover(isPresented: $showBackdrop, arrowEdge: .bottom) { BackdropPanel(model: model) }
            IconButton(icon: "trash", help: L("Delete Selection (⌫)")) { model.deleteSelection(); canvas.refresh() }
                .disabled(model.selectedID == nil)
                .padding(.trailing, 12)
        }
        .frame(height: 52)
        .background(WindowDragArea())
        .background(Zen.gray0)
        .overlay(alignment: .bottom) { Rectangle().fill(Zen.gray2).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let size = Renderer.contentRect(base: model.base, state: model.state).size
            Text("\(Int(size.width / model.scale)) × \(Int(size.height / model.scale))")
                .zenData(12, color: Zen.gray5).monospacedDigit()
            if model.state.crop != nil {
                Button { model.setCrop(nil); canvas.refresh() } label: { ButtonLabel(title: L("Undo Crop"), icon: "crop") }
                    .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
            }
            Spacer()
            dragHandle
            Button { window?.pinImage() } label: { ButtonLabel(title: L("Pin"), icon: "pin") }
                .buttonStyle(ZenButtonStyle(kind: .subtle, height: 32))
                .help(L("Pin to screen, above other windows (⌘P)"))
            Button { window?.saveAs() } label: { ButtonLabel(title: L("Save As"), icon: "download") }
                .buttonStyle(ZenButtonStyle(kind: .subtle, height: 32))
            Button { window?.copyAndClose() } label: { ButtonLabel(title: L("Copy"), icon: "copy") }
                .buttonStyle(ZenButtonStyle(kind: .secondary, height: 32))
                .help("⌘C")
            Button { window?.saveAndClose() } label: { ButtonLabel(title: L("Save"), icon: "device-floppy", color: .white) }
                .buttonStyle(ZenButtonStyle(kind: .primary, height: 32))
                .help("⌘S")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Zen.gray0)
        .overlay(alignment: .top) { Rectangle().fill(Zen.gray2).frame(height: 1) }
    }

    private var dragHandle: some View {
        HStack(spacing: 8) {
            Icon(name: "drag-drop", size: 14, color: Zen.gray9)
            Text(L("Drag"))
        }
        .font(Zen.font(11, .extraBold)).tracking(1).textCase(.uppercase)
        .foregroundStyle(Zen.gray9)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onDrag {
            guard let url = window?.dragFile() else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help(L("Drag the image into another app"))
    }

    private func tool(_ t: Tool) -> some View {
        IconButton(icon: t.icon, help: t.title, size: 18, frame: 32, active: model.tool == t) {
            canvas.commitText()
            model.tool = t
            canvas.refresh()
            canvas.window?.makeFirstResponder(canvas)
        }
    }

    private var divider: some View { Rectangle().fill(Zen.gray2).frame(width: 1, height: 24).padding(.horizontal, 6) }
}

struct BackdropPanel: View {
    let model: EditorModel
    var body: some View {
        let b = model.state.backdrop
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Background")).zenLabel(10, color: Zen.gray5)
            ZenSegmented(options: Backdrop.Fill.allCases.map { ($0, $0.title) },
                         selection: Binding(get: { b.fill }, set: { var n = b; n.fill = $0; model.setBackdrop(n) }))
            HStack(spacing: 12) {
                Text(L("Padding")).zenData(12, color: Zen.gray6)
                Slider(value: Binding(get: { Double(b.padding) }, set: { var n = b; n.padding = CGFloat($0.rounded()); model.setBackdrop(n) }),
                       in: 8...200)
                    .frame(width: 220)
                    .disabled(b.fill == .none)
                Text("\(Int(b.padding)) pt").zenData(12, color: Zen.gray7).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
        .padding(18)
        .background(Zen.gray0)
    }
}
