import AppKit
import ScreenCaptureKit

/// Windows of ours that never appear in a capture: the selection overlay, Quick Access,
/// the recording bar, the scrolling frame, toasts. Pinned images are left in on purpose.
@MainActor
enum CaptureExclusion {
    private(set) static var windowNumbers: Set<Int> = []
    static func add(_ w: NSWindow) {
        w.sharingType = .none
        windowNumbers.insert(w.windowNumber)
    }
    static func remove(_ w: NSWindow) { windowNumbers.remove(w.windowNumber) }
}

enum CaptureError: LocalizedError {
    case noPermission, noDisplay, noWindow, empty
    var errorDescription: String? {
        switch self {
        case .noPermission: return L("Turn on Screenshots in Screen Recording, in System Settings.")
        case .noDisplay: return L("Couldn't find the screen for the capture.")
        case .noWindow: return L("The window closed before the capture.")
        case .empty: return L("The chosen area is empty.")
        }
    }
}

/// Screen geometry: AppKit uses one global space with the origin at the bottom left of the
/// main screen; ScreenCaptureKit and Core Graphics use the top left. Everything outside this
/// file speaks AppKit points.
enum Geometry {
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit global rect → Core Graphics global rect (top-left origin).
    static func toCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
    static func fromCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
    static func screen(for rect: CGRect) -> NSScreen? {
        screen(containing: CGPoint(x: rect.midX, y: rect.midY))
    }
    static var mouseScreen: NSScreen? { Stage.testScreen ?? screen(containing: NSEvent.mouseLocation) }
}

/// Pixels from the screen through ScreenCaptureKit.
enum ScreenGrabber {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
    }

    @MainActor
    private static func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let excluded = CaptureExclusion.windowNumbers
        let windows = content.windows.filter { excluded.contains(Int($0.windowID)) }
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    /// The whole screen at its native pixel size.
    @MainActor
    static func capture(screen: NSScreen, cursor: Bool = false) async throws -> CGImage {
        try await capture(rect: screen.frame, cursor: cursor)
    }

    /// A rect in AppKit points, clipped to the screen it sits on. Our excluded windows stay out.
    /// The pixels are copied out of the capture's IOSurface into an image of their own.
    @MainActor
    static func capture(rect: CGRect, cursor: Bool = false) async throws -> CGImage {
        let pb = try await captureBuffer(rect: rect, cursor: cursor)
        let frozen = FrozenScreen(buffer: pb)
        guard let img = frozen.crop(pixels: CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)) else { throw CaptureError.empty }
        return img
    }

    /// A rect as a pixel buffer (BGRA, in an IOSurface): for code that reads pixels, such as
    /// the scrolling capture, without Core Graphics decoding and caching a copy of each frame.
    @MainActor
    static func captureBuffer(rect: CGRect, cursor: Bool = false) async throws -> CVPixelBuffer {
        guard let screen = Geometry.screen(for: rect) else { throw CaptureError.noDisplay }
        let clipped = rect.intersection(screen.frame).integral
        guard clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.empty }
        let content = try await content()
        let id = Geometry.displayID(screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: clipped.minX - screen.frame.minX, y: screen.frame.maxY - clipped.maxY,
                                   width: clipped.width, height: clipped.height)
        config.width = Int((clipped.width * scale).rounded())
        config.height = Int((clipped.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = cursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.ignoreShadowsDisplay = true
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter(display: display, content: content), configuration: config)
        guard let pb = sample.imageBuffer else { throw CaptureError.empty }
        return pb
    }

    /// One window by itself, with or without its shadow, on a transparent background.
    @MainActor
    static func capture(windowID: CGWindowID, shadow: Bool) async throws -> CGImage {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
        guard let pb = sample.imageBuffer else { throw CaptureError.empty }
        let frozen = FrozenScreen(buffer: pb)
        guard let img = frozen.crop(pixels: CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height)) else { throw CaptureError.empty }
        return img
    }

    /// On-screen windows front to back, in AppKit points, for the window picker.
    struct WindowInfo: Equatable {
        let id: CGWindowID
        let frame: CGRect
        let app: String
        let title: String
        let pid: pid_t
    }

    @MainActor
    static func windows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let excluded = CaptureExclusion.windowNumbers
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            if excluded.contains(Int(id)) { return nil }
            if (w[kCGWindowAlpha as String] as? CGFloat ?? 1) < 0.05 { return nil }
            let cg = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard cg.width >= 40, cg.height >= 40 else { return nil }
            return WindowInfo(id: id, frame: Geometry.fromCG(cg),
                              app: w[kCGWindowOwnerName as String] as? String ?? "",
                              title: w[kCGWindowName as String] as? String ?? "", pid: pid)
        }
    }
}

extension CGImage {
    /// Pixels of a rect given in points relative to an image that covers `frame` (AppKit points).
    func crop(points rect: CGRect, imageFrame frame: CGRect) -> CGImage? {
        let sx = CGFloat(width) / frame.width
        let sy = CGFloat(height) / frame.height
        let px = CGRect(x: (rect.minX - frame.minX) * sx,
                        y: (frame.maxY - rect.maxY) * sy,
                        width: rect.width * sx, height: rect.height * sy).integral
        return cropping(to: px)
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

extension NSWindow {
    /// Done for good: out of the capture exclusions, its views dropped (with the images they
    /// hold) and closed, so AppKit lets go of it. orderOut alone keeps every byte alive.
    @MainActor
    func dispose() {
        CaptureExclusion.remove(self)
        orderOut(nil)
        contentView = nil
        close()
    }
}

extension CGImage {
    /// A copy no larger than `maxSide` on its long side, in a buffer of its own. ImageIO's
    /// thumbnails can come back bigger than asked and in a page-protected copy (~5 MB each).
    func fitted(maxSide: CGFloat) -> CGImage? {
        let s = min(1, maxSide / CGFloat(max(width, height)))
        let w = max(1, Int(CGFloat(width) * s)), h = max(1, Int(CGFloat(height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A copy that owns only its own pixels. A crop made with `cropping(to:)` keeps the whole
    /// parent image (a full Retina screen) alive for as long as the crop lives.
    func detached() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// Memory freed by the app goes back to macOS right away. The allocator keeps freed pages
/// for reuse until the system is under pressure; after a capture (a Retina screen is ~90 MB)
/// that would show as the app's memory for hours.
enum Memory {
    static func trim() { malloc_zone_pressure_relief(nil, 0) }
}
