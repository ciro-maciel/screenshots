import AppKit
import SwiftUI

/// An image pinned over every window: move it by dragging, resize from the edges, right click
/// for the rest. Esc or the X closes it.
@MainActor
final class PinWindow: NSPanel {
    static private(set) var open: [PinWindow] = []
    let image: CGImage
    let scale: CGFloat

    @discardableResult
    static func show(image: CGImage, scale: CGFloat) -> PinWindow {
        let w = PinWindow(image: image, scale: scale)
        open.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        return w
    }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(1, scale)
        let screen = (Geometry.mouseScreen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var size = CGSize(width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale)
        let fit = min(1, screen.width * 0.6 / size.width, screen.height * 0.6 / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let offset = CGFloat(PinWindow.open.count % 6) * 24
        super.init(contentRect: CGRect(x: screen.midX - size.width / 2 + offset, y: screen.midY - size.height / 2 - offset,
                                       width: size.width, height: size.height),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size
        minSize = CGSize(width: 60, height: 60 * size.height / max(size.width, 1))
        contentView = NSHostingView(rootView: PinView(window: self))
        setFrame(CGRect(origin: frame.origin, size: size), display: false)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "c" { copyImage(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "w" { closePin(); return true }
        return super.performKeyEquivalent(with: event)
    }

    func closePin() {
        PinWindow.open.removeAll { $0 === self }
        dispose()
    }

    func copyImage() {
        let pb = Stage.board
        pb.clearContents()
        Library.put(image, scale: scale, on: pb)
        HUD.shared.toast(L("Image copied"))
    }

    func annotate() {
        EditorWindow.show(image: image, scale: scale)
        closePin()
    }

    func save() {
        let c = Library.shared.add(image: image, scale: scale, source: "pinned")
        if let url = Library.shared.save(c) { HUD.shared.toast(L("Saved to %@", url.deletingLastPathComponent().lastPathComponent)) }
    }

    func originalSize() {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true, animate: true)
    }

    func setOpacity(_ v: CGFloat) { alphaValue = v }
}

struct PinView: View {
    weak var window: PinWindow?
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let w = window {
                Image(decorative: w.image, scale: w.scale).resizable().interpolation(.high)
                    .allowsHitTesting(false)
            }
            WindowDragArea()
            if hover {
                Button { window?.closePin() } label: {
                    Icon(name: "x", size: 14, color: Zen.gray9)
                        .frame(width: 26, height: 26)
                        .background(Zen.gray0)
                        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(L("Close (Esc)"))
            }
        }
        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Copy")) { window?.copyImage() }
            Button(L("Save")) { window?.save() }
            Button(L("Annotate")) { window?.annotate() }
            Divider()
            Menu(L("Opacity")) {
                ForEach([100, 75, 50, 25], id: \.self) { v in
                    Button("\(v)%") { window?.setOpacity(CGFloat(v) / 100) }
                }
            }
            Button(L("Original Size")) { window?.originalSize() }
            Divider()
            Button(L("Close")) { window?.closePin() }
        }
    }
}
