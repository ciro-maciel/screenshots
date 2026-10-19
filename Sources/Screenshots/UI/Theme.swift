import SwiftUI
import AppKit
import CoreText

/// The Zen design system in SwiftUI: ten grays, Montserrat in four weights, radius zero, no shadow,
/// 1px rules in gray.2.
enum Zen {
    // 03-cor.md: the ramp. 0–3 surface and structure, 4–9 ink.
    static let gray0 = Color(hex: 0xFFFFFF)
    static let gray1 = Color(hex: 0xF9FAFB)
    static let gray2 = Color(hex: 0xF3F4F6)
    static let gray3 = Color(hex: 0xE5E7EB)
    static let gray4 = Color(hex: 0x9CA3AF)
    static let gray5 = Color(hex: 0x6B7280)
    static let gray6 = Color(hex: 0x4B5563)
    static let gray7 = Color(hex: 0x374151)
    static let gray8 = Color(hex: 0x1F2937)
    static let gray9 = Color(hex: 0x11181C)
    /// Loss and errors only (red.6 / red.7 of Mantine).
    static let red6 = Color(hex: 0xFA5252)
    static let red7 = Color(hex: 0xF03E3E)
    static let red2 = Color(hex: 0xFFC9C9)

    enum Weight { case regular, medium, bold, extraBold, black
        var postScript: String {
            switch self {
            case .regular: return "Montserrat-Regular"
            case .medium: return "Montserrat-Medium"
            case .bold: return "Montserrat-Bold"
            case .extraBold: return "Montserrat-ExtraBold"
            case .black: return "Montserrat-Black"
            }
        }
    }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font { .custom(weight.postScript, fixedSize: size) }

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static let rule: CGFloat = 1
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - The four text roles (02-tipografia.md)

extension View {
    /// Label: the announcement. 10–13px, 800, uppercase, tracking 1.5, gray.4/5.
    func zenLabel(_ size: CGFloat = 10, color: Color = Zen.gray4) -> some View {
        font(Zen.font(size, .extraBold)).tracking(1.5).textCase(.uppercase).foregroundStyle(color)
    }
    /// Data: what is compared in a column. 13px, 500, gray.7.
    func zenData(_ size: CGFloat = 13, color: Color = Zen.gray7) -> some View {
        font(Zen.font(size, .medium)).foregroundStyle(color)
    }
    /// Body: what is read in sequence. 15px, 500, gray.6.
    func zenBody(_ size: CGFloat = 15, color: Color = Zen.gray6) -> some View {
        font(Zen.font(size, .medium)).foregroundStyle(color).lineSpacing(size * 0.4)
    }
    /// Note: the verification under a strong number. 13px, gray.6.
    func zenNote() -> some View {
        font(Zen.font(13, .medium)).foregroundStyle(Zen.gray6).lineSpacing(5)
    }
    /// Display: the declaration. 900, tracking -0.04em, gray.9.
    func zenDisplay(_ size: CGFloat) -> some View {
        font(Zen.font(size, .black)).tracking(-0.04 * size).foregroundStyle(Zen.gray9)
    }

    func zenBorder(_ color: Color = Zen.gray2) -> some View {
        overlay(Rectangle().strokeBorder(color, lineWidth: Zen.rule))
    }
}

// MARK: - Icons and illustrations

/// Tabler icon, outline, stroke 1.5, from Resources/Icons (template PDFs).
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = Zen.gray7

    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Icons"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    var body: some View {
        Group {
            if let img = Icon.image(name) {
                Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Color.clear)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }
}

/// An illustration from Resources/Illustrations. The official build adds licensed ones that
/// can't be redistributed; without them, each place draws the Tabler icon of the same idea.
struct Illustration: View {
    let name: String
    var size: CGFloat = 160

    private static let fallback: [String: String] = ["camera": "camera", "access": "lock", "editor": "pencil"]

    /// Decoded once: the scan animation redraws this 60 times a second.
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Illustrations"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    var body: some View {
        if let img = Illustration.image(name) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Icon(name: Illustration.fallback[name] ?? "photo", size: size * 0.4, color: Zen.gray5)
                .frame(width: size * 0.7, height: size * 0.7)
                .background(Zen.gray1)
                .zenBorder(Zen.gray3)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Buttons (05-forma.md: a label in a black rectangle)

struct ZenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, subtle, danger }
    var kind: Kind = .primary
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        // Row buttons (30 pt and less) are compact: letter 10, tighter sides.
        let compact = height <= 30
        return configuration.label
            .font(Zen.font(compact ? 10 : 11, .extraBold))
            .tracking(compact ? 0.8 : 1)
            .textCase(.uppercase)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, kind == .subtle ? 8 : (compact ? 10 : 16))
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(Rectangle().strokeBorder(border, lineWidth: kind == .secondary || kind == .danger ? 1 : 0))
            .opacity(enabled ? 1 : 0.45)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .offset(y: configuration.isPressed ? 0 : 0)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary, .subtle: return Zen.gray9
        case .danger: return Zen.red7
        }
    }
    private var background: Color { kind == .primary ? Zen.gray9 : Zen.gray0.opacity(kind == .subtle ? 0 : 1) }
    private var border: Color {
        switch kind {
        case .secondary: return Zen.gray3
        case .danger: return Zen.red7
        default: return .clear
        }
    }
}

struct ButtonLabel: View {
    let title: String
    var icon: String? = nil
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Icon(name: icon, size: 14, color: color ?? .primary) }
            Text(title)
        }
    }
}

/// A checkbox row: a 16 pt square, filled gray.9 with the Tabler check when on.
struct ZenToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Rectangle().fill(isOn ? Zen.gray9 : Zen.gray0)
                    Rectangle().strokeBorder(isOn ? Zen.gray9 : Zen.gray4, lineWidth: 1)
                    if isOn { Icon(name: "check", size: 12, color: .white) }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).zenData(13, color: Zen.gray9)
                    if let detail { Text(detail).zenData(12, color: Zen.gray5).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Segmented choice: square cells, the chosen one filled gray.9.
struct ZenSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let on = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(Zen.font(11, .bold))
                        .foregroundStyle(on ? Color.white : Zen.gray7)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(on ? Zen.gray9 : Zen.gray0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(Zen.gray3).frame(width: 1, height: 28) }
            }
        }
        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
        .fixedSize()
    }
}

/// Small icon button (toolbars, rows).
struct IconButton: View {
    let icon: String
    let help: String
    var size: CGFloat = 16
    var frame: CGFloat = 28
    var active = false
    var color: Color? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: size, color: active ? .white : (color ?? (hover ? Zen.gray9 : Zen.gray6)))
                .frame(width: frame, height: frame)
                .background(active ? Zen.gray9 : (hover ? Zen.gray2 : Color.clear), ignoresSafeAreaEdges: [])
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Toast: success in gray.9, error in red.6. Distinguishable without reading.
struct ToastView: View {
    let text: String
    var error = false
    var body: some View {
        HStack(spacing: 10) {
            Icon(name: error ? "alert-circle" : "check", size: 16, color: .white)
            Text(text).font(Zen.font(13, .bold)).foregroundStyle(.white).lineLimit(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(error ? Zen.red6 : Zen.gray9)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
/// 09-painel.md, "Ação destrutiva": nothing removes in one click. Hold for 3 s; letting go
/// at any moment cancels.
///
/// The timing is SwiftUI's long-press gesture, and the countdown is drawn per frame by a
/// TimelineView: a Foundation Timer would not fire while the mouse button is down, because
/// AppKit runs the event-tracking run loop mode during the press.
struct HoldButton: View {
    let title: String
    var icon: String? = "trash"
    var kind: ZenButtonStyle.Kind = .primary
    var duration: Double = 3
    var height: CGFloat = 36
    let action: () -> Void

    @State private var pressedAt: Date?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let fg: Color = kind == .primary ? .white : (kind == .danger ? Zen.red7 : Zen.gray9)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: pressedAt == nil)) { context in
            let progress = pressedAt.map { min(1, context.date.timeIntervalSince($0) / duration) } ?? 0
            let left = max(1, Int(ceil(duration * (1 - progress))))
            HStack(spacing: 8) {
                if let icon { Icon(name: icon, size: 14, color: fg) }
                Text(pressedAt == nil ? title : L("Hold… %d", left))
            }
            .font(Zen.font(height <= 30 ? 10 : 11, .extraBold)).tracking(height <= 30 ? 0.8 : 1).textCase(.uppercase).lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height <= 30 ? 10 : 16)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(kind == .primary ? Zen.gray9 : Zen.gray0)
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Rectangle().fill(kind == .primary ? Color.white.opacity(0.85) : fg)
                        .frame(width: geo.size.width * progress, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(kind == .danger ? Zen.red7 : (kind == .secondary ? Zen.gray3 : .clear), lineWidth: 1))
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            pressedAt = nil
            if enabled { action() }
        } onPressingChanged: { pressing in
            pressedAt = pressing && enabled ? Date() : nil
        }
        .help(L("Hold for %d seconds to confirm. Release to cancel.", Int(duration)))
    }
}


/// Every floating part moves when dragged by its background; buttons on top
/// keep their clicks. Put it behind a bar, a toolbar or a card.
struct WindowDragArea: NSViewRepresentable {
    var onMove: (() -> Void)? = nil
    final class DragView: NSView {
        var onMove: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, window?.styleMask.contains(.titled) == true { window?.performZoom(nil); return }
            onMove?()
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> DragView { let v = DragView(); v.onMove = onMove; return v }
    func updateNSView(_ v: DragView, context: Context) { v.onMove = onMove }
}

/// The handle of a floating bar: Tabler grip, gray.4, drags the window.
struct GripHandle: View {
    var vertical = true
    var onMove: (() -> Void)? = nil
    var body: some View {
        Icon(name: vertical ? "grip-vertical" : "grip-horizontal", size: 14, color: Zen.gray4)
            .frame(width: vertical ? 18 : 28, height: vertical ? 28 : 14)
            .background(WindowDragArea(onMove: onMove))
            .help(L("Drag to move"))
    }
}
