import AppKit

/// Hides the icons on the desktop by covering them with the wallpaper: one window per screen,
/// just above the icon layer. Nothing in the Finder changes.
@MainActor
final class DesktopIcons {
    static let shared = DesktopIcons()
    private var windows: [NSWindow] = []
    var isHidden: Bool { !windows.isEmpty }

    func toggle() { show(!isHidden) }

    func show(_ hide: Bool) {
        windows.forEach { $0.dispose() }
        windows.removeAll()
        guard hide else { return }
        for screen in Stage.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.hasShadow = false
            let v = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            v.imageScaling = .scaleAxesIndependently
            v.image = Self.wallpaper(for: screen)
            w.contentView = v
            w.orderFront(nil)
            windows.append(w)
        }
    }

    /// The wallpaper scaled to fill the screen (the usual "Fill" setting).
    static func wallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let target = screen.frame.size
        let s = max(target.width / CGFloat(cg.width), target.height / CGFloat(cg.height))
        let w = target.width / s, h = target.height / s
        let crop = CGRect(x: (CGFloat(cg.width) - w) / 2, y: (CGFloat(cg.height) - h) / 2, width: w, height: h).integral
        guard let part = cg.cropping(to: crop) else { return img }
        return NSImage(cgImage: part, size: target)
    }
}
