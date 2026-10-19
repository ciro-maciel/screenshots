import CoreGraphics
import CoreVideo
import Accelerate
import Foundation

/// Joins frames of a region that scrolls down into one tall image.
///
/// Each frame becomes a strip of samples per row (every 3rd pixel, RGB), the side edges left
/// out: the overlay scroller comes and goes, and the window's rounded corners show what is
/// behind it. Screen captures carry a few levels of noise between frames, so rows are equal
/// within a tolerance, never by exact hash. Two frames match at the vertical shift where the
/// rows of the old frame, moved up, equal the rows of the new one. Rows that never move (a
/// sticky header or footer) are found on the first real shift and kept out of the matching;
/// rows of a single color match anything, so they never count as evidence. Blank rows taken
/// for a footer do no harm: content is appended as it enters the moving region, and the last
/// frame's footer closes the image.
final class Stitcher {
    struct Frame {
        let width: Int
        let samples: [UInt8]     // rows × stride
        let stride: Int
        let uniform: [Bool]
        /// The frame's pixels, kept only while they may still be written out (first and last).
        let pixels: RGBA
        var rows: Int { uniform.count }

        func rowEqual(_ i: Int, _ other: Frame, _ j: Int, tolerance: Int = 14) -> Bool {
            samples.withUnsafeBufferPointer { a in
                other.samples.withUnsafeBufferPointer { b in
                    let ia = i * stride, ib = j * other.stride
                    for k in 0..<stride where abs(Int(a[ia + k]) - Int(b[ib + k])) > tolerance { return false }
                    return true
                }
            }
        }
    }

    let maxHeight: Int
    private(set) var first: Frame?
    private var last: Frame?
    private var top = 0, bottom = 0
    private var locked = false
    /// The stitched rows go straight to a file, top first, and the result maps that file:
    /// a page of 40 000 rows costs no more memory than one of 400.
    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-stitch-\(UUID().uuidString).raw")
    private var file: FileHandle?
    private var finished: CGImage?
    private(set) var height = 0
    /// Frames that showed no movement in a row: the end of the page when scrolling by itself.
    private(set) var stillFrames = 0
    private(set) var lastShift = 0
    private let ignoreSides: Int

    init(maxHeight: Int = 40_000, ignoreSidePixels: Int = 40) {
        self.maxHeight = maxHeight
        self.ignoreSides = ignoreSidePixels
    }

    deinit {
        try? file?.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var isFull: Bool { height >= maxHeight }

    private func write(_ f: Frame, rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        if file == nil {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            file = try? FileHandle(forWritingTo: fileURL)
        }
        let bpr = f.pixels.bytesPerRow
        f.pixels.bytes.withUnsafeBytes { raw in
            file?.write(Data(raw[(rows.lowerBound * bpr)..<(rows.upperBound * bpr)]))
        }
    }

    /// Adds a frame; returns the rows of new content it brought (0 when nothing moved).
    @discardableResult
    func add(_ image: CGImage) -> Int {
        guard let px = RGBA(image) else { return 0 }
        return add(pixels: px)
    }

    @discardableResult
    func add(pixels px: RGBA) -> Int {
        guard finished == nil, let frame = Stitcher.frame(pixels: px, ignoreSides: ignoreSides) else { return 0 }
        guard let prev = last else {
            first = frame; last = frame; height = frame.rows
            return frame.rows
        }
        guard frame.width == prev.width, frame.rows == prev.rows else { return 0 }
        let h = frame.rows
        if Stitcher.same(prev, frame) { stillFrames += 1; lastShift = 0; return 0 }
        if !locked {
            (top, bottom) = Stitcher.fixedEdges(prev, frame)
        }
        guard let dy = Stitcher.shift(prev, frame, top: top, bottom: bottom) else {
            stillFrames += 1; lastShift = 0
            return 0
        }
        if !locked {
            locked = true
            // The first frame without its footer; the footer comes back at the end.
            write(first!, rows: 0..<(h - bottom))
            height = h - bottom
            first = nil
        }
        let take = min(dy, max(0, maxHeight - height))
        guard take > 0 else { last = frame; return 0 }
        write(frame, rows: (h - bottom - dy)..<(h - bottom - dy + take))
        height += take
        stillFrames = 0
        lastShift = dy
        last = frame
        return take
    }

    /// The tall image: first frame, every new slice, then the footer from the last frame.
    func result() -> CGImage? {
        if let finished { return finished }
        guard let last else { return nil }
        if !locked {
            write(last, rows: 0..<last.rows)
        } else if bottom > 0 {
            write(last, rows: (last.rows - bottom)..<last.rows)
        }
        try? file?.close()
        file = nil
        self.last = nil
        first = nil
        let w = last.width, bpr = w * 4
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped), data.count >= bpr,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        let rows = data.count / bpr
        finished = CGImage(width: w, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return finished
    }

    // MARK: matching

    static func frame(_ image: CGImage, ignoreSides: Int, step: Int = 3) -> Frame? {
        guard let px = RGBA(image) else { return nil }
        return frame(pixels: px, ignoreSides: ignoreSides, step: step)
    }

    static func frame(pixels px: RGBA, ignoreSides: Int, step: Int = 3) -> Frame? {
        let w = px.width, h = px.height
        guard w > 0, h > 0 else { return nil }
        let side = min(ignoreSides, w / 6)
        let xs = Array(Swift.stride(from: side, to: max(side + 1, w - side), by: step))
        let rowStride = xs.count * 3
        var samples = [UInt8](repeating: 0, count: rowStride * h)
        var uniform = [Bool](repeating: true, count: h)
        px.bytes.withUnsafeBufferPointer { buf in
            samples.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    let row = y * px.bytesPerRow
                    var lo = 255, hi = 0
                    var o = y * rowStride
                    for x in xs {
                        let i = row + x * 4
                        let r = buf[i], g = buf[i + 1], b = buf[i + 2]
                        out[o] = r; out[o + 1] = g; out[o + 2] = b
                        o += 3
                        let l = (Int(r) * 3 + Int(g) * 6 + Int(b)) / 10
                        if l < lo { lo = l }
                        if l > hi { hi = l }
                    }
                    uniform[y] = hi - lo <= 8
                }
            }
        }
        return Frame(width: w, samples: samples, stride: rowStride, uniform: uniform, pixels: px)
    }

    static func same(_ a: Frame, _ b: Frame) -> Bool {
        for i in 0..<a.rows where !a.rowEqual(i, b, i) { return false }
        return true
    }

    /// Rows equal at the same place in both frames, from the top and from the bottom.
    static func fixedEdges(_ a: Frame, _ b: Frame) -> (Int, Int) {
        let h = a.rows
        var top = 0
        while top < h / 2, a.rowEqual(top, b, top) { top += 1 }
        var bottom = 0
        while bottom < h / 3, a.rowEqual(h - 1 - bottom, b, h - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    /// How many rows the content moved up between two frames, within the region that scrolls.
    static func shift(_ a: Frame, _ b: Frame, top: Int, bottom: Int) -> Int? {
        let h = a.rows
        let m = h - top - bottom
        let minOverlap = max(12, m / 10)
        guard m > minOverlap + 1 else { return nil }
        var best: (dy: Int, matched: Int)?
        for dy in 1...(m - minOverlap) {
            let overlap = m - dy
            var matched = 0, evidence = 0, missed = 0
            let allowedMisses = overlap / 25
            var i = 0
            while i < overlap {
                let ia = top + dy + i, ib = top + i
                let eq = a.rowEqual(ia, b, ib)
                if !b.uniform[ib] {
                    evidence += 1
                    if eq { matched += 1 }
                }
                if !eq {
                    missed += 1
                    if missed > allowedMisses { break }
                }
                i += 1
            }
            guard missed <= allowedMisses, evidence >= 6, matched * 100 >= evidence * 96 else { continue }
            if best == nil || matched > best!.matched { best = (dy, matched) }
        }
        return best?.dy
    }
}

/// An image's pixels as tightly packed RGBA bytes, top row first.
struct RGBA {
    let width: Int, height: Int, bytesPerRow: Int
    var bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width; height = image.height; bytesPerRow = width * 4
        bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    /// Straight from a screen frame (BGRA in an IOSurface): rows copied and channels swapped
    /// by Accelerate. Drawing the frame as a CGImage instead leaves a decoded copy of every
    /// frame in Core Graphics' purgeable cache (~2.7 MB each, kept).
    init?(buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer); bytesPerRow = width * 4
        bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = width, h = height, dstBPR = bytesPerRow
        var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        let err = bytes.withUnsafeMutableBytes { raw -> vImage_Error in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dstBPR)
            let map: [UInt8] = [2, 1, 0, 3]   // BGRA → RGBA
            return vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags))
        }
        if err != kvImageNoError { return nil }
    }

    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = y * bytesPerRow + x * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}
