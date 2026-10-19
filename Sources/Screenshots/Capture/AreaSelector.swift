import AppKit
import QuartzCore

/// The full-screen layer where an area or a window is chosen. The screen is captured first
/// (frozen), so the magnifier reads real pixels and nothing moves under the selection.
///   Drag: an area. Shift while dragging: a square. Click without dragging: the whole screen
///   (or, picking windows, the window under the cursor). Space: area ↔ window. Esc: cancel.
@MainActor
final class AreaSelector {
    enum Mode { case area, window, text, scrolling, record, timer }

    struct Result {
        var rect: CGRect               // AppKit global points
        var screen: NSScreen
        var frozen: FrozenScreen?      // the whole screen as it was when the overlay opened
        var window: ScreenGrabber.WindowInfo?
        /// The selection's pixels from the frozen screen.
        var frozenCrop: CGImage? { frozen?.crop(points: rect, screenFrame: screen.frame) }
    }

    static private(set) var current: AreaSelector?

    let mode: Mode
    var pickingWindows: Bool
    private(set) var overlays: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private(set) var snapshots: [CGDirectDisplayID: FrozenScreen] = [:]
    private(set) var windowList: [ScreenGrabber.WindowInfo] = []

    private init(mode: Mode) {
        self.mode = mode
        self.pickingWindows = mode == .window
    }

    /// Opens the overlay on every screen and waits for a choice; nil when cancelled.
    static func select(_ mode: Mode) async -> Result? {
        current?.finish(nil)
        let selector = AreaSelector(mode: mode)
        current = selector
        await selector.prepare()
        if selector.snapshots.isEmpty {
            current = nil
            HUD.shared.toast(CaptureError.noPermission.localizedDescription, error: true)
            return nil
        }
        return await withCheckedContinuation { cont in
            selector.continuation = cont
            selector.open()
        }
    }

    private func prepare() async {
        let hideIcons = Prefs.shared.hideIconsWhileCapturing && !DesktopIcons.shared.isHidden
        if hideIcons { DesktopIcons.shared.show(true); try? await Task.sleep(nanoseconds: 150_000_000) }
        for screen in Stage.screens {
            if let frozen = await FrozenScreen.capture(screen) {
                snapshots[Geometry.displayID(screen)] = frozen
            }
        }
        windowList = ScreenGrabber.windows()
        if hideIcons { DesktopIcons.shared.show(false) }
    }

    private func open() {
        Stage.activate()
        for screen in Stage.screens {
            let w = OverlayWindow(screen: screen, selector: self,
                                  snapshot: snapshots[Geometry.displayID(screen)])
            CaptureExclusion.add(w)
            overlays.append(w)
            w.orderFrontRegardless()
        }
        let start = overlays.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? overlays.first
        start?.makeKey()
        if !Stage.isolated { NSCursor.crosshair.set() }
        overlays.forEach { $0.overlayView.refresh(mouse: NSEvent.mouseLocation) }
    }

    func finish(_ result: Result?) {
        for w in overlays { w.overlayView.releaseSnapshot(); w.dispose() }
        overlays.removeAll()
        snapshots.removeAll()
        DispatchQueue.main.async { Memory.trim() }
        if !Stage.isolated { NSCursor.arrow.set() }
        if AreaSelector.current === self { AreaSelector.current = nil }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    func toggleWindowPicking() {
        guard mode != .window else { return }
        pickingWindows.toggle()
        overlays.forEach { $0.overlayView.refresh(mouse: NSEvent.mouseLocation) }
    }

    func window(at p: CGPoint) -> ScreenGrabber.WindowInfo? {
        windowList.first { $0.frame.contains(p) }
    }

    var hint: String {
        switch mode {
        case .window: return L("Click a window  ·  Esc cancels")
        case .text: return L("Drag over the text  ·  Esc cancels")
        case .scrolling: return L("Drag over the part that scrolls  ·  Space picks a window  ·  Esc cancels")
        case .record: return L("Drag the area to record  ·  Click records the whole screen  ·  Esc cancels")
        default: return L("Drag an area  ·  Click takes the whole screen  ·  Space picks a window  ·  Esc cancels")
        }
    }
}

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    @MainActor
    init(screen: NSScreen, selector: AreaSelector, snapshot: FrozenScreen?) {
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                  screen: screen, selector: selector, snapshot: snapshot)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayView: NSView {
    let screen: NSScreen
    weak var selector: AreaSelector?
    private(set) var snapshot: FrozenScreen?

    private let freezeLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let sizeLabel = OverlayLabel()
    private let hintLabel = OverlayLabel()
    private let magnifier = MagnifierView(frame: CGRect(x: 0, y: 0, width: 132, height: 156))

    private var dragStart: CGPoint?
    private(set) var selection: CGRect?        // view coordinates
    private var hovered: ScreenGrabber.WindowInfo?

    init(frame: CGRect, screen: NSScreen, selector: AreaSelector, snapshot: FrozenScreen?) {
        self.screen = screen
        self.selector = selector
        self.snapshot = snapshot
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let scale = screen.backingScaleFactor

        if Prefs.shared.freezeScreen, let snapshot {
            // The surface itself, not a CGImage of it: no copy of the screen.
            freezeLayer.contents = snapshot.surface
            freezeLayer.contentsGravity = .resize
        }
        freezeLayer.frame = bounds
        layer?.addSublayer(freezeLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        layer?.addSublayer(dimLayer)

        highlightLayer.fillColor = NSColor.white.withAlphaComponent(0.16).cgColor
        highlightLayer.strokeColor = NSColor.white.cgColor
        highlightLayer.lineWidth = 2
        layer?.addSublayer(highlightLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        for l in [crossH, crossV] {
            l.backgroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
            l.contentsScale = scale
            layer?.addSublayer(l)
        }
        [freezeLayer, dimLayer, highlightLayer, borderLayer].forEach { $0.contentsScale = scale }
        // No implicit animations: the overlay follows the mouse one to one.
        for l in [freezeLayer, dimLayer, borderLayer, highlightLayer, crossH, crossV] {
            l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        }

        addSubview(sizeLabel)
        hintLabel.text = selector.hint
        addSubview(hintLabel)
        magnifier.snapshot = snapshot
        magnifier.screen = screen
        addSubview(magnifier)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The frozen screen lives in the layer and the magnifier: drop both when the overlay goes.
    func releaseSnapshot() {
        freezeLayer.contents = nil
        magnifier.snapshot = nil
        snapshot = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func global(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + screen.frame.minX, y: p.y + screen.frame.minY) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    // MARK: events

    override func mouseMoved(with event: NSEvent) { refresh(mouse: global(convert(event.locationInWindow, from: nil))) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        refresh(mouse: global(dragStart!))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        var w = p.x - start.x, h = p.y - start.y
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(w), abs(h))
            w = side * (w < 0 ? -1 : 1); h = side * (h < 0 ? -1 : 1)
        }
        selection = CGRect(x: min(start.x, start.x + w), y: min(start.y, start.y + h), width: abs(w), height: abs(h)).integral
        refresh(mouse: global(p))
    }

    override func mouseUp(with event: NSEvent) {
        guard let selector else { return }
        defer { dragStart = nil }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            selector.finish(result(rect: CGRect(origin: global(sel.origin), size: sel.size), window: nil))
            return
        }
        let p = global(convert(event.locationInWindow, from: nil))
        if selector.pickingWindows {
            if let w = selector.window(at: p) {
                selector.finish(result(rect: w.frame.intersection(screen.frame), window: w))
            }
            return
        }
        if selector.mode == .text { return }
        selector.finish(result(rect: screen.frame, window: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: selector?.finish(nil)               // Esc
        case 49: selector?.toggleWindowPicking()     // Space
        default: super.keyDown(with: event)
        }
    }

    private func result(rect: CGRect, window: ScreenGrabber.WindowInfo?) -> AreaSelector.Result {
        AreaSelector.Result(rect: rect, screen: screen, frozen: snapshot, window: window)
    }

    // MARK: drawing

    func refresh(mouse: CGPoint) {
        guard let selector else { return }
        let inside = NSMouseInRect(mouse, screen.frame, false)
        let p = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let path = CGMutablePath()
        path.addRect(bounds)
        hovered = nil
        if let sel = selection {
            path.addRect(sel)
            borderLayer.path = CGPath(rect: sel.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            highlightLayer.path = nil
        } else if selector.pickingWindows {
            hovered = inside ? selector.window(at: mouse) : nil
            if let w = hovered {
                let r = local(w.frame).intersection(bounds)
                path.addRect(r)
                highlightLayer.path = CGPath(rect: r.insetBy(dx: 1, dy: 1), transform: nil)
            } else {
                highlightLayer.path = nil
            }
            borderLayer.path = nil
        } else {
            borderLayer.path = nil
            highlightLayer.path = nil
        }
        dimLayer.path = path
        dimLayer.frame = bounds

        let showCross = inside && Prefs.shared.showCrosshair && !selector.pickingWindows && dragStart == nil
        crossH.isHidden = !showCross
        crossV.isHidden = !showCross
        crossH.frame = CGRect(x: 0, y: p.y.rounded() - 0.25, width: bounds.width, height: 0.5)
        crossV.frame = CGRect(x: p.x.rounded() - 0.25, y: 0, width: 0.5, height: bounds.height)
        CATransaction.commit()

        // Size: under the selection, or the window's app while picking.
        if let sel = selection {
            sizeLabel.text = "\(Int(sel.width)) × \(Int(sel.height))"
            sizeLabel.isHidden = false
            let s = sizeLabel.fittingSize
            var o = CGPoint(x: sel.maxX - s.width, y: sel.minY - s.height - 8)
            if o.y < 8 { o.y = sel.minY + 8 }
            o.x = max(8, o.x)
            sizeLabel.frame = CGRect(origin: o, size: s)
        } else if let w = hovered {
            sizeLabel.text = w.app.isEmpty ? "\(Int(w.frame.width)) × \(Int(w.frame.height))" : "\(w.app)  ·  \(Int(w.frame.width)) × \(Int(w.frame.height))"
            sizeLabel.isHidden = false
            let s = sizeLabel.fittingSize
            let r = local(w.frame).intersection(bounds)
            sizeLabel.frame = CGRect(x: max(8, r.midX - s.width / 2), y: max(8, r.midY - s.height / 2), width: s.width, height: s.height)
        } else {
            sizeLabel.isHidden = true
        }

        let hs = hintLabel.fittingSize
        hintLabel.frame = CGRect(x: (bounds.width - hs.width) / 2, y: bounds.height - hs.height - 48, width: hs.width, height: hs.height)
        hintLabel.isHidden = !inside || selection != nil

        let showMag = inside && Prefs.shared.showMagnifier && !selector.pickingWindows && snapshot != nil
        magnifier.isHidden = !showMag
        if showMag {
            magnifier.point = p
            var o = CGPoint(x: p.x + 20, y: p.y - magnifier.frame.height - 20)
            if o.x + magnifier.frame.width > bounds.width - 8 { o.x = p.x - magnifier.frame.width - 20 }
            if o.y < 8 { o.y = p.y + 20 }
            magnifier.setFrameOrigin(o)
            magnifier.needsDisplay = true
        }
    }
}

/// Black label, white Montserrat Bold: dimensions and the hint.
final class OverlayLabel: NSView {
    var text = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont(name: "Montserrat-Bold", size: 11) ?? .boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
    }
    override var fittingSize: NSSize {
        let s = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(s.width) + 16, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x11181C, alpha: 0.92).setFill()
        bounds.fill()
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: 8, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

/// 12 × 12 points of the frozen screen, ten times bigger, with the center pixel outlined
/// and the coordinates under it.
final class MagnifierView: NSView {
    var snapshot: FrozenScreen?
    weak var screen: NSScreen?
    var point: CGPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot, let screen, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side: CGFloat = 132
        let box = CGRect(x: 0, y: bounds.height - side, width: side, height: side)
        let scale = CGFloat(snapshot.width) / screen.frame.width
        let pixels: CGFloat = 13
        let cx = (point.x * scale).rounded(.down), cy = ((screen.frame.height - point.y) * scale).rounded(.down)
        let src = CGRect(x: cx - (pixels - 1) / 2, y: cy - (pixels - 1) / 2, width: pixels, height: pixels)
        NSColor.black.setFill()
        box.fill()
        if let crop = snapshot.crop(pixels: src) {
            ctx.interpolationQuality = .none
            // Crop may be clipped at the screen edge: keep its place in the grid.
            let cell = side / pixels
            let dx = (crop.width < Int(pixels) && src.minX < 0) ? -src.minX * cell : 0
            let dy = (crop.height < Int(pixels) && src.maxY > CGFloat(snapshot.height)) ? (src.maxY - CGFloat(snapshot.height)) * cell : 0
            ctx.draw(crop, in: CGRect(x: box.minX + dx, y: box.minY + dy, width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell))
            let center = CGRect(x: box.minX + (pixels - 1) / 2 * cell, y: box.minY + (pixels - 1) / 2 * cell, width: cell, height: cell)
            NSColor.white.setStroke()
            let pth = NSBezierPath(rect: center.insetBy(dx: 0.5, dy: 0.5)); pth.lineWidth = 1; pth.stroke()
        }
        NSColor.white.setStroke()
        let frame = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)); frame.lineWidth = 1; frame.stroke()
        let label = CGRect(x: 0, y: 0, width: side, height: bounds.height - side)
        NSColor(hex: 0x11181C).setFill()
        label.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Montserrat-Bold", size: 10) ?? .boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        let text = "\(Int(point.x)), \(Int(screen.frame.height - point.y))" as NSString
        let s = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (side - s.width) / 2, y: (label.height - s.height) / 2), withAttributes: attrs)
    }
}
