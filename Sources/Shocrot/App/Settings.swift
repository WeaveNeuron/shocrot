import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A global keyboard shortcut expressed with Carbon key code + modifiers.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask (cmdKey, optionKey, ...)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let isFunctionKey = HotKey.functionKeyNames[UInt32(event.keyCode)] != nil
        // Function keys work alone; anything else needs more than ⇧, or it would swallow capital letters everywhere.
        guard mods & ~UInt32(shiftKey) != 0 || isFunctionKey else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = mods
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + HotKey.keyName(keyCode)
    }

    var keyEquivalent: String {
        let name = HotKey.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func keyName(_ code: UInt32) -> String {
        if let f = functionKeyNames[code] { return f }
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case captureArea, captureOCR, captureScreen, pinClipboard, translateSelection, translateCapture, translateInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "区域截图"
        case .captureOCR: return "识别文字 (OCR)"
        case .captureScreen: return "全屏截图"
        case .pinClipboard: return "贴图剪贴板"
        case .translateSelection: return "划词翻译"
        case .translateCapture: return "截图翻译"
        case .translateInput: return "输入翻译"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: return "crop"
        case .captureOCR: return "text.viewfinder"
        case .captureScreen: return "macwindow"
        case .pinClipboard: return "pin"
        case .translateSelection: return "character.cursor.ibeam"
        case .translateCapture: return "viewfinder"
        case .translateInput: return "translate"
        }
    }

    var defaultHotKey: HotKey {
        let mods = UInt32(optionKey | shiftKey)
        switch self {
        case .captureArea: return HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: mods)
        case .captureOCR: return HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: mods)
        case .captureScreen: return HotKey(keyCode: UInt32(kVK_ANSI_F), modifiers: mods)
        case .pinClipboard: return HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: mods)
        case .translateSelection: return HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: mods)
        case .translateCapture: return HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: mods)  // ⌥⇧S is taken by Easydict and Bob
        case .translateInput: return HotKey(keyCode: UInt32(kVK_ANSI_I), modifiers: mods)
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var ext: String { self == .png ? "png" : "jpg" }
}

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case edit, copy, save
    var id: String { rawValue }
    var title: String {
        switch self {
        case .edit: return "显示标注工具栏"
        case .copy: return "直接复制到剪贴板"
        case .save: return "直接保存到文件夹"
        }
    }
}

/// GIF export of a recording. Only these values are offered; anything else in the defaults falls back.
enum GIFOptions {
    static let frameRates = [10, 12, 15]
    static let defaultFrameRate = 12
    /// 0 = the recording's own width.
    static let maxWidths = [0, 1280, 800]
    static let defaultMaxWidth = 0

    static func widthTitle(_ w: Int) -> String { w == 0 ? "原尺寸" : "\(w) 像素" }
}

/// App-wide preferences backed by UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var hotKeys: [HotKeyAction: HotKey] {
        didSet {
            // Cleared shortcuts are stored as empty data so they stay cleared after relaunch.
            let raw = HotKeyAction.allCases.reduce(into: [String: Data]()) { dict, action in
                dict[action.rawValue] = hotKeys[action].flatMap { try? JSONEncoder().encode($0) } ?? Data()
            }
            d.set(raw, forKey: "hotKeys")
            NotificationCenter.default.post(name: .hotKeysChanged, object: nil)
        }
    }
    @Published var saveDirectory: URL { didSet { d.set(saveDirectory.path, forKey: "saveDirectory") } }
    @Published var imageFormat: ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") } }
    @Published var afterCapture: AfterCaptureAction { didSet { d.set(afterCapture.rawValue, forKey: "afterCapture") } }
    @Published var gifFrameRate: Int { didSet { d.set(gifFrameRate, forKey: "gifFrameRate") } }
    @Published var gifMaxWidth: Int { didSet { d.set(gifMaxWidth, forKey: "gifMaxWidth") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var showMagnifier: Bool { didSet { d.set(showMagnifier, forKey: "showMagnifier") } }
    @Published var showPreview: Bool { didSet { d.set(showPreview, forKey: "showPreview") } }
    @Published var ocrAutoCopy: Bool { didSet { d.set(ocrAutoCopy, forKey: "ocrAutoCopy") } }
    @Published var ocrShowWindow: Bool { didSet { d.set(ocrShowWindow, forKey: "ocrShowWindow") } }
    @Published var ocrKeepLineBreaks: Bool { didSet { d.set(ocrKeepLineBreaks, forKey: "ocrKeepLineBreaks") } }
    @Published var ocrLanguages: [String] { didSet { d.set(ocrLanguages, forKey: "ocrLanguages") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    @Published var primaryLanguage: String { didSet { d.set(primaryLanguage, forKey: "primaryLanguage") } }
    @Published var secondaryLanguage: String { didSet { d.set(secondaryLanguage, forKey: "secondaryLanguage") } }
    @Published var appleTranslateEnabled: Bool { didSet { d.set(appleTranslateEnabled, forKey: "appleTranslateEnabled") } }
    @Published var googleTranslateEnabled: Bool { didSet { d.set(googleTranslateEnabled, forKey: "googleTranslateEnabled") } }
    @Published var llm: LLMConfig { didSet { d.set(try? JSONEncoder().encode(llm), forKey: "llm") } }
    @Published var launchAtLogin: Bool {
        didSet {
            // Writing the property back below runs this observer again (it is @Published); that pass only
            // reflects the system's state and must not register or unregister anything.
            guard !syncingLaunchAtLogin else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                    Feedback.toast("请在系统设置的“登录项”中允许 Shocrot", symbol: "exclamationmark.triangle.fill")
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                NSLog("Shocrot: launch at login failed: \(error)")
                Feedback.toast("无法更改登录时启动：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
            // Show what the system actually did, not what was asked for.
            let actual = Self.launchesAtLogin(SMAppService.mainApp.status)
            if actual != launchAtLogin {
                syncingLaunchAtLogin = true
                launchAtLogin = actual
                syncingLaunchAtLogin = false
            }
        }
    }
    private var syncingLaunchAtLogin = false

    /// Registered counts as on even while it waits for the user's approval in System Settings.
    static func launchesAtLogin(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    static let availableOCRLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en-US", "English"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("fr-FR", "Français"),
        ("de-DE", "Deutsch"), ("es-ES", "Español"), ("ru-RU", "Русский"),
    ]

    private init() {
        var keys: [HotKeyAction: HotKey] = [:]
        let raw = d.dictionary(forKey: "hotKeys") as? [String: Data] ?? [:]
        for action in HotKeyAction.allCases {
            if let data = raw[action.rawValue], let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
                keys[action] = hk
            } else if raw[action.rawValue] == nil {
                keys[action] = action.defaultHotKey
            }
        }
        hotKeys = keys
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        saveDirectory = d.string(forKey: "saveDirectory").map { URL(fileURLWithPath: $0) }
            ?? pictures.appendingPathComponent("Shocrot", isDirectory: true)
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        afterCapture = AfterCaptureAction(rawValue: d.string(forKey: "afterCapture") ?? "") ?? .edit
        gifFrameRate = (d.object(forKey: "gifFrameRate") as? Int).flatMap { GIFOptions.frameRates.contains($0) ? $0 : nil }
            ?? GIFOptions.defaultFrameRate
        gifMaxWidth = (d.object(forKey: "gifMaxWidth") as? Int).flatMap { GIFOptions.maxWidths.contains($0) ? $0 : nil }
            ?? GIFOptions.defaultMaxWidth
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        showMagnifier = d.object(forKey: "showMagnifier") as? Bool ?? true
        showPreview = d.object(forKey: "showPreview") as? Bool ?? true
        ocrAutoCopy = d.object(forKey: "ocrAutoCopy") as? Bool ?? true
        ocrShowWindow = d.object(forKey: "ocrShowWindow") as? Bool ?? true
        ocrKeepLineBreaks = d.object(forKey: "ocrKeepLineBreaks") as? Bool ?? true
        // Empty = let Vision detect the language, which reads both CJK and Latin text best.
        ocrLanguages = d.stringArray(forKey: "ocrLanguages") ?? []
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        primaryLanguage = d.string(forKey: "primaryLanguage") ?? "zh-Hans"
        secondaryLanguage = d.string(forKey: "secondaryLanguage") ?? "en"
        appleTranslateEnabled = d.object(forKey: "appleTranslateEnabled") as? Bool ?? true
        googleTranslateEnabled = d.bool(forKey: "googleTranslateEnabled")  // off: text would leave the Mac
        llm = d.data(forKey: "llm").flatMap { try? JSONDecoder().decode(LLMConfig.self, from: $0) } ?? LLMConfig()
        launchAtLogin = Self.launchesAtLogin(SMAppService.mainApp.status)
    }
}

extension Notification.Name {
    static let hotKeysChanged = Notification.Name("ShocrotHotKeysChanged")
    static let historyChanged = Notification.Name("ShocrotHistoryChanged")
}
