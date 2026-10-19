import AppKit
import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, background, shortcuts, quickAccess, recording, screenshots, annotate, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Geral"
        case .background: return "Fundo"
        case .shortcuts: return "Atalhos"
        case .quickAccess: return "Acesso rápido"
        case .recording: return "Gravação"
        case .screenshots: return "Capturas"
        case .annotate: return "Anotação"
        case .advanced: return "Avançado"
        }
    }
    var icon: String {
        switch self {
        case .general: return "settings"
        case .background: return "wallpaper"
        case .shortcuts: return "keyboard"
        case .quickAccess: return "layout-dashboard"
        case .recording: return "video"
        case .screenshots: return "camera"
        case .annotate: return "pencil"
        case .advanced: return "adjustments"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "O que acontece ao ligar o Mac e logo depois de cada captura, e a pasta onde os arquivos ficam."
        case .background: return "Um fundo atrás das capturas de janela, para mandar a imagem já pronta."
        case .shortcuts: return "Os atalhos que valem em qualquer app, do jeito que você preferir."
        case .quickAccess: return "A miniatura que aparece no canto depois de capturar."
        case .recording: return "Formato, qualidade e o que entra na gravação da tela."
        case .screenshots: return "O arquivo de cada captura e como a seleção de área se comporta."
        case .annotate: return "Cor e espessura com que o editor abre, e os atalhos dele."
        case .advanced: return "Nome dos arquivos, quanto tempo o histórico guarda e a volta ao padrão."
        }
    }
}

/// The one window of the app (the macOS app frame of the Zen design system, shared with Cleaner): the history and
/// every settings pane in the sidebar. SettingsWindow and HistoryWindow open it on their pane.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static var current: NSWindow? { window }
    static let model = SettingsModel()

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        model.section = .settings
        open()
    }

    static func open() {
        Stage.activate()
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = MacShell.window(title: "Screenshots", size: CGSize(width: 1120, height: 780),
                                minSize: CGSize(width: 980, height: 720), autosave: "ScreenshotsMain",
                                root: SettingsView(model: model, prefs: Prefs.shared, library: Library.shared))
        w.delegate = closer
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// A closed window is gone for good: its views, the history cards and their thumbnails go
    /// with it, and the next open builds a fresh one.
    private static let closer = Closer()
    final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let w = SettingsWindow.window else { return }
                SettingsWindow.window = nil
                DispatchQueue.main.async {
                    w.contentView = nil
                    Memory.trim()
                }
            }
        }
    }
}

@MainActor
@Observable
final class SettingsModel {
    enum Section { case history, settings }
    var section: Section = .settings
    var tab: SettingsTab = .general { didSet { section = .settings } }
    var recording: HotAction?
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var prefs: Prefs
    let library: Library
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        MacShellView {
            MacSidebar(app: "Screenshots") {
                MacSidebarGroup(title: "Capturas") {
                    MacSidebarItem(icon: "history", title: "Histórico",
                                   badge: library.items.isEmpty ? nil : "\(library.items.count)",
                                   active: model.section == .history) { model.section = .history }
                }
                MacSidebarGroup(title: "Ajustes") {
                    ForEach(SettingsTab.allCases) { t in
                        MacSidebarItem(icon: t.icon, title: t.title, active: model.section == .settings && model.tab == t) { model.tab = t }
                    }
                }
            } status: {
                MacStatusLine(on: ScreenGrabber.hasPermission, onText: "Gravação de Tela ligada", offText: "Gravação de Tela desligada") {
                    WelcomeWindow.show()
                }
            }
        } content: {
            switch model.section {
            case .history: HistoryView(library: library)
            case .settings:
                MacPage {
                    MacPageHeader(crumb: "Screenshots", title: model.tab.title, subtitle: model.tab.subtitle)
                    content
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .general: general
        case .background: background
        case .shortcuts: shortcuts
        case .quickAccess: quickAccess
        case .recording: recording
        case .screenshots: screenshots
        case .annotate: annotate
        case .advanced: advanced
        }
    }

    // MARK: tabs

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Ao iniciar") {
                ZenToggle(title: "Abrir o Screenshots ao entrar no Mac", detail: "Fica na barra de menus, pronto para o primeiro atalho.",
                          isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                ZenToggle(title: "Tocar o som de captura", isOn: $prefs.playSound)
            }
            .onAppear { opensAtLogin = SMAppService.mainApp.status == .enabled }
            SettingsSection(title: "Depois de capturar") {
                ZenToggle(title: "Mostrar o acesso rápido", detail: "A miniatura no canto, com copiar, salvar, anotar e fixar.", isOn: $prefs.afterShowQuickAccess)
                ZenToggle(title: "Copiar a imagem", isOn: $prefs.afterCopy)
                ZenToggle(title: "Salvar na pasta", isOn: $prefs.afterSave)
                ZenToggle(title: "Abrir o editor de anotação", isOn: $prefs.afterOpenEditor)
                ZenToggle(title: "Fixar na tela", isOn: $prefs.afterPin)
            }
            SettingsSection(title: "Pasta") {
                HStack(spacing: 12) {
                    Icon(name: "folder", size: 16, color: Zen.gray6)
                    Text(prefs.saveFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .zenData(13, color: Zen.gray9).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { chooseFolder() } label: { Text("Escolher") }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: prefs.saveFolder)) } label: { Text("Abrir") }
                        .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
                }
            }
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Capturas de janela", note: "O fundo entra só nas capturas de janela. No editor, qualquer imagem ganha fundo pelo botão Fundo.") {
                ZenSegmented(options: Backdrop.Fill.allCases.map { ($0, $0.title) }, selection: $prefs.windowBackground)
                HStack(spacing: 12) {
                    Text("Margem").zenData(13, color: Zen.gray6)
                    Slider(value: Binding(get: { Double(prefs.backgroundPadding) }, set: { prefs.backgroundPadding = Int($0.rounded()) }), in: 8...200)
                        .frame(width: 260)
                        .disabled(prefs.windowBackground == .none)
                    Text("\(prefs.backgroundPadding) pt").zenData(13, color: Zen.gray7).monospacedDigit()
                }
            }
            SettingsSection(title: "Prévia") {
                BackdropPreview(fill: prefs.windowBackground, padding: CGFloat(prefs.backgroundPadding))
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Atalhos do teclado", note: "Valem em qualquer app. Clique num atalho e aperte a nova combinação; Esc cancela, ⌫ apaga.") {
                VStack(spacing: 0) {
                    ForEach(HotAction.allCases, id: \.self) { a in
                        HStack(spacing: 12) {
                            Icon(name: a.icon, size: 16, color: Zen.gray6)
                            Text(a.title).zenData(13, color: Zen.gray9)
                            Spacer()
                            if Hotkeys.shared.failed.contains(a) {
                                Text("Em uso por outro app").zenData(11, color: Zen.red7)
                            }
                            ShortcutField(action: a, model: model, prefs: prefs)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Zen.gray2).frame(height: 1) }
                    }
                }
                Button { prefs.shortcuts = Shortcut.defaults } label: { ButtonLabel(title: "Voltar ao padrão", icon: "refresh") }
                    .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
            }
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Posição") {
                ZenSegmented(options: [(false, "Canto esquerdo"), (true, "Canto direito")], selection: $prefs.quickAccessRight)
            }
            SettingsSection(title: "Fechar sozinho", note: "Com o mouse em cima, a miniatura espera.") {
                ZenSegmented(options: [(0, "Nunca"), (5, "5 s"), (10, "10 s"), (30, "30 s"), (60, "1 min")], selection: $prefs.quickAccessAutoClose)
            }
            SettingsSection(title: "Na miniatura") {
                VStack(alignment: .leading, spacing: 8) {
                    help("Clique duplo", "abre o editor")
                    help("Arrastar", "leva o arquivo para outro app (Mail, Slack, Finder)")
                    help("Copiar e Salvar", "no meio, e a miniatura sai do canto; nos cantos, fechar, anotar, fixar e apagar")
                }
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Formato") {
                ZenSegmented(options: [(false, "Vídeo MP4"), (true, "GIF")], selection: $prefs.recordGIF)
                ZenSegmented(options: [(30, "30 quadros/s"), (60, "60 quadros/s")], selection: $prefs.recordFPS)
                ZenToggle(title: "Gravar em Retina", detail: "Dobro de pixels nas telas Retina; desligado, o arquivo fica menor.", isOn: $prefs.recordRetina)
            }
            SettingsSection(title: "Na gravação") {
                ZenToggle(title: "Mostrar o cursor", isOn: $prefs.recordCursor)
                ZenToggle(title: "Mostrar os cliques", detail: "Um anel onde o mouse clica.", isOn: $prefs.recordClicks)
                ZenToggle(title: "Gravar o som do computador", isOn: $prefs.recordSystemAudio)
                if #available(macOS 15.0, *) {
                    ZenToggle(title: "Gravar o microfone", isOn: $prefs.recordMicrophone)
                }
            }
        }
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Arquivo") {
                ZenSegmented(options: [(Prefs.ImageFormat.png, "PNG"), (.jpeg, "JPEG")], selection: $prefs.imageFormat)
                ZenToggle(title: "Salvar em 1× nas telas Retina", detail: "Metade dos pixels: arquivos menores, texto menos nítido.", isOn: $prefs.downscaleRetina)
            }
            SettingsSection(title: "Seleção de área") {
                ZenToggle(title: "Congelar a tela durante a seleção", detail: "O que se mexe (vídeo, menus) fica parado até você escolher.", isOn: $prefs.freezeScreen)
                ZenToggle(title: "Mostrar a lupa", isOn: $prefs.showMagnifier)
                ZenToggle(title: "Mostrar a mira", isOn: $prefs.showCrosshair)
                ZenToggle(title: "Esconder os ícones da mesa durante a captura", isOn: $prefs.hideIconsWhileCapturing)
            }
            SettingsSection(title: "Janela") {
                ZenToggle(title: "Capturar a sombra da janela", isOn: $prefs.windowShadow)
            }
            SettingsSection(title: "Timer") {
                ZenSegmented(options: [(3, "3 s"), (5, "5 s"), (10, "10 s")], selection: $prefs.timerSeconds)
            }
        }
    }

    private var annotate: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Cor inicial") {
                HStack(spacing: 8) {
                    ForEach(Array(Palette.colors.enumerated()), id: \.offset) { i, c in
                        Button { prefs.annotationColor = i } label: {
                            Rectangle().fill(Color(nsColor: c.color)).frame(width: 22, height: 22)
                                .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                                .padding(3)
                                .overlay(Rectangle().strokeBorder(prefs.annotationColor == i ? Zen.gray9 : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                    }
                }
            }
            SettingsSection(title: "Espessura inicial") {
                ZenSegmented(options: [(0, "Fina"), (1, "Média"), (2, "Grossa")], selection: $prefs.annotationWidth)
            }
            SettingsSection(title: "Atalhos no editor") {
                VStack(alignment: .leading, spacing: 8) {
                    help("V C A L R F O T P H N B S", "trocam de ferramenta")
                    help("Shift", "segura retas a 45° e quadrados")
                    help("⌘Z e ⇧⌘Z", "desfazem e refazem; ⌫ apaga o que está selecionado")
                    help("⌘C, ⌘S, ⇧⌘S e ⌘P", "copiam, salvam, salvam como e fixam na tela")
                }
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Nome do arquivo", note: "Exemplo: \(Library.fileName(prefix: prefs.fileNamePrefix, date: Date())).\(prefs.imageFormat.ext)") {
                TextField("Captura", text: $prefs.fileNamePrefix)
                    .textFieldStyle(.plain)
                    .font(Zen.font(14, .medium))
                    .frame(width: 280)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Zen.gray3).frame(height: 1) }
            }
            SettingsSection(title: "Histórico", note: "Uma cópia de cada captura fica no histórico, só neste Mac.") {
                ZenSegmented(options: [(0, "Não guardar"), (1, "1 dia"), (7, "1 semana"), (30, "1 mês"), (-1, "Sempre")], selection: $prefs.historyDays)
                HStack(spacing: 12) {
                    Button { HistoryWindow.show() } label: { ButtonLabel(title: "Abrir o histórico", icon: "history") }
                        .buttonStyle(ZenButtonStyle(kind: .secondary, height: 30))
                    HoldButton(title: "Limpar o histórico", kind: .danger, height: 30) {
                        Library.shared.clear()
                        HUD.shared.toast("Histórico limpo")
                    }
                }
            }
            SettingsSection(title: "Ajustes") {
                HoldButton(title: "Voltar tudo ao padrão", icon: "refresh", kind: .secondary, height: 30) {
                    prefs.reset()
                    HUD.shared.toast("Ajustes de volta ao padrão")
                }
            }
        }
    }

    // MARK: pieces

    private func help(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).font(Zen.font(12, .bold)).foregroundStyle(Zen.gray9)
            Text(text).zenData(12, color: Zen.gray6)
        }
    }

    /// Reads the status back from the system after every change, so the box shows what macOS did, not what was clicked.
    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Screenshots: login item: \(error)")
        }
        let status = SMAppService.mainApp.status
        if on && status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        opensAtLogin = status == .enabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.saveFolder)
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let url = panel.url { prefs.saveFolder = url.path }
    }
}

/// A titled block of settings: label 10/800, rows 13/500, 28 between blocks.
struct SettingsSection<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).zenLabel(10, color: Zen.gray5)
            content
            if let note { Text(note).zenData(12, color: Zen.gray5).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small window drawn over the chosen backdrop.
struct BackdropPreview: View {
    let fill: Backdrop.Fill
    let padding: CGFloat
    var body: some View {
        let pad = fill == .none ? 0 : padding / 4
        ZStack {
            switch fill {
            case .none: Color.clear
            case .white: Color.white
            case .gray: Zen.gray3
            case .black: Zen.gray9
            case .wallpaper:
                if let screen = NSScreen.main, let img = DesktopIcons.wallpaper(for: screen) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { Zen.gray3 }
            }
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Zen.gray3).frame(width: 7, height: 7) }
                    Spacer()
                }
                .padding(.horizontal, 8).frame(height: 18).background(Zen.gray1)
                Rectangle().fill(Zen.gray0)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle().fill(Zen.gray3).frame(width: 120, height: 8)
                            Rectangle().fill(Zen.gray2).frame(width: 180, height: 6)
                            Rectangle().fill(Zen.gray2).frame(width: 150, height: 6)
                        }
                        .padding(12)
                    }
            }
            .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
            .padding(pad)
        }
        .frame(width: 320, height: 200)
        .clipped()
        .overlay(Rectangle().strokeBorder(Zen.gray2, lineWidth: 1))
    }
}

/// Click, then press the new combination.
struct ShortcutField: View {
    let action: HotAction
    let model: SettingsModel
    @Bindable var prefs: Prefs
    @State private var monitor: Any?

    var body: some View {
        let recording = model.recording == action
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Aperte o atalho…" : (prefs.shortcuts[action]?.display ?? "Sem atalho"))
                .font(Zen.font(12, recording ? .bold : .medium))
                .foregroundStyle(recording ? Color.white : (prefs.shortcuts[action] == nil ? Zen.gray4 : Zen.gray9))
                .frame(width: 140, height: 28)
                .background(recording ? Zen.gray9 : Zen.gray1)
                .overlay(Rectangle().strokeBorder(recording ? Zen.gray9 : Zen.gray3, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        if model.recording != nil { return }
        model.recording = action
        Hotkeys.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop()
            case 51, 117:
                prefs.shortcuts[action] = nil
                stop()
            default:
                if let sc = Shortcut(event: event) {
                    // One action per combination: the old owner loses it.
                    for (k, v) in prefs.shortcuts where v == sc && k != action { prefs.shortcuts[k] = nil }
                    prefs.shortcuts[action] = sc
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.recording == action { model.recording = nil }
        Hotkeys.shared.paused = false
    }
}
