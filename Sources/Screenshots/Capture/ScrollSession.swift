import AppKit
import SwiftUI

/// Scrolling capture, live: a frame marks the region, the person scrolls (or presses
/// "Rolar sozinho") and the region is captured ten times a second and stitched.
@MainActor
@Observable
final class ScrollSession {
    static private(set) var current: ScrollSession?

    let rect: CGRect
    private let stitcher: Stitcher
    private(set) var height = 0
    private(set) var autoScrolling = false
    private(set) var running = false
    private var frameWindow: NSWindow?
    private var panel: NSPanel?
    private var loop: Task<Void, Never>?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    /// Tests scroll the page themselves and drive the loop one capture at a time.
    var manualTicks = false

    init(rect: CGRect) {
        self.rect = rect
        let scale = Geometry.screen(for: rect)?.backingScaleFactor ?? 2
        stitcher = Stitcher(ignoreSidePixels: Int(32 * scale))
    }

    /// Runs until "Concluir" (the stitched image) or "Cancelar" (nil).
    func run() async -> CGImage? {
        ScrollSession.current = self
        showChrome()
        running = true
        _ = await tick()
        if !manualTicks {
            loop = Task { [weak self] in
                while let self, self.running, !Task.isCancelled {
                    if self.autoScrolling { self.scrollStep() }
                    try? await Task.sleep(nanoseconds: self.autoScrolling ? 160_000_000 : 90_000_000)
                    guard self.running else { break }
                    _ = await self.tick()
                    if self.autoScrolling, self.stitcher.stillFrames >= 4 { self.finish(); break }
                    if self.stitcher.isFull { self.finish(); break }
                }
            }
        }
        return await withCheckedContinuation { cont in continuation = cont }
    }

    /// One capture into the stitcher. Returns the new rows.
    @discardableResult
    func tick() async -> Int {
        guard let buffer = try? await ScreenGrabber.captureBuffer(rect: rect), let px = RGBA(buffer: buffer) else { return 0 }
        let added = stitcher.add(pixels: px)
        height = stitcher.height
        return added
    }

    func toggleAuto() {
        if !autoScrolling, !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            HUD.shared.toast("Para rolar sozinho, ligue o Screenshots em Acessibilidade e tente de novo.", error: true)
            return
        }
        autoScrolling.toggle()
    }

    /// A scroll wheel event in the middle of the region, a third of its height.
    private func scrollStep() {
        let center = Geometry.toCG(rect)
        let p = CGPoint(x: center.midX, y: center.midY)
        CGWarpMouseCursorPosition(p)
        let amount = Int32(max(40, rect.height / 3))
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0)
        ev?.location = p
        ev?.post(tap: .cghidEventTap)
    }

    func finish() { end(with: stitcher.result()) }
    func cancel() { end(with: nil) }

    private func end(with image: CGImage?) {
        guard running else { return }
        running = false
        loop?.cancel()
        for w in [frameWindow, panel].compactMap({ $0 }) { w.dispose() }
        DispatchQueue.main.async { Memory.trim() }
        frameWindow = nil; panel = nil
        if ScrollSession.current === self { ScrollSession.current = nil }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: image)
    }


    // MARK: chrome

    private func showChrome() {
        // A 2 pt frame just outside the region; clicks and scrolls pass through it.
        let outer = rect.insetBy(dx: -3, dy: -3)
        let fw = NSWindow(contentRect: outer, styleMask: .borderless, backing: .buffered, defer: false)
        fw.isOpaque = false
        fw.backgroundColor = .clear
        fw.ignoresMouseEvents = true
        fw.level = .statusBar
        fw.hasShadow = false
        fw.isReleasedWhenClosed = false
        fw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        fw.contentView = FrameBorderView(frame: CGRect(origin: .zero, size: outer.size))
        CaptureExclusion.add(fw)
        fw.orderFrontRegardless()
        frameWindow = fw

        let host = NSHostingView(rootView: ScrollPanelView(session: self))
        let size = host.fittingSize
        let screen = Geometry.screen(for: rect)?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < screen.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > screen.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        CaptureExclusion.add(p)
        p.orderFrontRegardless()
        panel = p
    }
}

final class FrameBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x11181C).setStroke()
        let outer = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); outer.lineWidth = 2; outer.stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5)); inner.lineWidth = 1; inner.stroke()
    }
}

struct ScrollPanelView: View {
    let session: ScrollSession
    var body: some View {
        HStack(spacing: 12) {
            GripHandle()
            Icon(name: "arrow-autofit-height", size: 16, color: Zen.gray9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rolagem").zenLabel(9, color: Zen.gray5)
                Text("\(session.height.formatted()) px").font(Zen.font(13, .black)).foregroundStyle(Zen.gray9).monospacedDigit()
            }
            .frame(width: 92, alignment: .leading)
            Button { session.toggleAuto() } label: {
                ButtonLabel(title: session.autoScrolling ? "Parar" : "Rolar sozinho", icon: session.autoScrolling ? "player-stop" : "mouse")
            }
            .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
            Button { session.cancel() } label: { ButtonLabel(title: "Cancelar", icon: "x") }
                .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
            Button { session.finish() } label: { ButtonLabel(title: "Concluir", icon: "check", color: .white) }
                .buttonStyle(ZenButtonStyle(kind: .primary, height: 30))
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(WindowDragArea())
        .background(Zen.gray0)
        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
    }
}
