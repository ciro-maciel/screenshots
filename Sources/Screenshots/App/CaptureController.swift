import AppKit

/// Turns an action (shortcut or menu) into a capture and then does what the settings ask:
/// sound, history, save, copy, Quick Access, editor, pin.
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private(set) var busy = false
    var lastArea: CGRect?
    /// The latest capture, for the tests.
    private(set) var last: Capture?

    func run(_ action: HotAction) {
        if let rec = RecordingSession.current {
            if action == .recordVideo || action == .recordGIF { rec.stop() }
            return
        }
        switch action {
        case .toggleIcons: DesktopIcons.shared.toggle(); return
        case .history: HistoryWindow.show(); return
        default: break
        }
        if ScrollSession.current != nil || AreaSelector.current != nil || busy { return }
        guard ScreenGrabber.hasPermission else { WelcomeWindow.show(); return }
        busy = true
        Task {
            await perform(action)
            busy = false
        }
    }

    func perform(_ action: HotAction) async {
        await performAction(action)
        // Every frozen screen and crop of the capture is released by now: hand the pages back.
        Memory.trim()
    }

    private func performAction(_ action: HotAction) async {
        do {
            switch action {
            case .area:
                guard let sel = await AreaSelector.select(.area) else { return }
                lastArea = sel.rect
                let img = try await image(of: sel)
                finish(img, scale: sel.screen.backingScaleFactor, source: sel.window == nil ? "area" : "window")

            case .previousArea:
                guard let r = lastArea else { return await performAction(.area) }
                let img = try await ScreenGrabber.capture(rect: r)
                finish(img, scale: Geometry.screen(for: r)?.backingScaleFactor ?? 2, source: "area")

            case .fullscreen:
                guard let screen = Geometry.mouseScreen else { return }
                let img = try await withHiddenIcons { try await ScreenGrabber.capture(screen: screen) }
                finish(img, scale: screen.backingScaleFactor, source: "fullscreen")

            case .window:
                guard let sel = await AreaSelector.select(.window), let w = sel.window else { return }
                let img = try await ScreenGrabber.capture(windowID: w.id, shadow: Prefs.shared.windowShadow)
                let scale = CGFloat(img.width) / max(w.frame.width, 1)
                finish(withBackdrop(img, scale: scale), scale: scale.rounded(), source: "window")

            case .scrolling:
                guard let sel = await AreaSelector.select(.scrolling) else { return }
                guard let img = await ScrollSession(rect: sel.rect).run() else { return }
                finish(img, scale: sel.screen.backingScaleFactor, source: "scrolling")

            case .text:
                guard let sel = await AreaSelector.select(.text) else { return }
                let img = try await image(of: sel)
                let text = await TextRecognizer.recognize(img)
                if text.isEmpty {
                    HUD.shared.toast(L("No text found in that area."), error: true)
                } else {
                    Stage.board.clearContents()
                    Stage.board.setString(text, forType: .string)
                    let lines = text.split(separator: "\n").count
                    HUD.shared.toast(lines == 1 ? L("Text copied: 1 line") : L("Text copied: %d lines", lines))
                }

            case .recordVideo, .recordGIF:
                guard let sel = await AreaSelector.select(.record) else { return }
                let gif = action == .recordGIF
                guard let url = await RecordingSession(rect: sel.rect, gif: gif).run(),
                      let c = await Library.shared.add(movie: url, gif: gif, source: "recording") else { return }
                after(c)

            case .timer:
                guard let sel = await AreaSelector.select(.timer) else { return }
                lastArea = sel.rect
                _ = await HUD.shared.countdown(Prefs.shared.timerSeconds)
                let img = try await ScreenGrabber.capture(rect: sel.rect)
                finish(img, scale: sel.screen.backingScaleFactor, source: "timer")

            case .toggleIcons, .history:
                break
            }
        } catch {
            HUD.shared.toast(error.localizedDescription, error: true)
        }
    }

    /// The selection's pixels: from the frozen screen, or captured again now.
    private func image(of sel: AreaSelector.Result) async throws -> CGImage {
        if Prefs.shared.freezeScreen, let crop = sel.frozenCrop { return crop }
        return try await ScreenGrabber.capture(rect: sel.rect)
    }

    private func withHiddenIcons<T>(_ body: () async throws -> T) async throws -> T {
        let hide = Prefs.shared.hideIconsWhileCapturing && !DesktopIcons.shared.isHidden
        if hide { DesktopIcons.shared.show(true); try? await Task.sleep(nanoseconds: 150_000_000) }
        defer { if hide { DesktopIcons.shared.show(false) } }
        return try await body()
    }

    /// Window captures get the backdrop from the settings.
    private func withBackdrop(_ img: CGImage, scale: CGFloat) -> CGImage {
        let p = Prefs.shared
        guard p.windowBackground != .none else { return img }
        var wallpaper: CGImage?
        if p.windowBackground == .wallpaper, let s = NSScreen.main {
            wallpaper = DesktopIcons.wallpaper(for: s)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let state = EditorState(backdrop: Backdrop(fill: p.windowBackground, padding: CGFloat(p.backgroundPadding)))
        return Renderer.render(base: img, state: state, scale: scale, wallpaper: wallpaper) ?? img
    }

    @discardableResult
    func finish(_ image: CGImage, scale: CGFloat, source: String) -> Capture {
        if Prefs.shared.playSound { Self.shutter() }
        let c = Library.shared.add(image: image, scale: scale, source: source)
        after(c)
        return c
    }

    private func after(_ c: Capture) {
        let p = Prefs.shared
        var c = c
        if p.afterSave, Library.shared.save(c) != nil { c = Library.shared.item(c.id) ?? c }
        if p.afterCopy { Library.shared.copy(c) }
        if p.afterShowQuickAccess { QuickAccess.shared.show(c) }
        if p.afterOpenEditor, c.isImage { EditorWindow.show(capture: c) }
        if p.afterPin, c.isImage, let img = Library.shared.image(c) { PinWindow.show(image: img, scale: CGFloat(c.scale)) }
        if !p.afterShowQuickAccess && !p.afterOpenEditor && !p.afterPin {
            HUD.shared.toast(p.afterSave ? L("Capture saved") : (p.afterCopy ? L("Capture copied") : L("Capture kept in history")))
        }
        last = c
        Memory.trim()
    }

    private static let sound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)
    static func shutter() {
        sound?.stop()
        sound?.play()
    }
}
