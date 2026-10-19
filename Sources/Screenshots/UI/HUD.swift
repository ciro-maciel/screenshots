import AppKit
import SwiftUI

/// Short messages at the top of the screen with the mouse, and the timer's countdown.
@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private(set) var lastMessage: String?

    func toast(_ text: String, error: Bool = false, seconds: Double = 2.4) {
        lastMessage = text
        show(AnyView(ToastView(text: text, error: error)), at: .top, seconds: seconds)
    }

    /// Big number in the middle of the screen, one second each; true when it ran to the end.
    func countdown(_ seconds: Int) async -> Bool {
        for s in stride(from: seconds, to: 0, by: -1) {
            show(AnyView(CountdownView(n: s)), at: .center, seconds: 0)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        hide()
        // Let the window server drop the panel before the capture.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return true
    }

    enum Place { case top, center }

    private func show(_ view: AnyView, at place: Place, seconds: Double) {
        hideTask?.cancel()
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let screen = (Geometry.mouseScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = place == .top
            ? CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 24)
            : CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        p.contentView = host
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        CaptureExclusion.add(p)
        p.orderFrontRegardless()
        panel = p
        if seconds > 0 {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() { panel?.orderOut(nil) }
}

struct CountdownView: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(Zen.font(96, .black)).tracking(-4)
            .foregroundStyle(.white)
            .frame(width: 180, height: 180)
            .background(Zen.gray9.opacity(0.92))
    }
}
