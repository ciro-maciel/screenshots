import AppKit
import Darwin
import ScreenCaptureKit

/// `Screenshots --memtest` (run it with scripts/test.sh memtest): the heavy paths, many times
/// over, measuring the app's memory (the physical footprint, the number Activity Monitor shows)
/// after each. Memory must come back down after every capture and stay flat while recording,
/// however long the recording. The ceilings include what the test itself draws (its windows,
/// big synthetic pages) and the image caches macOS keeps; they catch regressions like the
/// 1 GB of version 0.1.9, not single megabytes.
@MainActor
enum MemTest {
    static var failures = 0

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func settle() async -> Double {
        // Let AppKit and Core Animation drain what they release at the end of the run loop turn.
        for _ in 0..<6 { await E2E.sleep(0.25) }
        return footprint()
    }

    static func report(_ name: String, _ mb: Double, limit: Double) {
        let ok = mb <= limit
        if !ok { failures += 1 }
        print(String(format: "  %@  %-48@ %7.1f MB  (limite %.0f)", ok ? "ok  " : "FAIL", name as NSString, mb, limit))
    }

    static func run() async -> Int32 {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-mem-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SCREENSHOT_HOME", home.path, 1)
        let p = Prefs.shared
        p.reset()
        p.saveFolder = home.appendingPathComponent("Saved").path
        p.playSound = false
        p.afterCopy = false
        guard ScreenGrabber.hasPermission else { print("Screen Recording off"); return 2 }

        let base = await settle()
        print(String(format: "Screenshots memtest — início %.1f MB, pid %d", base, getpid())); fflush(stdout)

        let vf = E2E.screen.visibleFrame
        if ProcessInfo.processInfo.environment["MEMTEST_ONLY"] != "record" {
            await heavyCaptures(base: base)
        }

        // 5. Recording: memory must stay flat, minute after minute. Clicks drawn all along.
        let blinker = E2E.Blinker()
        let rw = E2E.testWindow(CGRect(x: vf.minX + 160, y: vf.minY + 140, width: 640, height: 400), title: "Gravação", view: blinker)
        rw.level = .floating
        await E2E.sleep(0.4)
        let rrect = E2E.contentRectOnScreen(rw)
        let anim = Task { @MainActor in
            while !Task.isCancelled { blinker.phase += 1; blinker.needsDisplay = true; try? await Task.sleep(nanoseconds: 33_000_000) }
        }
        Recorder.trace("animation running")
        await E2E.sleep(2)
        Recorder.trace("animation after 2 s")
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Recorder.trace("shareable content alone")
        let beforeRec = footprint()
        Recorder.trace("before recording")
        let rec = RecordingSession(rect: rrect, gif: false)
        let rt = Task { await rec.run(countdown: 0) }
        _ = await E2E.waitFor(5) { rec.startedAt != nil }
        await E2E.sleep(5)
        let start = footprint()
        print(String(format: "        gravação aberta: +%.1f MB (codificador de vídeo e quadros da tela)", start - beforeRec)); fflush(stdout)
        let seconds = Int(ProcessInfo.processInfo.environment["MEMTEST_RECORD_SECONDS"] ?? "60") ?? 60
        var samples: [Double] = []
        for i in 1...seconds {
            if i % 2 == 0 { ClickRing.show(at: CGPoint(x: rrect.midX, y: rrect.midY)) }
            await E2E.sleep(1)
            if i % 10 == 0 { samples.append(footprint()) }
        }
        rec.stop()
        let url = await rt.value
        anim.cancel()
        rw.dispose()
        E2E.testWindows.removeAll { $0 === rw }
        let growth = (samples.last ?? start) - start
        print(String(format: "        gravando %d s a 30 quadros/s, com %d cliques: %@ MB", seconds, seconds / 2,
                     samples.map { String(format: "%.0f", $0) }.joined(separator: " → ")))
        print(String(format: "        quadros gravados: %d  (entregues por estado: %@)", rec.frames, "\(rec.statuses)"))
        report("crescimento durante a gravação", growth, limit: 6)
        if let url { try? FileManager.default.removeItem(at: url) }
        E2E.closeTestWindows()
        E2E.quadWindow?.dispose()
        E2E.quadWindow = nil
        report("depois de tudo, janelas de teste fechadas", await settle(), limit: base + 80)

        if let hold = ProcessInfo.processInfo.environment["MEMTEST_HOLD"], let s = Double(hold) {
            print("holding \(Int(s)) s for inspection, pid \(getpid())"); fflush(stdout)
            await E2E.sleep(s)
        }
        E2E.closeTestWindows()
        Prefs.shared.store.removePersistentDomain(forName: "click.ciromaciel.screenshots.tests")
        try? FileManager.default.removeItem(at: home)
        print(failures == 0 ? "\nmemória ok" : "\n\(failures) acima do limite")
        return failures == 0 ? 0 : 1
    }

    static func heavyCaptures(base: Double) async {
        let vf = E2E.screen.visibleFrame
        // 1. Area captures through the real overlay (frozen Retina screen each time).
        E2E.quadWindow = E2E.testWindow(CGRect(x: vf.minX + 120, y: vf.maxY - 520, width: 400, height: 300), title: "Quadrantes", view: E2E.Quadrants())
        await E2E.sleep(0.5)
        E2E.quadRect = E2E.contentRectOnScreen(E2E.quadWindow)
        let a = CGPoint(x: E2E.quadRect.minX + 10, y: E2E.quadRect.maxY - 10)
        let b = CGPoint(x: E2E.quadRect.maxX - 10, y: E2E.quadRect.minY + 10)
        var peak = 0.0
        for _ in 0..<15 {
            await E2E.withOverlay({ await CaptureController.shared.perform(.area) }, drive: { o in
                peak = max(peak, footprint())
                E2E.drag(from: a, to: b, in: o)
            }, at: a)
            QuickAccess.shared.closeAll()
        }
        print(String(format: "        pico durante a seleção (tela congelada): %.1f MB", peak))
        report("depois de 15 capturas de área", await settle(), limit: base + 35)
        if ProcessInfo.processInfo.environment["MEMTEST_STOP"] == "1" {
            print("holding, pid \(getpid())"); fflush(stdout)
            await E2E.sleep(60)
            exit(1)
        }

        // 2. Quick Access thumbnails and the history window.
        for _ in 0..<10 {
            let c = CaptureController.shared.finish(E2E.page(width: 2400, height: 1600), scale: 2, source: "Teste")
            QuickAccess.shared.close(c.id)
        }
        HistoryWindow.show(); await E2E.sleep(1); HistoryWindow.current?.performClose(nil)
        report("depois de 25 miniaturas e o histórico", await settle(), limit: base + 50)

        // 3. Editor: open, draw, export, close.
        for _ in 0..<5 {
            EditorWindow.show(image: E2E.page(width: 2880, height: 1800), scale: 2)
            guard let w = EditorWindow.open.last else { continue }
            w.model.add(Annotation(kind: .blur, a: CGPoint(x: 100, y: 100), b: CGPoint(x: 900, y: 700)))
            w.model.add(Annotation(kind: .arrow, a: CGPoint(x: 1000, y: 100), b: CGPoint(x: 1500, y: 700)))
            await E2E.sleep(0.4)
            _ = w.model.export()
            w.close()
        }
        report("depois de abrir e fechar o editor 5 vezes", await settle(), limit: base + 60)

        // 4. Scrolling capture of a long page, three times.
        let scale = E2E.screen.backingScaleFactor
        let docPts = CGSize(width: 480, height: 2400)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: docPts.width, height: 360))
        // The test's own page (18 MB) lives only in the test window.
        scroll.documentView = E2E.LongDoc(image: E2E.page(width: Int(docPts.width * scale), height: Int(docPts.height * scale), seed: 2026), size: docPts)
        let sw = E2E.testWindow(CGRect(x: vf.minX + 600, y: vf.maxY - 560, width: docPts.width, height: 360), title: "Página longa", view: scroll)
        sw.level = .floating
        await E2E.sleep(0.4)
        let rect = E2E.contentRectOnScreen(sw)
        for _ in 0..<3 {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            let s = ScrollSession(rect: rect)
            s.manualTicks = true
            let t = Task { await s.run() }
            _ = await E2E.waitFor(3) { s.height > 0 }
            var y: CGFloat = 0
            while y < docPts.height - 360 {
                y = min(y + 120, docPts.height - 360)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView); scroll.display()
                await E2E.sleep(0.1)
                await s.tick()
                peak = max(peak, footprint())
            }
            s.finish()
            if let img = await t.value { CaptureController.shared.finish(img, scale: scale, source: "scrolling") }
            QuickAccess.shared.closeAll()
        }
        sw.dispose()
        E2E.testWindows.removeAll { $0 === sw }
        report("depois de 3 capturas com rolagem", await settle(), limit: base + 80)

    }
}
