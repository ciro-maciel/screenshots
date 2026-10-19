import AppKit
import CoreVideo
import ScreenCaptureKit

/// A whole screen held still while an area is chosen. The pixels stay in the IOSurface that
/// ScreenCaptureKit filled (video memory, given back whole when released): the overlay shows
/// the surface itself, and only the chosen area, or the magnifier's few pixels, are copied out.
/// Drawing a crop of a CGImage instead makes Core Graphics copy the entire Retina screen into
/// a malloc block that the allocator then keeps (~90 MB per 5K screen).
final class FrozenScreen {
    let buffer: CVPixelBuffer
    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }
    var surface: IOSurfaceRef? { CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() }

    init(buffer: CVPixelBuffer) { self.buffer = buffer }

    /// From an image (the tests and the screen previews draw fake desktops).
    convenience init?(image: CGImage) {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.init(buffer: pb)
    }

    /// The whole screen, through ScreenCaptureKit, at its native pixel size.
    @MainActor
    static func capture(_ screen: NSScreen) async -> FrozenScreen? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == Geometry.displayID(screen) }) else { return nil }
        let excluded = CaptureExclusion.windowNumbers
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int((screen.frame.width * scale).rounded())
        config.height = Int((screen.frame.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.captureResolution = .best
        guard let sample = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config),
              let pb = sample.imageBuffer else { return nil }
        return FrozenScreen(buffer: pb)
    }

    /// Pixels of a rect in image pixels (top-left origin), copied into an image of their own.
    func crop(pixels r: CGRect) -> CGImage? {
        let rect = r.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let w = Int(rect.width), h = Int(rect.height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let dst = ctx.data else { return nil }
        let srcBPR = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<h {
            memcpy(dst + row * w * 4, base + (Int(rect.minY) + row) * srcBPR + Int(rect.minX) * 4, w * 4)
        }
        return ctx.makeImage()
    }

    /// A rect in AppKit points of the screen this was taken from.
    func crop(points rect: CGRect, screenFrame frame: CGRect) -> CGImage? {
        let sx = CGFloat(width) / frame.width, sy = CGFloat(height) / frame.height
        return crop(pixels: CGRect(x: (rect.minX - frame.minX) * sx, y: (frame.maxY - rect.maxY) * sy,
                                   width: rect.width * sx, height: rect.height * sy))
    }
}
