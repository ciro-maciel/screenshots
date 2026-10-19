// The macOS app frame of the Zen design system, the same file as in Cleaner
// (github.com/ciro-maciel/cleaner). Kept identical across the apps: nothing here is per app.
import SwiftUI
import AppKit

enum MacShell {
    /// The sidebar: white, 300 wide, 1px gray.2 rule on its right.
    static let sidebarWidth: CGFloat = 300

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// The app window: content under a transparent title bar, no title text, the native window
    /// buttons in their default place over the sidebar.
    @MainActor
    static func window<V: View>(title: String, size: CGSize, minSize: CGSize, autosave: String, root: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .white
        w.contentView = NSHostingView(rootView: root.frame(minWidth: minSize.width, minHeight: minSize.height))
        w.contentMinSize = minSize
        if let test = Stage.testScreen {
            // Isolated tests: on the invisible display, and never saved over the real position.
            w.setFrameOrigin(CGPoint(x: test.visibleFrame.minX + 20, y: test.visibleFrame.maxY - size.height - 20))
        } else {
            if !w.setFrameUsingName(autosave) { w.center() }
            w.setFrameAutosaveName(autosave)
        }
        return w
    }
}

/// Sidebar, rule, content. The whole window is white; nothing translucent.
struct MacShellView<Sidebar: View, Content: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: MacShell.sidebarWidth)
            Rectangle().fill(Zen.gray2).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Zen.gray0)
        .ignoresSafeArea()
    }
}

/// The app's name as its wordmark (28/900), the menu in labeled groups, and the footer: one
/// status line about what the app needs to work, then version and author.
struct MacSidebar<Menu: View, Status: View>: View {
    let app: String
    @ViewBuilder var menu: Menu
    @ViewBuilder var status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window buttons, then the wordmark.
            Text(app).zenDisplay(28).lineLimit(1)
                .padding(.top, 52)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 24) { menu }

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 12) {
                status
                Text(L("Version %@ · by Ciro Cesar Maciel", MacShell.version)).zenData(12, color: Zen.gray5)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Zen.gray2).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Zen.gray0)
    }
}

/// A labeled group of menu items: label 10/800 gray.4, items 2 apart.
struct MacSidebarGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).zenLabel(10).padding(.horizontal, 24).padding(.bottom, 8)
            VStack(spacing: 2) { content }.padding(.horizontal, 12)
        }
    }
}

/// Active: gray.9 fill, white, 800. Inactive: transparent, gray.7, 500; hover gray.1. Radius 0.
struct MacSidebarItem: View {
    let icon: String
    let title: String
    var badge: String? = nil
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Icon(name: icon, size: 18, color: active ? .white : Zen.gray7)
                Text(title)
                    .font(Zen.font(13, active ? .extraBold : .medium))
                    .foregroundStyle(active ? .white : Zen.gray7)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge).font(Zen.font(11, .bold)).foregroundStyle(active ? Zen.gray3 : Zen.gray5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(active ? Zen.gray9 : (hover ? Zen.gray1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The footer's status line: check in gray.6 when on, lock in red.7 when something is missing.
/// Clicking it when off runs `fix` (usually opening System Settings).
struct MacStatusLine: View {
    let on: Bool
    let onText: String
    let offText: String
    var fix: (() -> Void)? = nil

    var body: some View {
        Button { if !on { fix?() } } label: {
            HStack(spacing: 8) {
                Icon(name: on ? "check" : "lock", size: 14, color: on ? Zen.gray6 : Zen.red7)
                Text(on ? onText : offText).zenData(12, color: on ? Zen.gray6 : Zen.red7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!on && fix != nil)
    }
}

/// The content column: scrolls, 48 at the sides, 40 on top, at most 1280 wide.
struct MacPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: 1280, alignment: .leading)
                .padding(.horizontal, 48)
                .padding(.top, 40)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Zen.gray0)
    }
}

/// Crumb 10/800 gray.4 (the app's name), title 36/900, subtitle 15/500 gray.6, actions on the
/// right. One primary button per screen.
struct MacPageHeader<Actions: View>: View {
    let crumb: String
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        PageHeaderLayout {
            VStack(alignment: .leading, spacing: 8) {
                Text(crumb).zenLabel(10)
                Text(title).zenDisplay(36).lineLimit(1).fixedSize()
            }
            Text(subtitle).zenBody(15).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) { actions }.fixedSize()
        }
        .padding(.bottom, 32)
    }
}

extension MacPageHeader where Actions == EmptyView {
    init(crumb: String, title: String, subtitle: String) {
        self.init(crumb: crumb, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The header's three parts: crumb with title, subtitle, actions. The actions sit on the right,
/// 18 below the top, while the whole title and at least 360 of text fit beside them; in a
/// narrower window they drop 24 below the subtitle, still on the right. The title is never cut, the subtitle stops at 640.
struct PageHeaderLayout: SwiftUI.Layout {
    private struct Frame { var isSide: Bool; var head: CGSize; var sub: CGSize; var subWidth: CGFloat; var act: CGSize }

    private func frame(_ width: CGFloat, _ views: Subviews) -> Frame {
        let head = views[0].sizeThatFits(.unspecified)
        let act = views[2].sizeThatFits(.unspecified)
        let beside = width - act.width - 24
        let isSide = act.width == 0 || beside >= max(head.width, 360)
        let subWidth = min(isSide && act.width > 0 ? beside : width, 640)
        let sub = views[1].sizeThatFits(ProposedViewSize(width: subWidth, height: nil))
        return Frame(isSide: isSide, head: head, sub: sub, subWidth: subWidth, act: act)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1280
        let f = frame(width, subviews)
        let text = f.head.height + 8 + f.sub.height
        if f.act.width == 0 { return CGSize(width: width, height: text) }
        return CGSize(width: width, height: f.isSide ? max(text, 18 + f.act.height) : text + 24 + f.act.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frame(bounds.width, subviews)
        let x = bounds.minX, y = bounds.minY
        subviews[0].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: x, y: y + f.head.height + 8), proposal: ProposedViewSize(width: f.subWidth, height: nil))
        let at = f.isSide ? CGPoint(x: bounds.maxX - f.act.width, y: y + 18)
                          : CGPoint(x: bounds.maxX - f.act.width, y: y + f.head.height + 8 + f.sub.height + 24)
        subviews[2].place(at: at, proposal: .unspecified)
    }
}
