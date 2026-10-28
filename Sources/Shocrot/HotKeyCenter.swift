import AppKit
import Carbon.HIToolbox

/// Registers system-wide shortcuts through Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    /// While recording a new shortcut in Settings we suspend global hotkeys.
    var isSuspended = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    private func fire(_ id: UInt32) {
        guard !isSuspended else { return }
        handlers[id]?()
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    /// Returns false when the shortcut is already taken by another app.
    @discardableResult
    func register(_ hotKey: HotKey, handler: @escaping () -> Void) -> Bool {
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                         EventHotKeyID(signature: OSType(0x5348_4F43), id: id), // 'SHOC'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }
}
