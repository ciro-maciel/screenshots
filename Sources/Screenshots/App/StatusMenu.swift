import AppKit

/// The icon in the menu bar and its menu. While recording, the icon becomes Stop.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private(set) var item: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon("menubar", size: 18)
        item.button?.toolTip = "Screenshots"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
    }

    func recording(_ on: Bool) {
        guard let item else { return }
        if on {
            item.menu = nil
            item.button?.image = Self.icon("player-stop", size: 18)
            item.button?.target = self
            item.button?.action = #selector(stopRecording)
            item.button?.toolTip = "Parar a gravação"
        } else {
            item.button?.image = Self.icon("menubar", size: 18)
            item.button?.action = nil
            item.button?.toolTip = "Screenshots"
            item.menu = menu
        }
    }

    @objc private func stopRecording() { RecordingSession.current?.stop() }

    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }

    func build(_ menu: NSMenu) {
        menu.removeAllItems()
        for a in [HotAction.area, .previousArea, .fullscreen, .window, .scrolling, .text] { menu.addItem(entry(a)) }
        let timer = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        timer.image = Self.icon("clock-hour-4")
        let sub = NSMenu()
        for s in [3, 5, 10] {
            let i = NSMenuItem(title: "\(s) segundos", action: #selector(timerCapture(_:)), keyEquivalent: "")
            i.target = self
            i.tag = s
            i.state = Prefs.shared.timerSeconds == s ? .on : .off
            sub.addItem(i)
        }
        timer.submenu = sub
        menu.addItem(timer)
        menu.addItem(.separator())
        menu.addItem(entry(.recordVideo))
        menu.addItem(entry(.recordGIF))
        menu.addItem(.separator())
        menu.addItem(plain("Anotar uma imagem…", "pencil", #selector(openImage)))
        let fromClipboard = plain("Anotar a imagem copiada", "photo", #selector(annotateClipboard))
        fromClipboard.isEnabled = Self.clipboardImage() != nil
        menu.addItem(fromClipboard)
        let pinClipboard = plain("Fixar a imagem copiada", "pin", #selector(pinClipboard))
        pinClipboard.isEnabled = fromClipboard.isEnabled
        menu.addItem(pinClipboard)
        menu.addItem(entry(.history))
        let icons = entry(.toggleIcons)
        icons.title = DesktopIcons.shared.isHidden ? "Mostrar os ícones da mesa" : "Esconder os ícones da mesa"
        icons.image = Self.icon(DesktopIcons.shared.isHidden ? "eye" : "eye-off")
        menu.addItem(icons)
        if !PinWindow.open.isEmpty {
            menu.addItem(plain("Fechar as imagens fixadas", "x", #selector(closePins)))
        }
        menu.addItem(.separator())
        let settings = plain("Ajustes…", "settings", #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(plain("Sair do Screenshots", "power", #selector(quit)))
    }

    private func entry(_ a: HotAction) -> NSMenuItem {
        let i = NSMenuItem(title: a.title, action: #selector(runAction(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = a.rawValue
        i.image = Self.icon(a.icon)
        if let sc = Prefs.shared.shortcuts[a] {
            i.keyEquivalent = sc.menuKey
            i.keyEquivalentModifierMask = sc.menuModifiers
        }
        if a == .previousArea { i.isEnabled = CaptureController.shared.lastArea != nil }
        return i
    }

    private func plain(_ title: String, _ icon: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.image = Self.icon(icon)
        return i
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = HotAction(rawValue: raw) else { return }
        // Let the menu close before the overlay takes the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { CaptureController.shared.run(a) }
    }

    @objc private func timerCapture(_ sender: NSMenuItem) {
        Prefs.shared.timerSeconds = sender.tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { CaptureController.shared.run(.timer) }
    }

    @objc private func openImage() {
        Stage.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
        EditorWindow.show(image: img, scale: max(1, CGFloat(dpi / 72).rounded()))
    }

    static func clipboardImage() -> CGImage? {
        guard let ns = NSImage(pasteboard: Stage.board) else { return nil }
        return ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @objc private func annotateClipboard() {
        guard let img = Self.clipboardImage() else { return }
        EditorWindow.show(image: img, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    @objc private func pinClipboard() {
        guard let img = Self.clipboardImage() else { return }
        PinWindow.show(image: img, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    @objc private func closePins() { PinWindow.open.forEach { $0.closePin() } }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    static func icon(_ name: String, size: CGFloat = 16) -> NSImage? {
        guard let src = Icon.image(name) else { return nil }
        let img = NSImage(size: CGSize(width: size, height: size), flipped: false) { r in
            src.draw(in: r)
            return true
        }
        img.isTemplate = true
        return img
    }
}
