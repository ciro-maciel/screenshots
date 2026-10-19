import AppKit

/// The image being annotated. Committed work is drawn from one cached render; the shape
/// under the mouse is drawn on top of it, so dragging stays light on big captures.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    private var cache: CGImage?
    private var cacheRevision = -1
    private var cacheCropping = false
    private var draft: Annotation?
    private var dragStart: CGPoint?
    private var moveStart: CGPoint?
    private var moveOffset = CGVector.zero
    private var cropDraft: CGRect?
    private var textField: NSTextField?
    private var editingTextID: UUID?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    func refresh() { needsDisplay = true }

    // MARK: geometry

    private var cropping: Bool { model.tool == .crop }

    /// Size of what is shown, in image pixels.
    private var shownSize: CGSize {
        if cropping { return model.base.size }
        let c = Renderer.contentRect(base: model.base, state: model.state)
        let pad = model.state.backdrop.fill == .none ? 0 : (model.state.backdrop.padding * model.scale).rounded()
        return CGSize(width: c.width + pad * 2, height: c.height + pad * 2)
    }

    /// Where the shown image sits in the view, and its pixels-to-points factor.
    var display: (rect: CGRect, factor: CGFloat) {
        let size = shownSize
        let room = bounds.insetBy(dx: 32, dy: 32)
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return (.zero, 1) }
        let factor = min(room.width / size.width, room.height / size.height, 1 / model.scale)
        let w = size.width * factor, h = size.height * factor
        return (CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral, factor)
    }

    /// View point → image pixels (uncropped image space).
    func imagePoint(_ p: CGPoint) -> CGPoint {
        let d = display
        let out = CGPoint(x: (p.x - d.rect.minX) / d.factor, y: (p.y - d.rect.minY) / d.factor)
        if cropping { return out }
        let c = Renderer.contentRect(base: model.base, state: model.state)
        let pad = model.state.backdrop.fill == .none ? 0 : (model.state.backdrop.padding * model.scale).rounded()
        return CGPoint(x: out.x - pad + c.minX, y: out.y - pad + c.minY)
    }

    /// Image pixels → view point.
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let d = display
        if cropping { return CGPoint(x: d.rect.minX + p.x * d.factor, y: d.rect.minY + p.y * d.factor) }
        let c = Renderer.contentRect(base: model.base, state: model.state)
        let pad = model.state.backdrop.fill == .none ? 0 : (model.state.backdrop.padding * model.scale).rounded()
        return CGPoint(x: d.rect.minX + (p.x + pad - c.minX) * d.factor, y: d.rect.minY + (p.y + pad - c.minY) * d.factor)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(hex: 0xF3F4F6).setFill()
        bounds.fill()
        if cacheRevision != model.revision || cacheCropping != cropping || cache == nil {
            cache = cropping ? model.renderUncropped() : model.renderShown()
            cacheRevision = model.revision
            cacheCropping = cropping
        }
        let d = display
        guard let cache else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cache, in: d.rect)
        NSColor(hex: 0xE5E7EB).setStroke()
        NSBezierPath(rect: d.rect.insetBy(dx: -0.5, dy: -0.5)).stroke()

        // Live shapes, in image pixels.
        ctx.saveGState()
        let origin = viewPoint(.zero)
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: d.factor, y: d.factor)
        if !cropping {
            let content = Renderer.contentRect(base: model.base, state: model.state)
            ctx.clip(to: content)
        }
        if let draft {
            if draft.kind == .spotlight {
                let path = CGMutablePath()
                path.addRect(cropping ? CGRect(origin: .zero, size: model.base.size) : Renderer.contentRect(base: model.base, state: model.state))
                path.addRect(draft.rect)
                ctx.addPath(path)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fillPath(using: .evenOdd)
            } else {
                Renderer.draw(draft, in: ctx, base: model.base, scale: model.scale)
            }
        }
        if let sel = model.selected, moveStart != nil, moveOffset != .zero {
            Renderer.draw(sel.moved(by: moveOffset), in: ctx, base: model.base, scale: model.scale)
        }
        ctx.restoreGState()

        if let sel = model.selected, editingTextID != sel.id {
            let b = sel.moved(by: moveOffset).bounds
            let r = CGRect(origin: viewPoint(b.origin), size: CGSize(width: b.width * d.factor, height: b.height * d.factor)).insetBy(dx: -4, dy: -4)
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor(hex: 0x11181C).setStroke()
            path.stroke()
        }

        if cropping {
            let current = cropDraft ?? model.state.crop
            if let c = current {
                let r = CGRect(origin: viewPoint(c.origin), size: CGSize(width: c.width * d.factor, height: c.height * d.factor))
                let dim = NSBezierPath(rect: d.rect)
                dim.append(NSBezierPath(rect: r))
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.45).setFill()
                dim.fill()
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
                let label = "\(Int(c.width)) × \(Int(c.height))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Montserrat-Bold", size: 11) ?? .boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
                let s = label.size(withAttributes: attrs)
                let lr = CGRect(x: r.minX, y: r.minY - s.height - 10, width: s.width + 14, height: s.height + 6)
                NSColor(hex: 0x11181C).setFill(); lr.fill()
                label.draw(at: CGPoint(x: lr.minX + 7, y: lr.minY + 3), withAttributes: attrs)
            }
        }
    }

    // MARK: mouse

    override func resetCursorRects() {
        addCursorRect(display.rect, cursor: toolCursor)
    }

    private var toolCursor: NSCursor { model.tool == .select ? .arrow : (model.tool == .text ? .iBeam : .crosshair) }

    /// Over a shape the cursor says it can be moved, with any tool; off it, the tool draws.
    override func mouseMoved(with event: NSEvent) {
        guard !cropping, moveStart == nil, draft == nil else { return }
        let vp = convert(event.locationInWindow, from: nil)
        guard display.rect.contains(vp) else { return }
        (movableHit(imagePoint(vp)) != nil ? NSCursor.openHand : toolCursor).set()
    }

    /// The shape a press would pick up: text keeps its own click (edit) under the text tool.
    private func movableHit(_ p: CGPoint) -> Annotation? {
        guard let hit = topHit(p, 6 / display.factor) else { return nil }
        if model.tool == .text && hit.kind == .text { return nil }
        return hit
    }

    private func startMove(_ an: Annotation, at p: CGPoint) {
        model.selectedID = an.id
        moveStart = p
        moveOffset = .zero
        NSCursor.closedHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let vp = convert(event.locationInWindow, from: nil)
        let p = imagePoint(vp)
        let tol = 6 / display.factor
        if model.tool != .select, model.tool != .crop, let hit = movableHit(p) {
            startMove(hit, at: p)
            refresh()
            return
        }
        if model.tool != .select { model.selectedID = nil }
        switch model.tool {
        case .select:
            if event.clickCount == 2, let hit = topHit(p, tol), hit.kind == .text {
                beginText(editing: hit)
                return
            }
            model.selectedID = topHit(p, tol)?.id
            moveStart = model.selectedID == nil ? nil : p
            moveOffset = .zero
        case .crop:
            dragStart = clampToImage(p)
            cropDraft = nil
        case .text:
            if let hit = topHit(p, tol), hit.kind == .text { beginText(editing: hit) } else { beginText(at: p) }
        case .counter:
            let counter = Annotation(kind: .counter, a: p, b: p, color: model.colorIndex, width: model.strokeWidth, number: model.nextCounter)
            model.add(counter)
            model.selectedID = counter.id
        default:
            guard let kind = model.tool.kind else { return }
            dragStart = p
            draft = Annotation(kind: kind, a: p, b: p, points: [p], color: model.colorIndex, width: model.strokeWidth)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        if let start = moveStart {
            moveOffset = CGVector(dx: p.x - start.x, dy: p.y - start.y)
        } else if model.tool == .crop, let start = dragStart {
            let q = clampToImage(p)
            cropDraft = CGRect(x: min(start.x, q.x), y: min(start.y, q.y), width: abs(q.x - start.x), height: abs(q.y - start.y))
        } else if var d = draft, let start = dragStart {
            switch d.kind {
            case .pencil, .highlighter:
                if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 / display.factor { d.points.append(p) }
            case .line, .arrow:
                d.b = shift ? Self.snap45(from: start, to: p) : p
            default:
                d.b = shift ? Self.square(from: start, to: p) : p
            }
            draft = d
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; refresh(); window?.invalidateCursorRects(for: self) }
        if let id = model.selectedID, moveStart != nil {
            if abs(moveOffset.dx) + abs(moveOffset.dy) > 0 { model.move(id, by: moveOffset) }
            moveStart = nil
            moveOffset = .zero
            (model.tool == .select ? NSCursor.arrow : NSCursor.openHand).set()
            return
        }
        if model.tool == .crop {
            if let c = cropDraft, c.width >= 8, c.height >= 8 { model.setCrop(c) }
            cropDraft = nil
            return
        }
        guard let d = draft else { return }
        draft = nil
        let big: Bool
        switch d.kind {
        case .pencil, .highlighter: big = d.points.count >= 2
        case .line, .arrow: big = hypot(d.b.x - d.a.x, d.b.y - d.a.y) >= 6 / display.factor
        default: big = d.rect.width >= 4 / display.factor && d.rect.height >= 4 / display.factor
        }
        if big {
            model.add(d)
            model.selectedID = d.id
            NSCursor.openHand.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        if textField != nil { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 51, 117: model.deleteSelection(); refresh(); return             // ⌫ ⌦
        case 53:                                                              // Esc
            if model.tool == .crop { model.tool = .select } else { model.selectedID = nil }
            refresh(); return
        case 36, 76: if model.tool == .crop { model.tool = .select; refresh() }; return   // ↩
        case 123, 124, 125, 126:
            guard let id = model.selectedID else { break }
            let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) * model.scale
            let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                               125: CGVector(dx: 0, dy: -step), 126: CGVector(dx: 0, dy: step)][Int(event.keyCode)]!
            model.move(id, by: d); refresh(); return
        default: break
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let t = Tool.allCases.first(where: { $0.key == ch }) {
            model.tool = t
            refresh()
            return
        }
        super.keyDown(with: event)
    }

    private func topHit(_ p: CGPoint, _ tol: CGFloat) -> Annotation? {
        model.state.annotations.reversed().first { $0.hit(p, tolerance: tol) }
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(model.base.width)), y: min(max(p.y, 0), CGFloat(model.base.height)))
    }

    static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let snapped = (ang / step).rounded() * step
        let len = hypot(b.x - a.x, b.y - a.y)
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }

    static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + side * (b.x < a.x ? -1 : 1), y: a.y + side * (b.y < a.y ? -1 : 1))
    }

    // MARK: text

    /// A new text not yet in the model: it becomes one undo step when typing ends.
    private var pendingText: Annotation?

    private func beginText(at p: CGPoint) {
        let an = Annotation(kind: .text, a: p, b: p, color: model.colorIndex, width: model.strokeWidth, text: "", fontSize: model.fontSize)
        pendingText = an
        openField(for: an)
    }

    private func beginText(editing an: Annotation) {
        commitText()
        model.selectedID = an.id
        model.hiddenIDs.insert(an.id)
        openField(for: an)
    }

    private func openField(for an: Annotation) {
        editingTextID = an.id
        let d = display
        let font = Annotation.font(an.fontSize * d.factor)
        let tf = NSTextField(string: an.text)
        tf.font = font
        tf.textColor = Palette.color(an.color)
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        tf.focusRingType = .none
        tf.delegate = self
        tf.placeholderString = L("Text")
        let top = viewPoint(an.a)
        let h = ceil(font.ascender - font.descender + font.leading) + 4
        tf.frame = CGRect(x: top.x - 2, y: top.y - h, width: max(180, Annotation.textSize(an.text, fontSize: an.fontSize).width * d.factor + 48), height: h)
        addSubview(tf)
        textField = tf
        refresh()
        window?.makeFirstResponder(tf)
    }

    /// Ends the text being typed: keeps it, or drops it when empty.
    func commitText() {
        guard let tf = textField, let id = editingTextID else { return }
        textField = nil
        editingTextID = nil
        let text = tf.stringValue
        tf.removeFromSuperview()
        if var pending = pendingText, pending.id == id {
            pendingText = nil
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pending.text = text
                model.add(pending)
            }
        } else {
            model.hiddenIDs.remove(id)
            model.updateText(id, text)
        }
        refresh()
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    var isEditingText: Bool { textField != nil }

    /// Types into the open text field (tests drive the editor through this).
    func typeText(_ s: String) {
        textField?.stringValue = s
    }
}
