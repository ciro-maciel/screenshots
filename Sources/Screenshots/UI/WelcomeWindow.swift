import AppKit
import SwiftUI

/// First run, or whenever Screen Recording is off: what to turn on and where.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    static var current: NSWindow? { window }

    static func show() {
        Stage.activate()
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Screenshots"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct WelcomeView: View {
    @State var granted = ScreenGrabber.hasPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); Illustration(name: granted ? "camera" : "access", size: 176); Spacer() }
                .padding(.bottom, 24)
            Text("Screenshots").zenLabel(10)
                .padding(.bottom, 8)
            Text(granted ? "Pronto para capturar" : "Falta uma permissão").zenDisplay(32)
                .padding(.bottom, 10)
            Text(granted
                 ? "O Screenshots mora na barra de menus, no ícone do S. Aperte ⌥⇧⌘4 e arraste uma área; ⌥⇧⌘6 captura com rolagem."
                 : "Para ver a tela, o macOS pede que você ligue o Screenshots em Gravação de Tela. A imagem nunca sai deste Mac.")
                .zenBody(15).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            if granted {
                VStack(alignment: .leading, spacing: 10) {
                    row("⌥⇧⌘4", "Área")
                    row("⌥⇧⌘3", "Tela inteira")
                    row("⌥⇧⌘5", "Janela")
                    row("⌥⇧⌘6", "Com rolagem")
                    row("⌥⇧⌘7", "Texto")
                    row("⌥⇧⌘8", "Gravar a tela")
                }
                .padding(.bottom, 28)
                HStack(spacing: 12) {
                    Button { WelcomeWindow.close(); CaptureController.shared.run(.area) } label: { ButtonLabel(title: "Capturar agora", icon: "crosshair", color: .white) }
                        .buttonStyle(ZenButtonStyle(kind: .primary))
                    Button { SettingsWindow.show(.shortcuts) } label: { ButtonLabel(title: "Atalhos", icon: "keyboard") }
                        .buttonStyle(ZenButtonStyle(kind: .secondary))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Abra os Ajustes do Sistema pelo botão abaixo.")
                    step(2, "Em Gravação de Tela e Áudio do Sistema, ligue o Screenshots.")
                    step(3, "Volte aqui e reabra o app: o macOS só libera depois disso.")
                }
                .padding(.bottom, 28)
                HStack(spacing: 12) {
                    Button {
                        CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    } label: { ButtonLabel(title: "Abrir os Ajustes", icon: "settings", color: .white) }
                        .buttonStyle(ZenButtonStyle(kind: .primary))
                    Button { AppDelegate.relaunch() } label: { ButtonLabel(title: "Reabrir o app", icon: "refresh") }
                        .buttonStyle(ZenButtonStyle(kind: .secondary))
                }
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 48)
        .padding(.bottom, 40)
        .frame(width: 640)
        .background(WindowDragArea())
        .background(Zen.gray0)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(Zen.font(12, .bold)).foregroundStyle(Zen.gray9).frame(width: 64, alignment: .leading)
            Text(text).zenData(13, color: Zen.gray6)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(Zen.font(13, .black)).foregroundStyle(Zen.gray9).frame(width: 16, alignment: .leading)
            Text(text).zenData(13, color: Zen.gray6).fixedSize(horizontal: false, vertical: true)
        }
    }
}
