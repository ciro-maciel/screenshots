import AppKit
import SwiftUI

/// `Screenshots --screenshots <dir>`: saves a PNG of every window and panel, with sample
/// captures, for visual review before a release. Settings live in a temporary folder.
@MainActor
enum Screens {
    static var dir: URL!

    static func run(_ out: URL) async -> Int32 {
        dir = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-screens-\(UUID().uuidString.prefix(8))")
        setenv("SCREENSHOT_HOME", home.path, 1)
        Prefs.shared.reset()
        Prefs.shared.saveFolder = home.appendingPathComponent("Saved").path

        // Settings, every tab.
        SettingsWindow.show()
        await sleep(0.5)
        for (i, t) in SettingsTab.allCases.enumerated() {
            SettingsWindow.model.tab = t
            await sleep(0.3)
            await save(SettingsWindow.current?.contentView, "1\(i)-settings-\(t.rawValue).png")
        }
        SettingsWindow.current?.close()

        // Welcome, the real window.
        WelcomeWindow.show()
        await save(WelcomeWindow.current?.contentView, "20-welcome.png")
        WelcomeWindow.close()
        for granted in [false, true] {
            render(WelcomeView(granted: granted), "2\(granted ? 2 : 1)-welcome-\(granted ? "ready" : "permission").png")
        }

        // History: empty, then with samples.
        render(HistoryView(library: Library.shared).frame(width: 1040, height: 520), "30-history-empty.png")
        let shots = [sample(title: "Relatório de vendas", w: 1440, h: 900),
                     sample(title: "Painel do cliente", w: 1200, h: 760),
                     sample(title: "Configurações", w: 900, h: 1400)]
        var caps: [Capture] = []
        for (i, s) in shots.enumerated() { caps.append(Library.shared.add(image: s, scale: 2, source: ["area", "window", "scrolling"][i])) }

        // Quick Access: one card size for a tiny crop, a wide screen and a long page.
        let shapes = [("pequeno", 160, 90), ("tela", 2880, 1800), ("longo", 900, 4200), ("largo", 3000, 600)]
        for (i, sh) in shapes.enumerated() {
            let c = Library.shared.add(image: sample(title: "Formato \(sh.0)", w: sh.1, h: sh.2), scale: 2, source: "area")
            render(QuickAccessCard(id: c.id), "4\(i + 3)-quick-access-\(sh.0).png")
        }

        // Quick Access, still and with the mouse over it.
        render(QuickAccessCard(id: caps[0].id), "40-quick-access.png")
        render(QuickAccessCard(id: caps[0].id, forceHover: true), "41-quick-access-hover.png")

        // Editor with one of each annotation.
        EditorWindow.show(image: shots[0], scale: 2, captureID: caps[0].id)
        if let w = EditorWindow.open.last {
            w.setContentSize(CGSize(width: 1180, height: 760))
            let m = w.model
            func add(_ k: Annotation.Kind, _ a: CGPoint, _ b: CGPoint, color: Int = 0, text: String = "", n: Int = 0) {
                m.add(Annotation(kind: k, a: a, b: b, points: k == .pencil || k == .highlighter ? [a, CGPoint(x: (a.x + b.x) / 2, y: a.y + 30), b] : [],
                                 color: color, width: m.strokeWidth, text: text, fontSize: m.fontSize, number: n))
            }
            // The sample is 1440 × 900 pixels, origin at the bottom left.
            add(.rect, CGPoint(x: 400, y: 640), CGPoint(x: 1120, y: 560))
            add(.arrow, CGPoint(x: 1300, y: 300), CGPoint(x: 1140, y: 380))
            add(.text, CGPoint(x: 1150, y: 300), .zero, text: "Maior venda")
            add(.counter, CGPoint(x: 380, y: 780), .zero, n: 1)
            add(.counter, CGPoint(x: 380, y: 720), .zero, n: 2)
            add(.highlighter, CGPoint(x: 410, y: 455), CGPoint(x: 700, y: 455), color: 1)
            add(.blur, CGPoint(x: 820, y: 470), CGPoint(x: 1120, y: 180))
            add(.ellipse, CGPoint(x: 20, y: 600), CGPoint(x: 220, y: 500), color: 3)
            await sleep(0.5)
            await save(w.contentView, "50-editor.png")
            m.tool = .crop
            await sleep(0.3)
            await save(w.contentView, "51-editor-crop-tool.png")
            m.tool = .arrow
            m.setBackdrop(Backdrop(fill: .gray, padding: 64))
            await sleep(0.3)
            await save(w.contentView, "52-editor-backdrop.png")
            render(BackdropPanel(model: m), "53-backdrop-panel.png")
            w.close()
        }

        HistoryWindow.show()
        await save(HistoryWindow.current?.contentView, "31-history.png")
        HistoryWindow.current?.close()

        // Quick Access as a real panel, and the menu bar menu.
        QuickAccess.shared.show(caps[1])
        await save(QuickAccess.shared.panel(caps[1].id)?.contentView, "42-quick-access-panel.png")
        QuickAccess.shared.closeAll()
        // The menu opens over the real menu bar: never under the isolated tests.
        if !Stage.isolated { await menuShot() }

        // Pin.
        let pin = PinWindow.show(image: shots[1], scale: 2)
        await sleep(0.4)
        await save(pin.contentView, "60-pin.png")
        pin.closePin()

        // Bars.
        let scroll = ScrollSession(rect: CGRect(x: 100, y: 100, width: 600, height: 400))
        render(ScrollPanelView(session: scroll), "70-scroll-panel.png")
        let rec = RecordingSession(rect: CGRect(x: 100, y: 100, width: 600, height: 400), gif: false)
        render(RecordingBar(session: rec), "71-recording-bar.png")
        render(ToastView(text: L("Image copied")), "72-toast.png")
        render(ToastView(text: L("No text found in that area."), error: true), "73-toast-error.png")
        render(CountdownView(n: 3), "74-countdown.png")

        // The selection overlay over a sample screen, with a selection and the magnifier.
        let screen = Stage.testScreen ?? NSScreen.main!
        let fake = sample(title: "Área de trabalho", w: Int(screen.frame.width * 2), h: Int(screen.frame.height * 2))
        if let sel = await overlayPreview(screen: screen, snapshot: fake) { write(sel, "80-overlay.png") }

        try? FileManager.default.removeItem(at: home)
        Prefs.shared.store.removePersistentDomain(forName: "click.ciromaciel.screenshots.tests")
        print("screens → \(out.path)")
        return 0
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// The real window as it is on screen: title bar, traffic lights and all.
    static func save(_ v: NSView?, _ name: String) async {
        guard let w = v?.window else { return }
        w.orderFrontRegardless()
        await sleep(0.35)
        if let img = try? await ScreenGrabber.capture(windowID: CGWindowID(w.windowNumber), shadow: false) { write(img, name) }
    }

    /// Opens the status menu and photographs it with screencapture while AppKit tracks it.
    static func menuShot() async {
        StatusMenu.shared.install()
        guard let button = StatusMenu.shared.item?.button, let bw = button.window else { return }
        await sleep(0.4)
        let f = bw.frame
        let shot = dir.appendingPathComponent("90-status-menu.png").path
        let menuRect = CGRect(x: f.minX - 20, y: Geometry.mainHeight - f.minY, width: 380, height: 560)
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R\(Int(menuRect.minX)),\(Int(menuRect.minY) - 24),\(Int(menuRect.width)),\(Int(menuRect.height))", shot]
            try? p.run(); p.waitUntilExit()
            StatusMenu.shared.item?.menu?.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)
    }

    static func saveOffscreen(_ v: NSView?, _ name: String) {
        guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    static func write(_ img: CGImage, _ name: String) {
        try? Library.encode(img, format: .png, scale: 2, downscale: false).write(to: dir.appendingPathComponent(name))
    }

    static func render<V: View>(_ view: V, _ name: String) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host
        w.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        saveOffscreen(host, name)
        w.orderOut(nil)
    }

    /// The overlay drawn on screen for a moment over a fake desktop, captured with
    /// the exclusion turned off just for this picture.
    static func overlayPreview(screen: NSScreen, snapshot: CGImage) async -> CGImage? {
        let w = await withCheckedContinuation { (c: CheckedContinuation<OverlayWindow, Never>) in
            Task {
                let r = await AreaSelector.select(.area)
                _ = r
            }
            Task {
                while AreaSelector.current?.overlays.isEmpty ?? true { try? await Task.sleep(nanoseconds: 50_000_000) }
                c.resume(returning: AreaSelector.current!.overlays.first { $0.screen == screen } ?? AreaSelector.current!.overlays[0])
            }
        }
        // Replace the real frozen screen with the sample, then draw a selection.
        let v = w.overlayView
        let preview = OverlayView(frame: v.frame, screen: screen, selector: AreaSelector.current!, snapshot: FrozenScreen(image: snapshot))
        w.contentView = preview
        let a = CGPoint(x: screen.frame.minX + 400, y: screen.frame.maxY - 300)
        let b = CGPoint(x: screen.frame.minX + 1200, y: screen.frame.maxY - 820)
        E2E.mouse(.leftMouseDown, a, in: w)
        E2E.mouse(.leftMouseDragged, b, in: w)
        await sleep(0.3)
        w.sharingType = .readOnly
        CaptureExclusion.remove(w)
        let img = try? await ScreenGrabber.capture(rect: CGRect(x: screen.frame.minX, y: screen.frame.maxY - 1100, width: 1600, height: 1100))
        AreaSelector.current?.finish(nil)
        return img
    }

    /// A believable app screen in the gray ramp: sidebar, title, table rows, a chart.
    static func sample(title: String, w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }
        let H = CGFloat(h), W = CGFloat(w)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: W, height: H).fill()
        NSColor(hex: 0xF9FAFB).setFill(); CGRect(x: 0, y: 0, width: 440, height: H).fill()
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: String, _ color: UInt32) {
            (s as NSString).draw(at: CGPoint(x: x, y: H - y), withAttributes: [.font: NSFont(name: "Montserrat-\(weight)", size: size)!,
                                                                              .foregroundColor: NSColor(hex: color)])
        }
        text("Painel", 60, 120, 40, "Black", 0x11181C)
        for (i, item) in ["Início", "Clientes", "Vendas", "Relatórios", "Ajustes"].enumerated() {
            text(item, 60, 240 + CGFloat(i) * 72, 28, i == 2 ? "Bold" : "Medium", i == 2 ? 0x11181C : 0x6B7280)
        }
        text(title.uppercased(), 520, 120, 20, "ExtraBold", 0x9CA3AF)
        text(title, 520, 210, 64, "Black", 0x11181C)
        text("Atualizado hoje às 14:03 · 1.284 registros", 520, 280, 28, "Medium", 0x4B5563)
        for i in 0..<10 {
            let y = 380 + CGFloat(i) * 96
            if y > H - 100 { break }
            NSColor(hex: 0xF3F4F6).setFill(); CGRect(x: 520, y: H - y - 2, width: W - 600, height: 2).fill()
            text(["Ana Souza", "Bruno Lima", "Carla Dias", "Diego Rocha", "Elisa Prado", "Fábio Nunes", "Gabi Reis", "Hugo Melo", "Iara Costa", "João Pires"][i],
                 520, y - 20, 30, "Bold", 0x11181C)
            text("R$ \(1200 + i * 337),00", W - 420, y - 20, 30, "Medium", 0x374151)
        }
        for i in 0..<8 {
            let bh = CGFloat([120, 200, 160, 260, 220, 300, 240, 340][i])
            NSColor(hex: i == 7 ? 0x11181C : 0xE5E7EB).setFill()
            CGRect(x: W - 420 + CGFloat(i) * 46, y: H - 300, width: 30, height: bh * 0.4).fill()
        }
        return ctx.makeImage()!
    }
}
