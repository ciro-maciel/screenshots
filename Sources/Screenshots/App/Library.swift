import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One capture: a copy always lives in the history folder (Quick Access, dragging and the
/// editor read from it); the saved file in the person's folder is optional.
struct Capture: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, video, gif }
    let id: UUID
    let date: Date
    var kind: Kind
    var file: String            // name inside the history folder
    var savedPath: String?
    var width: Int
    var height: Int
    var scale: Double           // pixels per point when captured
    var source: String          // "area", "window"…: an identifier, shown through `sourceTitle`

    var isImage: Bool { kind == .image }

    /// The source in the interface language. Histories written before 0.3 kept the Portuguese
    /// label itself; both spellings land on the same text.
    var sourceTitle: String {
        switch source {
        case "area", "Área": return L("Area")
        case "window", "Janela": return L("Window")
        case "fullscreen", "Tela inteira": return L("Full Screen")
        case "scrolling", "Rolagem": return L("Scrolling")
        case "recording", "Gravação": return L("Recording")
        case "timer", "Timer": return L("Timer")
        case "editor", "Editor": return L("Editor")
        case "pinned", "Fixada": return L("Pinned")
        default: return source
        }
    }
}

@MainActor
@Observable
final class Library {
    static let shared = Library()

    let dir: URL
    private(set) var items: [Capture] = []
    /// Decoded thumbnails, 480 px at most, and only the last dozen seen (a few MB).
    @ObservationIgnored private let thumbCache = ThumbCache(limit: 12)

    init() {
        if let home = ProcessInfo.processInfo.environment["SCREENSHOT_HOME"] {
            dir = URL(fileURLWithPath: home).appendingPathComponent("History")
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screenshots/History")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder.iso.decode([Capture].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
        }
    }

    private var index: URL { dir.appendingPathComponent("index.json") }

    private func persist() {
        try? JSONEncoder.iso.encode(items).write(to: index, options: .atomic)
    }

    func url(_ c: Capture) -> URL { dir.appendingPathComponent(c.file) }

    func item(_ id: UUID) -> Capture? { items.first { $0.id == id } }

    // MARK: adding

    @discardableResult
    func add(image: CGImage, scale: CGFloat, source: String) -> Capture {
        let id = UUID()
        let file = "\(id.uuidString).png"
        try? Library.encode(image, format: .png, scale: scale, downscale: false).write(to: dir.appendingPathComponent(file))
        let c = Capture(id: id, date: Date(), kind: .image, file: file, savedPath: nil,
                        width: image.width, height: image.height, scale: Double(scale), source: source)
        items.insert(c, at: 0)
        persist()
        return c
    }

    @discardableResult
    func add(movie: URL, gif: Bool, source: String) async -> Capture? {
        let id = UUID()
        let file = "\(id.uuidString).\(gif ? "gif" : "mp4")"
        let dest = dir.appendingPathComponent(file)
        do { try FileManager.default.moveItem(at: movie, to: dest) } catch { return nil }
        var size = CGSize.zero
        if gif, let src = CGImageSourceCreateWithURL(dest as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            size = img.size
        } else if let track = try? await AVURLAsset(url: dest).loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize) {
            size = natural
        }
        let c = Capture(id: id, date: Date(), kind: gif ? .gif : .video, file: file, savedPath: nil,
                        width: Int(size.width), height: Int(size.height), scale: 1, source: source)
        items.insert(c, at: 0)
        persist()
        return c
    }

    /// The editor's result replaces the image (history copy, and the saved file if there is one).
    func replace(_ c: Capture, with image: CGImage) -> Capture {
        guard let i = items.firstIndex(where: { $0.id == c.id }) else { return c }
        try? Library.encode(image, format: .png, scale: CGFloat(c.scale), downscale: false).write(to: url(c))
        items[i].width = image.width
        items[i].height = image.height
        thumbCache.remove(c.id)
        if let saved = items[i].savedPath {
            let format: Prefs.ImageFormat = saved.lowercased().hasSuffix(".jpg") ? .jpeg : .png
            try? Library.encode(image, format: format, scale: CGFloat(c.scale), downscale: Prefs.shared.downscaleRetina)
                .write(to: URL(fileURLWithPath: saved))
        }
        persist()
        return items[i]
    }

    // MARK: actions

    /// Writes the capture into the chosen folder (or `to`). Returns the file.
    @discardableResult
    func save(_ c: Capture, to explicit: URL? = nil) -> URL? {
        guard let i = items.firstIndex(where: { $0.id == c.id }) else { return nil }
        let p = Prefs.shared
        let folder = URL(fileURLWithPath: p.saveFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest: URL
        if let explicit { dest = explicit }
        else if let saved = items[i].savedPath { dest = URL(fileURLWithPath: saved) }
        else {
            let ext = c.kind == .image ? p.imageFormat.ext : (c.kind == .gif ? "gif" : "mp4")
            let prefix = c.kind == .image ? p.fileNamePrefix : L("Recording")
            dest = Library.uniqueURL(folder: folder, name: Library.fileName(prefix: prefix, date: c.date), ext: ext)
        }
        do {
            if c.kind == .image {
                guard let img = image(c) else { return nil }
                let format: Prefs.ImageFormat = dest.pathExtension.lowercased() == "jpg" || dest.pathExtension.lowercased() == "jpeg" ? .jpeg : .png
                try Library.encode(img, format: format, scale: CGFloat(c.scale), downscale: p.downscaleRetina).write(to: dest)
            } else {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url(c), to: dest)
            }
        } catch {
            HUD.shared.toast(L("Couldn't save to %@.", folder.lastPathComponent), error: true)
            return nil
        }
        items[i].savedPath = dest.path
        persist()
        return dest
    }

    func copy(_ c: Capture) {
        let pb = Stage.board
        pb.clearContents()
        if c.kind == .image, let img = image(c) {
            let ns = NSImage(cgImage: img, size: CGSize(width: CGFloat(img.width) / CGFloat(c.scale), height: CGFloat(img.height) / CGFloat(c.scale)))
            pb.writeObjects([ns])
            if let png = try? Library.encode(img, format: .png, scale: CGFloat(c.scale), downscale: false) {
                pb.setData(png, forType: .png)
            }
        } else {
            pb.writeObjects([(c.savedPath.map { URL(fileURLWithPath: $0) } ?? url(c)) as NSURL])
        }
    }

    /// Removes the capture from the history and its saved file, if any.
    func delete(_ c: Capture) {
        try? FileManager.default.removeItem(at: url(c))
        if let saved = c.savedPath { try? FileManager.default.trashItem(at: URL(fileURLWithPath: saved), resultingItemURL: nil) }
        items.removeAll { $0.id == c.id }
        thumbCache.remove(c.id)
        persist()
    }

    /// Drops what is older than the history setting. Saved files stay where they are.
    func prune(now: Date = Date()) {
        let days = Prefs.shared.historyDays
        guard days >= 0 else { return }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        for c in items where c.date < limit || days == 0 {
            try? FileManager.default.removeItem(at: url(c))
            thumbCache.remove(c.id)
        }
        items.removeAll { $0.date < limit || days == 0 }
        persist()
    }

    func clear() {
        for c in items { try? FileManager.default.removeItem(at: url(c)) }
        items.removeAll()
        thumbCache.removeAll()
        persist()
    }

    // MARK: reading

    func image(_ c: Capture) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(c) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func thumbnail(_ c: Capture, maxSide: CGFloat = 480) -> NSImage? {
        if let hit = thumbCache.get(c.id) { return hit }
        var cg: CGImage?
        if c.kind == .video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url(c)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxSide, height: maxSide)
            cg = try? gen.copyCGImage(at: .zero, actualTime: nil)
        } else if let src = CGImageSourceCreateWithURL(url(c) as CFURL, nil) {
            // A very long page or very wide strip shows only its start in the card (see
            // CardThumbnail): decode it big enough that the start is sharp, then cut it.
            let crop = Library.cardCrop(width: c.width, height: c.height)
            let decodeSide = crop == nil ? maxSide : min(8000, maxSide * CGFloat(max(c.width, c.height)) / CGFloat(max(1, min(c.width, c.height))) * 1.7)
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: decodeSide,
                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            if let crop, let full = cg {
                let r = CGRect(x: 0, y: 0, width: CGFloat(full.width) * crop.width, height: CGFloat(full.height) * crop.height).integral
                cg = full.cropping(to: r)
            }
        }
        // ImageIO hands thumbnails back in a page-protected copy of ~5.6 MB each; a copy of our
        // own keeps a 480 px thumbnail at its real size (~600 KB).
        guard let cg = cg?.fitted(maxSide: maxSide) else { return nil }
        let img = NSImage(cgImage: cg, size: cg.size)
        thumbCache.set(c.id, img)
        return img
    }

    /// For captures far from the card's 4:3, the part the card shows: the top of a long page,
    /// the left of a wide strip, in the card's own proportion (fractions of the image). nil:
    /// the whole capture fits.
    static func cardCrop(width: Int, height: Int) -> CGSize? {
        let aspect = CGFloat(width) / CGFloat(max(height, 1))
        let card = (QuickAccess.width - 16) / (QuickAccess.height - 16)
        if aspect < card / 2.2 { return CGSize(width: 1, height: aspect / card) }
        if aspect > card * 2.2 { return CGSize(width: card / aspect, height: 1) }
        return nil
    }

    // MARK: files

    static func fileName(prefix: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = L("yyyy-MM-dd 'at' HH.mm.ss")
        return "\(prefix) \(f.string(from: date))"
    }

    static func uniqueURL(folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// PNG or JPEG with the DPI that tells apps the Retina size (144 for 2×).
    static func encode(_ image: CGImage, format: Prefs.ImageFormat, scale: CGFloat, downscale: Bool) throws -> Data {
        var img = image
        var dpiScale = scale
        if downscale, scale > 1, let small = resize(image, by: 1 / scale) { img = small; dpiScale = 1 }
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw CaptureError.empty }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * dpiScale, kCGImagePropertyDPIHeight: 72 * dpiScale]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.empty }
        return data as Data
    }

    static func resize(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(image.width) * factor)), h = max(1, Int(CGFloat(image.height) * factor))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }
}

/// The last few thumbnails, a hard limit (NSCache treats its limit as a hint).
final class ThumbCache {
    private let limit: Int
    private var order: [UUID] = []
    private var images: [UUID: NSImage] = [:]
    init(limit: Int) { self.limit = limit }

    func get(_ id: UUID) -> NSImage? {
        guard let img = images[id] else { return nil }
        order.removeAll { $0 == id }
        order.append(id)
        return img
    }
    func set(_ id: UUID, _ img: NSImage) {
        images[id] = img
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit { images[order.removeFirst()] = nil }
    }
    func remove(_ id: UUID) { images[id] = nil; order.removeAll { $0 == id } }
    func removeAll() { images.removeAll(); order.removeAll() }
}
