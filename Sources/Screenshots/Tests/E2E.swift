import AppKit
import AVFoundation
import ImageIO
import Carbon.HIToolbox

/// `Screenshots --e2e [evidence-dir]`: drives every feature through the same code a person
/// uses — real screen captures through ScreenCaptureKit, the real overlay fed with mouse and
/// key events, the real editor canvas — and checks the pixels of each result. Test windows
/// open on screen for a few seconds. Settings and history live in a temporary folder.
@MainActor
enum E2E {
    static var failures: [String] = []
    static var passed = 0
    static var evidence: URL?
    static var home: URL!

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ok    \(name)") }
        else { failures.append(name); print("  FAIL  \(name)  \(detail())") }
    }

    static func section(_ s: String) { print("\n\(s)") }

    static func run() async -> Int32 {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-e2e-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SCREENSHOT_HOME", home.path, 1)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--e2e"), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
            evidence = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: evidence!, withIntermediateDirectories: true)
        }
        let p = Prefs.shared
        p.reset()
        p.saveFolder = home.appendingPathComponent("Saved").path
        p.playSound = false
        p.afterOpenEditor = false
        p.afterPin = false
        p.quickAccessAutoClose = 0
        p.windowShadow = false
        // The tests write to the clipboard: keep what the person had copied and put it back.
        let clipboard = Stage.board.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { d, t in d[t] = item.data(forType: t) }
        } ?? []
        defer {
            Stage.board.clearContents()
            Stage.board.writeObjects(clipboard.map { types in
                let item = NSPasteboardItem()
                for (t, data) in types { item.setData(data, forType: t) }
                return item
            })
        }
        print("Screenshots e2e — home \(home.path)")
        print("permission: screen recording \(ScreenGrabber.hasPermission ? "on" : "OFF"), accessibility \(AXIsProcessTrusted() ? "on" : "off")")
        guard ScreenGrabber.hasPermission else {
            print("Screen Recording is off for this process: nothing to test.")
            return 2
        }

        testLocalization()
        await testStitcherSynthetic()
        await testPrefsAndHotkeys()
        await testRealCapture()
        await testAreaSelection()
        await testAreaFlowAndQuickAccess()
        await testWindowCapture()
        await testTextRecognition()
        await testScrollingCapture()
        await testEditor()
        await testPin()
        await testRecording()
        await testTimerAndFullscreen()
        await testDesktopIconsAndHistory()

        closeTestWindows()
        QuickAccess.shared.closeAll()
        PinWindow.open.forEach { $0.closePin() }
        EditorWindow.open.forEach { $0.close() }
        Prefs.shared.store.removePersistentDomain(forName: "click.ciromaciel.screenshots.tests")
        try? FileManager.default.removeItem(at: home)

        print("\n\(passed) ok, \(failures.count) failed")
        for f in failures { print("  - \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: helpers

    static var testWindows: [NSWindow] = []

    static func closeTestWindows() {
        testWindows.forEach { $0.orderOut(nil) }
        testWindows.removeAll()
    }

    static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    static var screen: NSScreen { Stage.testScreen ?? NSScreen.main ?? NSScreen.screens[0] }

    /// A normal window (layer 0, so the window picker sees it) with a fixed drawing.
    static func testWindow(_ rect: CGRect, title: String = "Teste", view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.setFrame(w.frameRect(forContentRect: rect), display: true)
        w.orderFrontRegardless()
        testWindows.append(w)
        return w
    }

    static func contentRectOnScreen(_ w: NSWindow) -> CGRect { w.convertToScreen(w.contentView!.frame) }

    static func save(_ img: CGImage?, _ name: String) {
        guard let img, let evidence else { return }
        try? Library.encode(img, format: .png, scale: 2, downscale: false).write(to: evidence.appendingPathComponent(name))
    }

    static func close(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), tol: Int = 14) -> Bool {
        abs(Int(a.0) - Int(b.0)) <= tol && abs(Int(a.1) - Int(b.1)) <= tol && abs(Int(a.2) - Int(b.2)) <= tol
    }

    static func waitFor(_ timeout: Double = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await sleep(0.05)
        }
        return cond()
    }

    // Events into a window, in global AppKit points.
    static func mouse(_ type: NSEvent.EventType, _ global: CGPoint, in w: NSWindow, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        let local = CGPoint(x: global.x - w.frame.minX, y: global.y - w.frame.minY)
        guard let e = NSEvent.mouseEvent(with: type, location: local, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) else { return }
        w.sendEvent(e)
    }

    static func drag(from a: CGPoint, to b: CGPoint, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
        mouse(.leftMouseDown, a, in: w)
        for t in stride(from: 0.2, through: 1.0, by: 0.2) {
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: w, flags: flags)
        }
        mouse(.leftMouseUp, b, in: w)
    }

    static func key(_ code: Int, _ chars: String, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: UInt16(code)) else { return }
        w.sendEvent(e)
    }

    static func keyEquivalent(_ chars: String, _ code: Int, flags: NSEvent.ModifierFlags, in w: NSWindow) -> Bool {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: UInt16(code)) else { return false }
        return w.performKeyEquivalent(with: e)
    }

    /// The person may be using the Mac: put the test window back on top before each step.
    static func front() async {
        Stage.activate()
        quadWindow?.makeKeyAndOrderFront(nil)
        quadWindow?.orderFrontRegardless()
        await sleep(0.25)
    }

    static func overlay(for p: CGPoint) async -> OverlayWindow? {
        _ = await waitFor(8) { !(AreaSelector.current?.overlays.isEmpty ?? true) }
        return AreaSelector.current?.overlays.first { $0.frame.contains(p) }
    }

    /// Runs an action that opens the overlay, then drives the overlay.
    static func withOverlay<T>(_ start: @escaping () async -> T, drive: (OverlayWindow) async -> Void, at p: CGPoint) async -> T {
        await front()
        let task = Task { await start() }
        if let o = await overlay(for: p) { await drive(o) } else { check(false, "overlay opened") }
        return await task.value
    }

    // MARK: synthetic images

    /// A deterministic "page": rows of colored blocks and numbered lines, no long blank runs.
    static func page(width: Int, height: Int, seed: UInt64 = 7) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = seed
        func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var y = 0
        var n = 0
        while y < height {
            let h = 18 + Int(next() % 40)
            let gray = CGFloat(next() % 200) / 255
            ctx.setFillColor(NSColor(srgbRed: gray, green: CGFloat(next() % 255) / 255, blue: 0.4, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 8 + Int(next() % 60), y: height - y - h + 3, width: 60 + Int(next() % UInt64(width / 2)), height: h - 6))
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
            ("linha \(n)" as NSString).draw(at: CGPoint(x: width - 140, y: height - y - h + 4),
                                            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            y += h
            n += 1
        }
        return ctx.makeImage()!
    }

    static func compose(_ parts: [(CGImage, CGRect)], width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (img, r) in parts { ctx.draw(img, in: r) }
        return ctx.makeImage()!
    }

    /// Fraction of sampled pixels that match within a tolerance (same size required).
    static func similarity(_ a: CGImage, _ b: CGImage, tol: Int = 16, step: Int = 3) -> Double {
        guard a.width == b.width, a.height == b.height, let pa = RGBA(a), let pb = RGBA(b) else { return 0 }
        var same = 0, total = 0
        var y = 0
        while y < a.height {
            var x = 0
            while x < a.width {
                let i = y * pa.bytesPerRow + x * 4
                if abs(Int(pa.bytes[i]) - Int(pb.bytes[i])) <= tol && abs(Int(pa.bytes[i + 1]) - Int(pb.bytes[i + 1])) <= tol
                    && abs(Int(pa.bytes[i + 2]) - Int(pb.bytes[i + 2])) <= tol { same += 1 }
                total += 1
                x += step
            }
            y += step
        }
        return total == 0 ? 0 : Double(same) / Double(total)
    }

    // MARK: 1. stitcher

    /// Both tables carry every key, the interface follows the Mac's first language, and
    /// histories written with Portuguese source labels still read in the interface language.
    static func testLocalization() {
        section("Idiomas (inglês e português do Brasil)")
        func keys(_ lang: String) -> Set<String> {
            guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: lang),
                  let d = NSDictionary(contentsOf: url) as? [String: String] else { return [] }
            return Set(d.keys)
        }
        let en = keys("en"), pt = keys("pt-BR")
        check(!en.isEmpty && en == pt, "as duas tabelas têm as mesmas chaves (\(en.count))",
              "só em en: \(en.subtracting(pt).sorted()), só em pt-BR: \(pt.subtracting(en).sorted())")
        let first = Locale.preferredLanguages.first ?? "en"
        check(L10n.isPortuguese == first.lowercased().hasPrefix("pt"), "segue o primeiro idioma do Mac (\(first))")
        let expected = L10n.isPortuguese ? "Janela" : "Window"
        let legacy = Capture(id: UUID(), date: Date(), kind: .image, file: "", savedPath: nil, width: 1, height: 1, scale: 1, source: "Janela")
        var current = legacy; current.source = "window"
        check(legacy.sourceTitle == expected && current.sourceTitle == expected, "origem antiga e nova no idioma da interface")
        check(L("settings|Thin") == (L10n.isPortuguese ? "Fina" : "Thin"), "chave com contexto mostra o texto, nunca a chave")
    }

    static func testStitcherSynthetic() async {
        section("Costura da captura com rolagem (quadros sintéticos)")
        let W = 640, viewH = 600, header = 70, footer = 40
        let doc = page(width: W, height: 3200)
        let headerImg = page(width: W, height: header, seed: 99)
        let footerImg = page(width: W, height: footer, seed: 42)
        let body = viewH - header - footer
        var offsets = [0]
        let steps = [130, 211, 37, 260, 180, 300, 95, 410, 222, 160]
        var i = 0
        while offsets.last! + body < 3200 {
            offsets.append(min(offsets.last! + steps[i % steps.count], 3200 - body))
            i += 1
        }
        offsets.append(offsets.last!)   // a still frame at the end
        let st = Stitcher(ignoreSidePixels: 24)
        for (k, off) in offsets.enumerated() {
            let slice = doc.cropping(to: CGRect(x: 0, y: off, width: W, height: body))!
            // A fake overlay scroller on the right that moves every frame.
            let scroller = page(width: 10, height: viewH, seed: UInt64(1000 + k))
            let frame = compose([(headerImg, CGRect(x: 0, y: viewH - header, width: W, height: header)),
                                 (slice, CGRect(x: 0, y: footer, width: W, height: body)),
                                 (footerImg, CGRect(x: 0, y: 0, width: W, height: footer)),
                                 (scroller, CGRect(x: W - 10, y: 0, width: 10, height: viewH))], width: W, height: viewH)
            st.add(frame)
        }
        let result = st.result()
        let expected = compose([(headerImg, CGRect(x: 0, y: 3200 + footer, width: W, height: header)),
                                (doc, CGRect(x: 0, y: footer, width: W, height: 3200)),
                                (footerImg, CGRect(x: 0, y: 0, width: W, height: footer))], width: W, height: header + 3200 + footer)
        check(result?.height == expected.height, "altura costurada = cabeçalho + página + rodapé", "\(result?.height ?? 0) vs \(expected.height)")
        if let result {
            // Compare without the scroller column.
            let a = result.cropping(to: CGRect(x: 0, y: 0, width: W - 10, height: result.height))!
            let b = expected.cropping(to: CGRect(x: 0, y: 0, width: W - 10, height: min(result.height, expected.height)))!
            let sim = a.height == b.height ? similarity(a, b, tol: 0, step: 2) : 0
            check(sim > 0.999, "pixels idênticos à página original", "similaridade \(sim)")
            save(result, "1-stitch-synthetic.png")
        }
        check(st.stillFrames >= 1, "quadro parado no fim é ignorado")
    }

    // MARK: 2. prefs and hotkeys

    static func testPrefsAndHotkeys() async {
        section("Ajustes e atalhos globais")
        let p = Prefs.shared
        p.imageFormat = .jpeg
        p.timerSeconds = 10
        let again = Prefs(store: p.store)
        check(again.imageFormat == .jpeg && again.timerSeconds == 10, "ajustes persistem")
        p.reset()
        p.saveFolder = home.appendingPathComponent("Saved").path
        p.playSound = false; p.quickAccessAutoClose = 0; p.windowShadow = false
        check(Prefs(store: p.store).imageFormat == .png, "voltar ao padrão")

        Hotkeys.shared.registerAll()
        check(Hotkeys.shared.registeredCount == Shortcut.defaults.count && Hotkeys.shared.failed.isEmpty,
              "8 atalhos registrados no sistema", "\(Hotkeys.shared.registeredCount), falhou: \(Hotkeys.shared.failed)")
        var got: HotAction?
        Hotkeys.shared.onAction = { got = $0 }
        Hotkeys.shared.fire(index: UInt32(HotAction.allCases.firstIndex(of: .scrolling)!))
        _ = await waitFor(1) { got != nil }
        check(got == .scrolling, "atalho chega na ação certa")
        check(Shortcut.defaults[.area]?.display == "⌥⇧⌘4", "atalho legível (⌥⇧⌘4)")
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K))!
        check(Shortcut(event: ev)?.display == "⇧⌘K", "gravador de atalho lê ⇧⌘K")
        Hotkeys.shared.paused = true
        check(Hotkeys.shared.registeredCount == 0, "atalhos pausam enquanto se grava um novo")
        Hotkeys.shared.paused = Stage.isolated   // isolated: leave the real app's shortcuts alone
        Hotkeys.shared.onAction = nil

        // No Dock icon, the app's own glyph in the menu bar.
        check(Bundle.main.infoDictionary?["LSUIElement"] as? Bool == true, "sem ícone no Dock")
        if let glyph = StatusMenu.icon("menubar", size: 18), let cg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil), let px = RGBA(cg) {
            // Template image: ink at the square's edge, the S cut out of the middle.
            check(glyph.isTemplate && px.pixel(1, 1).3 > 200, "ícone da barra é o quadrado do app, em modelo do macOS")
            var cut = 0
            for y in cg.height / 4..<cg.height * 3 / 4 { for x in cg.width / 4..<cg.width * 3 / 4 where px.pixel(x, y).3 < 60 { cut += 1 } }
            check(cut > cg.width * cg.height / 16, "o S aparece recortado no quadrado", "\(cut) pixels vazados")
            save(cg, "2-menubar-icon.png")
        } else { check(false, "ícone da barra de menus") }
    }

    // MARK: 3. real capture

    final class Quadrants: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let w = bounds.width / 2, h = bounds.height / 2
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); CGRect(x: 0, y: h, width: w, height: h).fill()
            NSColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1).setFill(); CGRect(x: w, y: h, width: w, height: h).fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill()
            NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1).setFill(); CGRect(x: w, y: 0, width: w, height: h).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
            ("Captura de tela 2026" as NSString).draw(at: CGPoint(x: 20, y: h + 20), withAttributes: attrs)
        }
    }

    static var quadWindow: NSWindow!
    static var quadRect: CGRect = .zero

    static func testRealCapture() async {
        section("Captura real pelo ScreenCaptureKit")
        let vf = screen.visibleFrame
        let rect = CGRect(x: vf.minX + 120, y: vf.maxY - 520, width: 400, height: 300)
        quadWindow = testWindow(rect, title: "Quadrantes", view: Quadrants())
        Stage.activate()
        await sleep(0.6)
        quadRect = contentRectOnScreen(quadWindow)
        let scale = screen.backingScaleFactor
        do {
            let img = try await ScreenGrabber.capture(rect: quadRect)
            check(img.width == Int(quadRect.width * scale) && img.height == Int(quadRect.height * scale),
                  "tamanho em pixels = pontos × \(Int(scale))", "\(img.width)×\(img.height)")
            let px = RGBA(img)!
            let qw = img.width / 4, qh = img.height / 4
            check(close(px.pixel(qw, qh), (255, 0, 0)), "canto de cima à esquerda é vermelho", "\(px.pixel(qw, qh))")
            check(close(px.pixel(qw * 3, qh), (0, 204, 0)), "canto de cima à direita é verde", "\(px.pixel(qw * 3, qh))")
            check(close(px.pixel(qw, qh * 3), (0, 0, 255)), "canto de baixo à esquerda é azul", "\(px.pixel(qw, qh * 3))")
            check(close(px.pixel(qw * 3, qh * 3), (255, 255, 0)), "canto de baixo à direita é amarelo", "\(px.pixel(qw * 3, qh * 3))")
            save(img, "3-real-capture.png")
        } catch {
            check(false, "captura real", error.localizedDescription)
        }
        // Our own excluded windows stay out of captures.
        HUD.shared.toast("Esta mensagem não pode sair na captura", seconds: 3)
        await sleep(0.4)
        if let vis = (Geometry.mouseScreen ?? screen).visibleFrame as CGRect?,
           let img = try? await ScreenGrabber.capture(rect: CGRect(x: vis.midX - 200, y: vis.maxY - 80, width: 400, height: 80)) {
            let px = RGBA(img)!
            var dark = 0
            for x in stride(from: 0, to: img.width, by: 4) where close(px.pixel(x, img.height / 2), (17, 24, 28), tol: 6) { dark += 1 }
            check(dark < img.width / 16, "o aviso do próprio app não aparece na captura", "\(dark) pixels do aviso")
        }
        HUD.shared.hide()
    }

    // MARK: 4. area selection

    static func testAreaSelection() async {
        section("Seleção de área (tela congelada, mouse e teclado)")
        let scale = screen.backingScaleFactor
        let a = CGPoint(x: quadRect.minX + 20, y: quadRect.maxY - 20)
        let b = CGPoint(x: quadRect.minX + 220, y: quadRect.maxY - 140)
        let r1 = await withOverlay({ await AreaSelector.select(.area) }, drive: { o in
            check(o.level == .screenSaver && CaptureExclusion.windowNumbers.contains(o.windowNumber), "camada cobre a tela e fica fora das capturas")
            mouse(.mouseMoved, a, in: o)
            drag(from: a, to: b, in: o)
        }, at: a)
        let expected = CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y)
        check(r1?.rect == expected, "arrastar devolve a área exata", "\(String(describing: r1?.rect)) vs \(expected)")
        if let crop = r1?.frozenCrop {
            check(crop.width == Int(expected.width * scale) && crop.height == Int(expected.height * scale), "recorte da tela congelada no tamanho certo")
            let px = RGBA(crop)!
            check(close(px.pixel(crop.width / 4, crop.height / 2), (255, 0, 0)), "recorte mostra o vermelho do quadrante", "\(px.pixel(crop.width / 4, crop.height / 2))")
            save(crop, "4-area.png")
        } else { check(false, "recorte da tela congelada") }

        let r2 = await withOverlay({ await AreaSelector.select(.area) }, drive: { o in key(53, "\u{1b}", in: o) }, at: a)
        check(r2 == nil && AreaSelector.current == nil, "Esc cancela e fecha a camada")

        let r3 = await withOverlay({ await AreaSelector.select(.area) }, drive: { o in
            drag(from: a, to: CGPoint(x: a.x + 300, y: a.y - 100), in: o, flags: .shift)
        }, at: a)
        check(r3.map { abs($0.rect.width - $0.rect.height) < 1 } ?? false, "Shift faz um quadrado", "\(String(describing: r3?.rect))")

        let r4 = await withOverlay({ await AreaSelector.select(.area) }, drive: { o in
            mouse(.leftMouseDown, a, in: o); mouse(.leftMouseUp, a, in: o)
        }, at: a)
        check(r4?.rect == screen.frame, "clique sem arrastar pega a tela inteira")

        let r5 = await withOverlay({ await AreaSelector.select(.area) }, drive: { o in
            key(49, " ", in: o)    // Space: pick windows
            let c = CGPoint(x: quadRect.midX, y: quadRect.midY)
            mouse(.mouseMoved, c, in: o)
            mouse(.leftMouseDown, c, in: o); mouse(.leftMouseUp, c, in: o)
        }, at: a)
        check(r5?.window?.id == CGWindowID(quadWindow.windowNumber), "Espaço troca para janela e o clique escolhe a janela de teste",
              "\(String(describing: r5?.window))")
    }

    // MARK: 5. full flow + Quick Access

    static func testAreaFlowAndQuickAccess() async {
        section("Fluxo completo: capturar, salvar, copiar, acesso rápido")
        let a = CGPoint(x: quadRect.minX + 10, y: quadRect.maxY - 10)
        let b = CGPoint(x: quadRect.maxX - 10, y: quadRect.minY + 10)
        let before = Library.shared.items.count
        await withOverlay({ await CaptureController.shared.perform(.area) }, drive: { o in drag(from: a, to: b, in: o) }, at: a)
        guard let c = CaptureController.shared.last, Library.shared.items.count == before + 1 else {
            check(false, "captura entrou no histórico"); return
        }
        check(true, "captura entrou no histórico")
        let saved = c.savedPath.map { URL(fileURLWithPath: $0) }
        check(saved.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "arquivo salvo na pasta escolhida")
        if let saved {
            check(saved.lastPathComponent.hasPrefix(L("Screenshot") + " ") && saved.pathExtension == "png", "nome no padrão (\(saved.lastPathComponent))")
            if let src = CGImageSourceCreateWithURL(saved as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                check((props[kCGImagePropertyDPIWidth] as? Double ?? 0) == 72 * Double(screen.backingScaleFactor), "PNG marcado como Retina (\(Int(72 * screen.backingScaleFactor)) dpi)")
            }
        }
        let pbImage = NSImage(pasteboard: Stage.board)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        check(pbImage?.width == c.width && pbImage?.height == c.height, "imagem copiada para a área de transferência")
        check(QuickAccess.shared.ids.last == c.id && QuickAccess.shared.panel(c.id)?.isVisible == true, "acesso rápido aparece")
        if let panel = QuickAccess.shared.panel(c.id), let v = panel.contentView {
            let vf = (Geometry.mouseScreen ?? screen).visibleFrame
            check(abs(panel.frame.minX - (vf.minX + 16)) < 1 && abs(panel.frame.minY - (vf.minY + 16)) < 1, "no canto de baixo à esquerda")
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                save(rep.cgImage, "5-quick-access.png")
            }
        }
        Stage.board.clearContents()
        QuickAccess.shared.copy(c.id)
        check(!QuickAccess.shared.ids.contains(c.id), "Copiar tira a miniatura do canto")
        QuickAccess.shared.show(c)
        check(NSImage(pasteboard: Stage.board) != nil, "Copiar no acesso rápido")
        check(QuickAccess.shared.save(c.id) == saved, "Salvar de novo grava no mesmo arquivo")
        check(!QuickAccess.shared.ids.contains(c.id), "Salvar tira a miniatura do canto")
        QuickAccess.shared.show(c)
        QuickAccess.shared.pin(c.id)
        check(PinWindow.open.count == 1 && !QuickAccess.shared.ids.contains(c.id), "Fixar abre a imagem fixada e fecha a miniatura")
        PinWindow.open.forEach { $0.closePin() }

        // Second capture: auto close, annotate, delete.
        Prefs.shared.quickAccessAutoClose = 1
        let c2 = CaptureController.shared.finish(page(width: 400, height: 300), scale: 2, source: "Teste")
        check(QuickAccess.shared.ids.contains(c2.id), "segunda miniatura empilha")
        _ = await waitFor(3) { !QuickAccess.shared.ids.contains(c2.id) }
        check(!QuickAccess.shared.ids.contains(c2.id), "fecha sozinha depois do tempo escolhido")
        Prefs.shared.quickAccessAutoClose = 0
        let c3 = CaptureController.shared.finish(page(width: 400, height: 300), scale: 2, source: "Teste")
        QuickAccess.shared.annotate(c3.id)
        check(EditorWindow.open.contains { $0.model.captureID == c3.id }, "Anotar abre o editor com a captura")
        EditorWindow.open.forEach { $0.close() }
        let savedC3 = Library.shared.item(c3.id)?.savedPath
        QuickAccess.shared.delete(c3.id)
        check(Library.shared.item(c3.id) == nil && !(savedC3.map { FileManager.default.fileExists(atPath: $0) } ?? false),
              "Apagar tira do histórico e manda o arquivo para o Lixo")
        if let url = QuickAccess.shared.dragURL(c.id) {
            check(FileManager.default.fileExists(atPath: url.path), "arrastar entrega um arquivo")
        }
        QuickAccess.shared.closeAll()

        await front()
        await CaptureController.shared.perform(.previousArea)
        check(CaptureController.shared.last?.source == "area" && CaptureController.shared.last?.width == c.width, "repetir a área anterior")
        QuickAccess.shared.closeAll()
    }

    // MARK: 6. window capture

    static func testWindowCapture() async {
        section("Captura de janela")
        let scale = screen.backingScaleFactor
        let c = CGPoint(x: quadRect.midX, y: quadRect.midY)
        await withOverlay({ await CaptureController.shared.perform(.window) }, drive: { o in
            mouse(.mouseMoved, c, in: o)
            mouse(.leftMouseDown, c, in: o); mouse(.leftMouseUp, c, in: o)
        }, at: c)
        let frame = quadWindow.frame
        if let last = CaptureController.shared.last, last.source == "window" {
            check(abs(last.width - Int(frame.width * scale)) <= 2 && abs(last.height - Int(frame.height * scale)) <= 2,
                  "só a janela, sem sombra, no tamanho dela", "\(last.width)×\(last.height) vs \(frame.width * scale)×\(frame.height * scale)")
            save(Library.shared.image(last), "6-window.png")
        } else { check(false, "captura de janela") }

        Prefs.shared.windowBackground = .gray
        Prefs.shared.backgroundPadding = 40
        await withOverlay({ await CaptureController.shared.perform(.window) }, drive: { o in
            mouse(.leftMouseDown, c, in: o); mouse(.leftMouseUp, c, in: o)
        }, at: c)
        if let last = CaptureController.shared.last, let img = Library.shared.image(last) {
            check(abs(last.width - Int((frame.width + 80) * scale)) <= 2, "fundo com margem nas capturas de janela", "\(last.width)")
            let px = RGBA(img)!
            check(close(px.pixel(10, 10), (0xE5, 0xE7, 0xEB), tol: 2), "fundo cinza do sistema", "\(px.pixel(10, 10))")
            save(img, "6-window-backdrop.png")
        }
        Prefs.shared.windowBackground = .none
        QuickAccess.shared.closeAll()
    }

    // MARK: 7. OCR

    static func testTextRecognition() async {
        section("Capturar texto (reconhecimento no próprio Mac)")
        let a = CGPoint(x: quadRect.minX + 5, y: quadRect.maxY - 5)
        let b = CGPoint(x: quadRect.minX + 360, y: quadRect.midY + 5)
        Stage.board.clearContents()
        await withOverlay({ await CaptureController.shared.perform(.text) }, drive: { o in drag(from: a, to: b, in: o) }, at: a)
        let text = Stage.board.string(forType: .string) ?? ""
        check(text.contains("Captura de tela 2026"), "texto da tela vai para a área de transferência", "\"\(text)\"")
    }

    // MARK: 8. scrolling capture

    final class LongDoc: NSView {
        let image: CGImage
        init(image: CGImage, size: CGSize) { self.image = image; super.init(frame: CGRect(origin: .zero, size: size)) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
    }

    static func testScrollingCapture() async {
        section("Captura com rolagem, ao vivo, numa janela que rola")
        let scale = screen.backingScaleFactor
        let docPts = CGSize(width: 480, height: 2400)
        let docImg = page(width: Int(docPts.width * scale), height: Int(docPts.height * scale), seed: 2026)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: docPts.width, height: 360))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = LongDoc(image: docImg, size: docPts)
        let vf = screen.visibleFrame
        let w = testWindow(CGRect(x: vf.minX + 600, y: vf.maxY - 560, width: docPts.width, height: 360), title: "Página longa", view: scroll)
        w.level = .floating
        await sleep(0.5)
        let rect = contentRectOnScreen(w)
        // Two real frames, before and after one step: the matcher must find the exact shift.
        if let f0 = try? await ScreenGrabber.capture(rect: rect) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 97))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.display()
            await sleep(0.15)
            if let f1 = try? await ScreenGrabber.capture(rect: rect),
               let a = Stitcher.frame(f0, ignoreSides: Int(32 * scale)), let b = Stitcher.frame(f1, ignoreSides: Int(32 * scale)) {
                let (t, bt) = Stitcher.fixedEdges(a, b)
                let dy = Stitcher.shift(a, b, top: t, bottom: bt)
                check(dy == Int(97 * scale), "deslocamento medido entre dois quadros reais = 97 pt",
                      "fixos \(t)/\(bt), achou \(dy.map(String.init) ?? "nenhum")")
                save(f0, "8-frame0.png"); save(f1, "8-frame1.png")
            }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.display()
            await sleep(0.15)
        }
        let session = ScrollSession(rect: rect)
        session.manualTicks = true
        let task = Task { await session.run() }
        _ = await waitFor(3) { session.height > 0 }
        check(session.height == Int(rect.height * scale), "primeiro quadro entra inteiro")
        var y: CGFloat = 0
        let steps: [CGFloat] = [97, 140, 63, 151, 120, 88, 160]
        var k = 0
        while y < docPts.height - 360 {
            y = min(y + steps[k % steps.count], docPts.height - 360)
            k += 1
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.display()
            await sleep(0.12)
            await session.tick()
        }
        await session.tick()
        session.finish()
        let result = await task.value
        check(ScrollSession.current == nil, "moldura e painel somem ao concluir")
        guard let result else { check(false, "imagem costurada"); return }
        save(result, "8-scrolling.png")
        check(abs(result.height - docImg.height) <= 2, "altura = página inteira (\(docImg.height) px)", "\(result.height)")
        if abs(result.height - docImg.height) <= 2 {
            let h = min(result.height, docImg.height)
            let cut = Int(24 * scale)
            let a = result.cropping(to: CGRect(x: 0, y: 0, width: result.width - cut, height: h))!
            let b = docImg.cropping(to: CGRect(x: 0, y: 0, width: docImg.width - cut, height: h))!
            let sim = similarity(a, b, tol: 20, step: 3)
            check(sim > 0.98, "costura bate com a página original", "similaridade \(sim)")
        }

        // Scrolling by itself posts wheel events: needs Accessibility.
        if AXIsProcessTrusted(), !Stage.isolated {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            await sleep(0.3)
            let auto = ScrollSession(rect: rect)
            let t2 = Task { await auto.run() }
            _ = await waitFor(2) { auto.height > 0 }
            auto.toggleAuto()
            _ = await waitFor(20) { ScrollSession.current == nil }
            if ScrollSession.current != nil { auto.finish() }
            let r2 = await t2.value
            check(r2.map { abs($0.height - docImg.height) <= Int(4 * scale) } ?? false, "rolar sozinho chega ao fim e para", "\(r2?.height ?? 0)")
            save(r2, "8-scrolling-auto.png")
        } else {
            print("  skip  rolar sozinho (move o mouse da pessoa: só fora do modo isolado, com Acessibilidade)")
        }
        w.orderOut(nil)
    }

    // MARK: 9. editor

    static func testEditor() async {
        section("Editor de anotação (eventos de mouse e teclado no canvas)")
        let base = page(width: 1600, height: 1000, seed: 5)
        EditorWindow.show(image: base, scale: 2)
        guard let w = EditorWindow.open.last else { check(false, "editor abre"); return }
        w.setFrame(CGRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80, width: 1100, height: 760), display: true)
        await sleep(0.5)
        let m = w.model, cv = w.canvas
        check(w.titleVisibility == .hidden, "o título não fica por cima das ferramentas")
        func drags(_ v: NSView) -> Int { (v is WindowDragArea.DragView ? 1 : 0) + v.subviews.reduce(0) { $0 + drags($1) } }
        check(drags(w.contentView!) >= 1, "a barra de ferramentas arrasta a janela")
        func g(_ ix: CGFloat, _ iy: CGFloat) -> CGPoint {
            // image pixels → global screen point
            let v = cv.viewPoint(CGPoint(x: ix, y: iy))
            return w.convertPoint(toScreen: cv.convert(v, to: nil))
        }
        func drawWith(_ t: Tool, _ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
            m.tool = t
            drag(from: g(a.x, a.y), to: g(b.x, b.y), in: w, flags: flags)
        }
        drawWith(.arrow, CGPoint(x: 100, y: 900), CGPoint(x: 500, y: 700))
        drawWith(.line, CGPoint(x: 100, y: 600), CGPoint(x: 400, y: 610), flags: .shift)
        drawWith(.rect, CGPoint(x: 600, y: 900), CGPoint(x: 900, y: 700))
        drawWith(.filledRect, CGPoint(x: 950, y: 900), CGPoint(x: 1100, y: 800))
        drawWith(.ellipse, CGPoint(x: 1150, y: 900), CGPoint(x: 1450, y: 700))
        drawWith(.pencil, CGPoint(x: 100, y: 400), CGPoint(x: 300, y: 300))
        drawWith(.highlighter, CGPoint(x: 400, y: 400), CGPoint(x: 700, y: 400))
        drawWith(.blur, CGPoint(x: 800, y: 500), CGPoint(x: 1100, y: 300))
        drawWith(.spotlight, CGPoint(x: 1200, y: 500), CGPoint(x: 1500, y: 300))
        m.tool = .counter
        for x in [200.0, 300.0] { mouse(.leftMouseDown, g(x, 150), in: w); mouse(.leftMouseUp, g(x, 150), in: w) }
        let kinds = m.state.annotations.map(\.kind)
        check(kinds == [.arrow, .line, .rect, .filledRect, .ellipse, .pencil, .highlighter, .blur, .spotlight, .counter, .counter],
              "as 11 ferramentas de desenho criam a forma certa", "\(kinds.map(\.rawValue))")
        let line = m.state.annotations[1]
        check(abs(line.b.y - line.a.y) < 1, "Shift deixa a linha reta")
        check(m.state.annotations.filter { $0.kind == .counter }.map(\.number) == [1, 2], "contador numera 1, 2")

        m.tool = .text
        mouse(.leftMouseDown, g(500, 200), in: w); mouse(.leftMouseUp, g(500, 200), in: w)
        check(cv.isEditingText, "texto abre um campo no lugar do clique")
        cv.typeText("Olá, mundo")
        cv.commitText()
        check(m.state.annotations.last?.kind == .text && m.state.annotations.last?.text == "Olá, mundo", "texto vira anotação")

        // Select and move the rectangle by its edge.
        m.tool = .select
        let before = m.state.annotations[2].rect
        drag(from: g(600, 800), to: g(650, 760), in: w)
        let after = m.state.annotations[2].rect
        check(m.selectedID == m.state.annotations[2].id && abs(after.minX - before.minX - 50) < 2 && abs(after.minY - before.minY + 40) < 2,
              "selecionar e mover um retângulo", "\(before) → \(after)")
        m.colorIndex = 3
        check(m.state.annotations[2].color == 3, "trocar a cor muda a forma selecionada")
        key(51, "\u{7f}", in: w)
        check(!m.state.annotations.contains { $0.kind == .rect }, "⌫ apaga a seleção")
        check(keyEquivalent("z", kVK_ANSI_Z, flags: .command, in: w) && m.state.annotations.contains { $0.kind == .rect }, "⌘Z desfaz")
        check(keyEquivalent("z", kVK_ANSI_Z, flags: [.command, .shift], in: w) && !m.state.annotations.contains { $0.kind == .rect }, "⇧⌘Z refaz")
        _ = keyEquivalent("z", kVK_ANSI_Z, flags: .command, in: w)
        key(Int(kVK_ANSI_A), "a", in: w)
        check(m.tool == .arrow, "tecla A escolhe a seta")

        // 15-app-mac.md, "Anotação": the shape just drawn stays selected; pressing on it moves it,
        // ⌫ deletes it, pressing off it draws a new one, all without changing tools.
        let n0 = m.state.annotations.count
        drawWith(.arrow, CGPoint(x: 1200, y: 150), CGPoint(x: 1500, y: 150))
        let drawn = m.state.annotations.last
        check(m.state.annotations.count == n0 + 1 && m.selectedID == drawn?.id, "a seta recém-feita fica selecionada")
        drag(from: g(1350, 150), to: g(1350, 100), in: w)
        let moved = m.state.annotations.first { $0.id == drawn?.id }
        check(m.state.annotations.count == n0 + 1 && abs((moved?.a.y ?? 0) - 100) < 2 && m.tool == .arrow,
              "arrastar a seta com a ferramenta de seta move, não desenha outra", "\(String(describing: moved?.a))")
        drag(from: g(1200, 30), to: g(1500, 30), in: w)
        let second = m.state.annotations.last
        check(m.state.annotations.count == n0 + 2 && second?.id != drawn?.id && m.selectedID == second?.id,
              "fora da seta, desenha outra seta")
        key(51, "\u{7f}", in: w)
        check(m.state.annotations.count == n0 + 1 && !m.state.annotations.contains { $0.id == second?.id }, "⌫ logo depois de desenhar apaga a seta")
        m.selectedID = drawn?.id
        key(51, "\u{7f}", in: w)
        check(m.state.annotations.count == n0, "volta ao que era antes")

        // Pixels of the export.
        guard let out = m.export(), let px = RGBA(out), let bp = RGBA(base) else { check(false, "exportar"); return }
        check(out.width == 1600 && out.height == 1000, "exporta no tamanho da captura")
        // Blur: pixel blocks inside the region differ from the base and are flat.
        let bx = 900, by = 1000 - 400
        check(!close(px.pixel(bx, by), (bp.pixel(bx, by).0, bp.pixel(bx, by).1, bp.pixel(bx, by).2), tol: 0) || px.pixel(bx, by) == px.pixel(bx + 3, by),
              "desfocar pixeliza a área")
        // Spotlight: outside is darker than the base.
        let sx = 50, sy = 1000 - 950
        let dark = Int(px.pixel(sx, sy).0) + Int(px.pixel(sx, sy).1) + Int(px.pixel(sx, sy).2)
        let orig = Int(bp.pixel(sx, sy).0) + Int(bp.pixel(sx, sy).1) + Int(bp.pixel(sx, sy).2)
        check(dark < orig * 6 / 10 + 3, "destaque escurece o resto", "\(dark) vs \(orig)")
        // Filled rectangle center carries the ink (red, default).
        check(close(px.pixel(1025, 1000 - 850), (0xF0, 0x3E, 0x3E), tol: 4) || close(px.pixel(1025, 1000 - 850), (0x78, 0x1F, 0x1F), tol: 6),
              "retângulo cheio na cor escolhida", "\(px.pixel(1025, 150))")
        save(out, "9-editor-export.png")
        if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            save(rep.cgImage, "9-editor-window.png")
        }

        // Crop with the mouse.
        drawWith(.crop, CGPoint(x: 100, y: 900), CGPoint(x: 900, y: 300))
        check(m.state.crop == CGRect(x: 100, y: 300, width: 800, height: 600), "recortar pelo mouse", "\(String(describing: m.state.crop))")
        check(m.export()?.width == 800 && m.export()?.height == 600, "exporta só o recorte")
        m.setBackdrop(Backdrop(fill: .white, padding: 20))
        check(m.export()?.width == 880 && m.export()?.height == 680, "fundo branco com margem de 20 pt")
        save(m.export(), "9-editor-crop-backdrop.png")

        Stage.board.clearContents()
        w.copyImage()
        check(NSImage(pasteboard: Stage.board)?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 880, "⌘C copia a imagem anotada")
        let url = w.saveImage()
        check(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "Salvar grava na pasta")
        if let id = m.captureID, let c = Library.shared.item(id) {
            check(c.width == 880 && c.source == "editor", "imagem anotada entra no histórico")
        }
        check(w.dragFile().map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "Arrastar gera o arquivo")
        w.pinImage()
        check(PinWindow.open.count == 1, "Fixar a partir do editor")
        PinWindow.open.forEach { $0.closePin() }
        w.close()
        check(!EditorWindow.open.contains { $0 === w }, "fechar o editor")

        // Copiar and Salvar end the edit: the image goes out and the editor closes.
        if let c = Library.shared.items.first(where: { $0.isImage }) {
            EditorWindow.show(capture: c)
            await sleep(0.4)
            if let e = EditorWindow.open.last {
                Stage.board.clearContents()
                e.copyAndClose()
                await sleep(0.2)
                check(NSImage(pasteboard: Stage.board) != nil && !EditorWindow.open.contains { $0 === e }, "Copiar copia e fecha o editor")
            }
            EditorWindow.show(capture: c)
            await sleep(0.4)
            if let e = EditorWindow.open.last {
                e.saveAndClose()
                await sleep(0.2)
                check(!EditorWindow.open.contains { $0 === e }, "Salvar grava e fecha o editor")
            }
        }
    }

    // MARK: 10. pin

    static func testPin() async {
        section("Imagem fixada sobre as janelas")
        let img = page(width: 600, height: 400)
        let p = PinWindow.show(image: img, scale: 2)
        await sleep(0.3)
        check(p.level == .floating && p.isVisible, "fica acima das outras janelas")
        check(abs(p.frame.width - 300) < 1 && abs(p.frame.height - 200) < 1, "abre no tamanho real em pontos", "\(p.frame)")
        p.setOpacity(0.5)
        check(p.alphaValue == 0.5, "opacidade")
        Stage.board.clearContents()
        p.copyImage()
        check(NSImage(pasteboard: Stage.board) != nil, "copiar da imagem fixada")
        key(53, "\u{1b}", in: p)
        check(PinWindow.open.isEmpty && !p.isVisible, "Esc fecha")
    }

    // MARK: 11. recording

    final class Blinker: NSView {
        var phase = 0
        override func draw(_ dirtyRect: NSRect) {
            (phase % 2 == 0 ? NSColor.systemTeal : NSColor.systemOrange).setFill()
            bounds.fill()
            NSColor.black.setFill()
            CGRect(x: CGFloat(phase * 12 % Int(max(bounds.width, 1))), y: 20, width: 40, height: 40).fill()
        }
    }

    static func testRecording() async {
        section("Gravação de tela (MP4 e GIF)")
        let blinker = Blinker()
        let vf = screen.visibleFrame
        let w = testWindow(CGRect(x: vf.minX + 160, y: vf.minY + 140, width: 320, height: 200), title: "Gravação", view: blinker)
        w.level = .floating
        await sleep(0.4)
        let rect = contentRectOnScreen(w)
        let scale = screen.backingScaleFactor
        let anim = Task { @MainActor in
            while !Task.isCancelled { blinker.phase += 1; blinker.needsDisplay = true; try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        defer { anim.cancel() }

        let session = RecordingSession(rect: rect, gif: false)
        let task = Task { await session.run(countdown: 0) }
        _ = await waitFor(5) { session.startedAt != nil }
        let barDrags = NSApp.windows.filter { $0.isVisible && $0 is NSPanel }.reduce(0) { n, p in
            func drags(_ v: NSView) -> Int { (v is WindowDragArea.DragView ? 1 : 0) + v.subviews.reduce(0) { $0 + drags($1) } }
            return n + (p.contentView.map(drags) ?? 0)
        }
        check(barDrags >= 2, "a barra de gravação se arrasta pela alça e pelo fundo")
        check(StatusMenu.shared.item == nil || StatusMenu.shared.item?.menu == nil, "ícone da barra vira Parar")
        await sleep(2.2)
        session.stop()
        let url = await task.value
        check(url != nil && FileManager.default.fileExists(atPath: url!.path), "MP4 gravado")
        if let url {
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let size = (try? await track?.load(.naturalSize)) ?? .zero
            check(dur > 1.5 && dur < 4, "duração ≈ 2 s", "\(dur)")
            check(Int(size.width) == Int(rect.width * scale) / 2 * 2 && Int(size.height) == Int(rect.height * scale) / 2 * 2,
                  "vídeo no tamanho da área em Retina", "\(size)")
            check(session.frames > 20, "quadros gravados (\(session.frames))")
            if let c = await Library.shared.add(movie: url, gif: false, source: "recording") {
                check(c.kind == .video && Library.shared.thumbnail(c) != nil, "vídeo entra no histórico com miniatura")
                check(Library.shared.save(c).map { $0.lastPathComponent.hasPrefix(L("Recording") + " ") && $0.pathExtension == "mp4" } ?? false, "salva como \"Gravação … .mp4\"")
            }
        }

        let gs = RecordingSession(rect: rect, gif: true)
        let gt = Task { await gs.run(countdown: 0) }
        _ = await waitFor(5) { gs.startedAt != nil }
        await sleep(1.6)
        gs.stop()
        let gif = await gt.value
        if let gif, let src = CGImageSourceCreateWithURL(gif as CFURL, nil) {
            let n = CGImageSourceGetCount(src)
            check(gif.pathExtension == "gif" && n >= 15, "GIF animado (\(n) quadros)")
            if let first = CGImageSourceCreateImageAtIndex(src, 0, nil) { save(first, "11-gif-frame.png") }
        } else { check(false, "GIF animado") }

        let cs = RecordingSession(rect: rect, gif: false)
        let ct = Task { await cs.run(countdown: 2) }
        await sleep(0.5)
        check(cs.countdown > 0, "contagem antes de gravar")
        cs.cancel()
        let none = await ct.value
        check(none == nil && RecordingSession.current == nil, "cancelar não deixa arquivo")
        w.orderOut(nil)
    }

    // MARK: 12. timer, full screen

    static func testTimerAndFullscreen() async {
        section("Timer e tela inteira")
        Prefs.shared.timerSeconds = 1
        let a = CGPoint(x: quadRect.minX + 10, y: quadRect.maxY - 10)
        let b = CGPoint(x: quadRect.minX + 110, y: quadRect.maxY - 110)
        let t0 = Date()
        await withOverlay({ await CaptureController.shared.perform(.timer) }, drive: { o in drag(from: a, to: b, in: o) }, at: a)
        check(CaptureController.shared.last?.source == "timer" && Date().timeIntervalSince(t0) >= 1, "timer espera e captura a área")
        let before = CaptureController.shared.last?.id
        await CaptureController.shared.perform(.fullscreen)
        let s = Geometry.mouseScreen ?? screen
        if let c = CaptureController.shared.last, c.id != before {
            check(c.width == Int(s.frame.width * s.backingScaleFactor) && c.height == Int(s.frame.height * s.backingScaleFactor),
                  "tela inteira em resolução nativa", "\(c.width)×\(c.height)")
        } else { check(false, "tela inteira") }
        QuickAccess.shared.closeAll()
    }

    // MARK: 13. desktop icons, history

    static func testDesktopIconsAndHistory() async {
        section("Ícones da mesa e histórico")
        DesktopIcons.shared.show(true)
        check(DesktopIcons.shared.isHidden, "esconder os ícones da mesa")
        DesktopIcons.shared.show(false)
        check(!DesktopIcons.shared.isHidden, "mostrar de novo")

        let lib = Library.shared
        let n = lib.items.count
        check(n > 5, "histórico guarda as capturas (\(n))")
        HistoryWindow.show()
        await sleep(0.6)
        if let v = HistoryWindow.current?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            save(rep.cgImage, "13-history.png")
        }
        HistoryWindow.current?.close()
        Prefs.shared.historyDays = 30
        lib.prune(now: Date().addingTimeInterval(31 * 86_400))
        check(lib.items.isEmpty, "apaga o que passou do prazo")
        let saved = try? FileManager.default.contentsOfDirectory(atPath: Prefs.shared.saveFolder)
        check((saved?.count ?? 0) > 0, "arquivos salvos ficam onde estão")
    }
}
