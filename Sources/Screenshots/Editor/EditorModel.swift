import AppKit
import SwiftUI

enum Tool: String, CaseIterable {
    case select, crop, arrow, line, rect, filledRect, ellipse, text, pencil, highlighter, counter, blur, spotlight

    var title: String {
        switch self {
        case .select: return L("Select and Move (V)")
        case .crop: return L("Crop (C)")
        case .arrow: return L("Arrow (A)")
        case .line: return L("Line (L)")
        case .rect: return L("Rectangle (R)")
        case .filledRect: return L("Filled Rectangle (F)")
        case .ellipse: return L("Ellipse (O)")
        case .text: return L("Text (T)")
        case .pencil: return L("Pencil (P)")
        case .highlighter: return L("Highlighter (H)")
        case .counter: return L("Counter (N)")
        case .blur: return L("Blur (B)")
        case .spotlight: return L("Spotlight (S)")
        }
    }
    var icon: String {
        switch self {
        case .select: return "pointer"
        case .crop: return "crop"
        case .arrow: return "arrow-up-right"
        case .line: return "slash"
        case .rect: return "square"
        case .filledRect: return "square-filled"
        case .ellipse: return "circle"
        case .text: return "typography"
        case .pencil: return "pencil"
        case .highlighter: return "highlight"
        case .counter: return "circle-number-1"
        case .blur: return "blur"
        case .spotlight: return "focus-2"
        }
    }
    var key: Character {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .filledRect: return "f"
        case .ellipse: return "o"
        case .text: return "t"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .counter: return "n"
        case .blur: return "b"
        case .spotlight: return "s"
        }
    }
    var kind: Annotation.Kind? { Annotation.Kind(rawValue: rawValue) }
}

/// One open image in the editor: the base pixels, what was drawn on them, and the history.
@MainActor
@Observable
final class EditorModel {
    let base: CGImage
    let scale: CGFloat
    var captureID: UUID?
    private(set) var state: EditorState
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    var tool: Tool = .arrow { didSet { if tool != .select { selectedID = nil } } }
    var colorIndex: Int { didSet { Prefs.shared.annotationColor = colorIndex; recolorSelection() } }
    var widthIndex: Int { didSet { Prefs.shared.annotationWidth = widthIndex; rewidthSelection() } }
    var selectedID: UUID?
    var wallpaper: CGImage?
    /// Annotations left out of the canvas while their text is being edited.
    var hiddenIDs: Set<UUID> = [] { didSet { revision += 1 } }
    /// Bumped on every change; the canvas redraws from it.
    private(set) var revision = 0

    init(base: CGImage, scale: CGFloat, captureID: UUID? = nil, backdrop: Backdrop? = nil) {
        self.base = base
        self.scale = max(1, scale)
        self.captureID = captureID
        colorIndex = Prefs.shared.annotationColor
        widthIndex = Prefs.shared.annotationWidth
        state = EditorState(backdrop: backdrop ?? Backdrop(fill: .none, padding: CGFloat(Prefs.shared.backgroundPadding)))
        if state.backdrop.fill == .wallpaper { loadWallpaper() }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var strokeWidth: CGFloat { Palette.widths[widthIndex] * scale }
    var fontSize: CGFloat { Palette.textSizes[widthIndex] * scale }

    func commit(_ change: (inout EditorState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        state = next
        revision += 1
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
        if let s = selectedID, !state.annotations.contains(where: { $0.id == s }) { selectedID = nil }
        revision += 1
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        revision += 1
    }

    func add(_ a: Annotation) { commit { $0.annotations.append(a) } }

    func deleteSelection() {
        guard let id = selectedID else { return }
        selectedID = nil
        commit { $0.annotations.removeAll { $0.id == id } }
    }

    func move(_ id: UUID, by d: CGVector) {
        commit { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i] = s.annotations[i].moved(by: d) }
        }
    }

    func setCrop(_ r: CGRect?) {
        commit { $0.crop = r.map { $0.integral } }
    }

    func setBackdrop(_ b: Backdrop) {
        if b.fill == .wallpaper, wallpaper == nil { loadWallpaper() }
        commit { $0.backdrop = b }
    }

    var nextCounter: Int { (state.annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }

    private func recolorSelection() {
        guard let id = selectedID else { return }
        commit { s in if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i].color = colorIndex } }
    }

    private func rewidthSelection() {
        guard let id = selectedID else { return }
        let w = strokeWidth, f = fontSize
        commit { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) {
                s.annotations[i].width = w
                if s.annotations[i].kind == .text { s.annotations[i].fontSize = f }
            }
        }
    }

    func updateText(_ id: UUID, _ text: String) {
        commit { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s.annotations.remove(at: i) }
                else { s.annotations[i].text = text }
            }
        }
    }

    private func loadWallpaper() {
        guard let screen = NSScreen.main, let img = DesktopIcons.wallpaper(for: screen) else { return }
        wallpaper = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The finished image.
    func export() -> CGImage? { Renderer.render(base: base, state: state, scale: scale, wallpaper: wallpaper) }

    /// What the canvas shows: the finished image minus a text being edited.
    func renderShown() -> CGImage? {
        guard !hiddenIDs.isEmpty else { return export() }
        var s = state
        s.annotations.removeAll { hiddenIDs.contains($0.id) }
        return Renderer.render(base: base, state: s, scale: scale, wallpaper: wallpaper)
    }

    /// Image + annotations without crop or backdrop: the canvas shows this while cropping.
    func renderUncropped() -> CGImage? {
        var s = state
        s.crop = nil
        s.backdrop.fill = .none
        return Renderer.render(base: base, state: s, scale: scale)
    }
}
