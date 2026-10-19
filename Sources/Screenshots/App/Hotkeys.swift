import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey: no Accessibility permission
/// needed, and the key press never reaches the app in front.
final class Hotkeys {
    static let shared = Hotkeys()
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    /// Off while the Settings window records a new shortcut.
    var paused = false { didSet { registerAll() } }
    /// Which actions failed to register (another app owns the combination).
    private(set) var failed: Set<HotAction> = []
    var onAction: ((HotAction) -> Void)?

    private static let signature: OSType = 0x5343_5348 // "SCSH"

    func registerAll() {
        installHandler()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        failed.removeAll()
        guard !paused else { return }
        for (i, action) in HotAction.allCases.enumerated() {
            guard let sc = Prefs.shared.shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Hotkeys.signature, id: UInt32(i))
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.insert(action) }
        }
    }

    var registeredCount: Int { refs.count }

    /// Same path a real key press takes, for the end-to-end test.
    func fire(index: UInt32) {
        guard Int(index) < HotAction.allCases.count else { return }
        let action = HotAction.allCases[Int(index)]
        DispatchQueue.main.async { self.onAction?(action) }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkeys.shared.fire(index: id.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension Shortcut {
    /// From a key event in the shortcut recorder. Needs at least one of ⌘ ⌥ ⌃.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }
}
