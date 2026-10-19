import AppKit
import CoreText

/// Annotation ink is the person's content, drawn on their image, not interface: it needs
/// color to stand out on any screenshot. The interface around it stays in the gray ramp.
enum Palette {
    static let colors: [(name: String, color: NSColor)] = [
        ("Vermelho", NSColor(hex: 0xF03E3E)),
        ("Amarelo", NSColor(hex: 0xFAB005)),
        ("Verde", NSColor(hex: 0x37B24D)),
        ("Azul", NSColor(hex: 0x1C7ED6)),
        ("Preto", NSColor(hex: 0x11181C)),
        ("Branco", NSColor(hex: 0xFFFFFF)),
    ]
    static func color(_ i: Int) -> NSColor { colors[max(0, min(colors.count - 1, i))].color }
    /// Stroke widths in points: fino, médio, grosso.
    static let widths: [CGFloat] = [2, 4, 8]
    /// Text sizes in points for the same three steps.
    static let textSizes: [CGFloat] = [16, 22, 32]
}

struct Annotation: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case arrow, line, rect, filledRect, ellipse, text, pencil, highlighter, counter, blur, spotlight
    }

    var id = UUID()
    var kind: Kind
    /// Image pixels, origin at the bottom left of the uncropped image.
    var a: CGPoint
    var b: CGPoint
    var points: [CGPoint] = []
    var color: Int = 0
    var width: CGFloat = 8
    var text = ""
    var fontSize: CGFloat = 44
    var number = 0

    var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }

    /// Where it is, for hit testing and the selection frame.
    var bounds: CGRect {
        switch kind {
        case .pencil, .highlighter:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -width * 2, dy: -width * 2)
        case .text:
            let s = Annotation.textSize(text, fontSize: fontSize)
            return CGRect(x: a.x, y: a.y - s.height, width: s.width, height: s.height)
        case .counter:
            let d = counterDiameter
            return CGRect(x: a.x - d / 2, y: a.y - d / 2, width: d, height: d)
        case .line, .arrow:
            return rect.insetBy(dx: -width * 3, dy: -width * 3)
        default:
            return rect
        }
    }

    var counterDiameter: CGFloat { max(28, width * 5 + 18) }

    func moved(by d: CGVector) -> Annotation {
        var c = self
        c.a = CGPoint(x: a.x + d.dx, y: a.y + d.dy)
        c.b = CGPoint(x: b.x + d.dx, y: b.y + d.dy)
        c.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return c
    }

    /// Whether a point (image pixels) touches it, with some room for thin strokes.
    func hit(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow:
            return Annotation.distance(p, a, b) <= width + tolerance
        case .pencil, .highlighter:
            for i in 1..<max(points.count, 1) where Annotation.distance(p, points[i - 1], points[i]) <= width * (kind == .highlighter ? 2 : 1) + tolerance {
                return true
            }
            return false
        case .rect, .ellipse:
            let r = rect
            let outer = r.insetBy(dx: -width - tolerance, dy: -width - tolerance)
            let inner = r.insetBy(dx: width + tolerance, dy: width + tolerance)
            return outer.contains(p) && (inner.isNull || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func font(_ size: CGFloat) -> NSFont { NSFont(name: "Montserrat-Bold", size: size) ?? .boldSystemFont(ofSize: size) }

    static func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let s = ((text.isEmpty ? " " : text) as NSString).boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                                                      options: [.usesLineFragmentOrigin],
                                                                      attributes: [.font: font(fontSize)])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }
}

/// The frame around a capture: none, a solid surface or the wallpaper, with a margin.
struct Backdrop: Equatable {
    enum Fill: String, CaseIterable {
        case none, white, gray, black, wallpaper
        var title: String {
            switch self {
            case .none: return "Nenhum"
            case .white: return "Branco"
            case .gray: return "Cinza"
            case .black: return "Preto"
            case .wallpaper: return "Papel de parede"
            }
        }
    }
    var fill: Fill = .none
    /// Points around the image.
    var padding: CGFloat = 64
}

struct EditorState: Equatable {
    var annotations: [Annotation] = []
    /// Image pixels; nil = the whole image.
    var crop: CGRect?
    var backdrop = Backdrop()
}

/// Draws a capture with its annotations, crop and backdrop. The editor's canvas and the
/// exported file come from the same code.
enum Renderer {
    /// The finished image.
    static func render(base: CGImage, state: EditorState, scale: CGFloat, wallpaper: CGImage? = nil) -> CGImage? {
        let content = contentRect(base: base, state: state)
        let pad = state.backdrop.fill == .none ? 0 : (state.backdrop.padding * scale).rounded()
        let w = Int(content.width + pad * 2), h = Int(content.height + pad * 2)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        switch state.backdrop.fill {
        case .none: break
        case .white: ctx.setFillColor(NSColor.white.cgColor); ctx.fill(full)
        case .gray: ctx.setFillColor(NSColor(hex: 0xE5E7EB).cgColor); ctx.fill(full)
        case .black: ctx.setFillColor(NSColor(hex: 0x11181C).cgColor); ctx.fill(full)
        case .wallpaper:
            if let wallpaper {
                let s = max(full.width / CGFloat(wallpaper.width), full.height / CGFloat(wallpaper.height))
                let ww = CGFloat(wallpaper.width) * s, wh = CGFloat(wallpaper.height) * s
                ctx.interpolationQuality = .high
                ctx.draw(wallpaper, in: CGRect(x: (full.width - ww) / 2, y: (full.height - wh) / 2, width: ww, height: wh))
            } else {
                ctx.setFillColor(NSColor(hex: 0xE5E7EB).cgColor); ctx.fill(full)
            }
        }
        ctx.saveGState()
        ctx.translateBy(x: pad - content.minX, y: pad - content.minY)
        ctx.clip(to: content)
        drawContent(ctx, base: base, state: state, scale: scale, region: content)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func contentRect(base: CGImage, state: EditorState) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        return (state.crop ?? full).intersection(full).integral
    }

    /// Base image, blurs, spotlight, then every other annotation in order. The context is in
    /// image pixels.
    static func drawContent(_ ctx: CGContext, base: CGImage, state: EditorState, scale: CGFloat, region: CGRect) {
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let list = state.annotations
        for a in list where a.kind == .blur { draw(a, in: ctx, base: base, scale: scale) }
        let spots = list.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(region)
            for s in spots { path.addRect(s.rect) }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        for a in list where a.kind != .blur && a.kind != .spotlight { draw(a, in: ctx, base: base, scale: scale) }
    }

    static func draw(_ an: Annotation, in ctx: CGContext, base: CGImage?, scale: CGFloat) {
        let color = Palette.color(an.color)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(an.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch an.kind {
        case .rect:
            ctx.setLineJoin(.miter)
            ctx.stroke(an.rect.insetBy(dx: an.width / 2, dy: an.width / 2).standardized)
        case .filledRect:
            ctx.fill(an.rect)
        case .ellipse:
            ctx.strokeEllipse(in: an.rect.insetBy(dx: an.width / 2, dy: an.width / 2).standardized)
        case .line:
            ctx.move(to: an.a); ctx.addLine(to: an.b); ctx.strokePath()
        case .arrow:
            let len = hypot(an.b.x - an.a.x, an.b.y - an.a.y)
            guard len > 1 else { return }
            let head = min(len * 0.6, an.width * 3.2 + 14 * scale)
            let ang = atan2(an.b.y - an.a.y, an.b.x - an.a.x)
            let base = CGPoint(x: an.b.x - cos(ang) * head * 0.8, y: an.b.y - sin(ang) * head * 0.8)
            ctx.move(to: an.a); ctx.addLine(to: base); ctx.strokePath()
            let spread: CGFloat = .pi / 7
            ctx.move(to: an.b)
            ctx.addLine(to: CGPoint(x: an.b.x - cos(ang - spread) * head, y: an.b.y - sin(ang - spread) * head))
            ctx.addLine(to: CGPoint(x: an.b.x - cos(ang + spread) * head, y: an.b.y - sin(ang + spread) * head))
            ctx.closePath()
            ctx.fillPath()
        case .pencil:
            stroke(an.points, in: ctx)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(an.width * 3)
            ctx.setLineCap(.butt)
            stroke(an.points, in: ctx)
        case .counter:
            let d = an.counterDiameter
            let r = CGRect(x: an.a.x - d / 2, y: an.a.y - d / 2, width: d, height: d)
            ctx.fillEllipse(in: r)
            let ink: NSColor = an.color == 5 || an.color == 1 ? NSColor(hex: 0x11181C) : .white
            drawText("\(an.number)", in: ctx, font: Annotation.font(d * 0.5), color: ink, centeredIn: r)
        case .text:
            let s = Annotation.textSize(an.text, fontSize: an.fontSize)
            drawText(an.text, in: ctx, font: Annotation.font(an.fontSize), color: color,
                     at: CGRect(x: an.a.x, y: an.a.y - s.height, width: s.width, height: s.height))
        case .blur:
            guard let base else { return }
            let r = an.rect.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height)).integral
            guard r.width >= 2, r.height >= 2 else { return }
            let flipped = CGRect(x: r.minX, y: CGFloat(base.height) - r.maxY, width: r.width, height: r.height)
            guard let part = base.cropping(to: flipped) else { return }
            let block = max(8, 7 * scale)
            let sw = max(1, Int(r.width / block)), sh = max(1, Int(r.height / block))
            guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            small.interpolationQuality = .medium
            small.draw(part, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let tiny = small.makeImage() else { return }
            ctx.interpolationQuality = .none
            ctx.draw(tiny, in: r)
        case .spotlight:
            break
        }
    }

    private static func stroke(_ pts: [CGPoint], in ctx: CGContext) {
        guard let f = pts.first else { return }
        ctx.move(to: f)
        if pts.count == 1 { ctx.addLine(to: CGPoint(x: f.x + 0.1, y: f.y)) }
        // Smooth through midpoints.
        for i in 1..<max(pts.count, 1) {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i - 1])
        }
        if let l = pts.last { ctx.addLine(to: l) }
        ctx.strokePath()
    }

    private static func drawText(_ text: String, in ctx: CGContext, font: NSFont, color: NSColor, at rect: CGRect) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ text: String, in ctx: CGContext, font: NSFont, color: NSColor, centeredIn r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        (text as NSString).draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2 + font.descender * 0.15), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
