import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    static let defaultSize = CGSize(width: 740, height: 640)
    private static var window: NSWindow?
    private static var keeper: OnScreenKeeper?

    static var isOpen: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    static func show(tab: SettingsTab? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = L("settings.windowTitle")
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.setContentSize(defaultSize)
            keeper = OnScreenKeeper(window: w)
            window = w
        }
        guard let window else { return }
        WindowPresentation.present(window, centerOnMouseScreenWhenHidden: true, preferredSize: window.frame.size)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, shortcuts, ocr, translate, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("settings.tab.general")
        case .shortcuts: L("settings.tab.shortcuts")
        case .ocr: L("settings.tab.ocr")
        case .translate: L("settings.tab.translate")
        case .about: L("settings.tab.about")
        }
    }

    var subtitle: String {
        switch self {
        case .general: L("settings.tab.general.subtitle")
        case .shortcuts: L("settings.tab.shortcuts.subtitle")
        case .ocr: L("settings.tab.ocr.subtitle")
        case .translate: L("settings.tab.translate.subtitle")
        case .about: L("settings.tab.about.subtitle")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "command"
        case .ocr: "text.viewfinder"
        case .translate: "translate"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .shortcuts: .indigo
        case .ocr: .orange
        case .translate: .blue
        case .about: .teal
        }
    }
}

extension Notification.Name {
    static let hotKeyRecorderStarted = Notification.Name("ShocrotHotKeyRecorderStarted")
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
}

/// System Settings–style layout: a sidebar of colored icons, a header and a grouped form per page.
struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared
    private static let sidebarWidth: CGFloat = 212

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: Binding(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) { tab in
                Label {
                    Text(tab.title)
                        .lineLimit(1)
                } icon: {
                    SettingsIcon(tab: tab, size: 22)
                }
                .padding(.vertical, 2)
                .tag(tab)
            }
            .listStyle(.sidebar)
            .safeAreaPadding(.top, 34)
            .frame(width: Self.sidebarWidth)
            .ignoresSafeArea(.container, edges: .top)

            Divider()

            VStack(spacing: 0) {
                if router.tab != .about {
                    HStack(spacing: 12) {
                        SettingsIcon(tab: router.tab, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(router.tab.title).font(.system(size: 17, weight: .semibold))
                            Text(router.tab.subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindow.defaultSize.width, height: SettingsWindow.defaultSize.height)
    }

    @ViewBuilder private var page: some View {
        switch router.tab {
        case .general: GeneralSettings()
        case .shortcuts: ShortcutSettings()
        case .ocr: OCRSettings()
        case .translate: TranslateSettings()
        case .about: AboutView()
        }
    }
}

/// A rounded, tinted square with a white glyph, like the icons in System Settings.
private struct SettingsIcon: View {
    let tab: SettingsTab
    let size: CGFloat

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var s = Settings.shared
    @State private var offerToClearHistory = false

    var body: some View {
        Form {
            Section {
                Toggle(L("settings.general.launchAtLogin"), isOn: $s.launchAtLogin)
                Toggle(L("settings.general.playSound"), isOn: $s.playSound)
                Toggle(L("settings.general.showMagnifier"), isOn: $s.showMagnifier)
                Toggle(L("settings.general.showPreview"), isOn: $s.showPreview)
                Toggle(L("settings.general.keepHistory"), isOn: $s.keepHistory)
            }
            Section {
                Picker(L("settings.language.picker"), selection: $s.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L("settings.language"))
            } footer: {
                HStack {
                    Text(L("settings.language.footer")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // The UI keeps the language it started with, so a different choice needs a restart.
                    if s.appLanguage != L10n.launchChoice {
                        Button(L("settings.language.restartNow"), action: Permission.relaunch).controlSize(.small)
                    }
                }
            }
            Section(L("settings.general.screenshots")) {
                Picker(L("settings.general.afterCapture"), selection: $s.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("settings.general.imageFormat"), selection: $s.imageFormat) {
                    Text(L("settings.general.png")).tag(ImageFormat.png)
                    Text(L("settings.general.jpeg")).tag(ImageFormat.jpeg)
                }
                LabeledContent(L("settings.general.saveLocation")) {
                    HStack {
                        Text(s.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(L("settings.general.change"), action: chooseFolder)
                    }
                }
            }
            Section(L("settings.general.gif")) {
                Picker(L("settings.general.gifFrameRate"), selection: $s.gifFrameRate) {
                    ForEach(GIFOptions.frameRates, id: \.self) { Text(L("gif.fps", $0)).tag($0) }
                }
                Picker(L("settings.general.gifMaxWidth"), selection: $s.gifMaxWidth) {
                    ForEach(GIFOptions.maxWidths, id: \.self) { Text(GIFOptions.widthTitle($0)).tag($0) }
                }
            }
            Section(L("settings.general.permissions")) {
                ForEach(Permission.allCases) { PermissionRow($0) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.keepHistory) { _, keep in
            if !keep, !HistoryStore.shared.items.isEmpty { offerToClearHistory = true }
        }
        .confirmationDialog(L("settings.general.clearHistory.title"), isPresented: $offerToClearHistory) {
            Button(L10n.plural("settings.general.clearHistory.delete", HistoryStore.shared.items.count), role: .destructive) { HistoryStore.shared.clear() }
            Button(L("settings.general.clearHistory.keep"), role: .cancel) {}
        } message: {
            Text(L("settings.general.clearHistory.message"))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = s.saveDirectory
        panel.prompt = L("settings.general.choose")
        if panel.runModal() == .OK, let url = panel.url { s.saveDirectory = url }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var app = AppController.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent {
                        HotKeyRecorder(action: action, hotKey: Binding(get: { s.hotKeys[action] }, set: { s.hotKeys[action] = $0 }))
                    } label: {
                        HStack {
                            Label {
                                Text(action.title)
                            } icon: {
                                Image(systemName: action.symbol).frame(width: 22) // keeps the titles in one column
                            }
                            if app.failedHotKeys.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help(L("settings.shortcuts.taken"))
                            }
                        }
                    }
                }
            } footer: {
                Text(L("settings.shortcuts.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("settings.shortcuts.inCapture")) {
                shortcutRow(L("settings.shortcuts.selectWindow"), L("settings.shortcuts.selectWindow.keys"))
                shortcutRow(L("settings.shortcuts.selectControl"), L("settings.shortcuts.selectControl.keys"))
                shortcutRow(L("settings.shortcuts.copyDone"), L("settings.shortcuts.copyDone.keys"))
                shortcutRow(L("settings.shortcuts.save"), "⌘S  ⇧⌘S")
                shortcutRow(L("settings.shortcuts.ocrTranslatePin"), "⌘T  ⌘D  ⌘P")
                shortcutRow(L("settings.shortcuts.scrollRecord"), "⌘L  ⌘R")
                shortcutRow(L("settings.shortcuts.stopRecording"), "⌃⌘⎋")
                shortcutRow(L("settings.shortcuts.tools"), Tool.allCases.map { String($0.shortcut).uppercased() }.joined(separator: " "))
                shortcutRow(L("settings.shortcuts.undoRedo"), "⌘Z  ⇧⌘Z")
                shortcutRow(L("settings.shortcuts.nudge"), L("settings.shortcuts.nudge.keys"))
                shortcutRow(L("settings.shortcuts.colorFullScreen"), "C  ⌘A")
                shortcutRow(L("settings.shortcuts.cancel"), L("settings.shortcuts.cancel.keys"))
            }
            Section {
                Button(L("settings.shortcuts.restoreDefaults")) {
                    s.hotKeys = Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultHotKey) })
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary) }
    }
}

struct HotKeyRecorder: View {
    let action: HotKeyAction
    @Binding var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? L("settings.shortcuts.recording") : (hotKey?.displayString ?? L("settings.shortcuts.notSet")))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : (hotKey == nil ? .secondary : .primary))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
        // Only one recorder listens at a time; otherwise the first one would swallow the keys meant for this one.
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyRecorderStarted)) { note in
            // The other recorder keeps the global shortcuts unregistered until it is done.
            if note.object as? String != action.rawValue { stop(reregister: false) }
        }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        NotificationCenter.default.post(name: .hotKeyRecorderStarted, object: action.rawValue)
        recording = true
        HotKeyCenter.shared.unregisterAll() // so the current combos reach us
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop() // Esc
            case 51, 117: hotKey = nil; stop() // Delete
            default:
                guard let hk = HotKey(event: event) else { NSSound.beep(); break }
                if let other = HotKeyAction.allCases.first(where: { $0 != action && Settings.shared.hotKeys[$0] == hk }) {
                    NSSound.beep()
                    Feedback.toast(L("toast.shortcutInUse", hk.displayString, other.title), symbol: "exclamationmark.triangle.fill")
                    break
                }
                hotKey = hk
                stop()
            }
            return nil
        }
    }

    private func stop() { stop(reregister: true) }

    private func stop(reregister: Bool) {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if reregister { AppController.shared.registerHotKeys() }
    }
}

private struct OCRSettings: View {
    @ObservedObject private var s = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("settings.ocr.autoCopy"), isOn: $s.ocrAutoCopy)
                Toggle(L("settings.ocr.showWindow"), isOn: $s.ocrShowWindow)
                Toggle(L("settings.ocr.keepLineBreaks"), isOn: $s.ocrKeepLineBreaks)
            }
            Section {
                ForEach(Settings.availableOCRLanguages, id: \.code) { lang in
                    Toggle(lang.name, isOn: Binding(
                        get: { s.ocrLanguages.contains(lang.code) },
                        set: { on in
                            if on { s.ocrLanguages.append(lang.code) } else { s.ocrLanguages.removeAll { $0 == lang.code } }
                            // Keep a stable priority order matching the list above.
                            let order = Settings.availableOCRLanguages.map(\.code)
                            s.ocrLanguages.sort { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
                        }
                    ))
                }
            } header: {
                Text(L("settings.ocr.languages"))
            } footer: {
                Text(L("settings.ocr.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text(verbatim: "Shocrot").font(.system(size: 22, weight: .semibold))
            Text(L("settings.about.tagline"))
                .foregroundStyle(.secondary)
            Text(L("settings.about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranslateSettings: View {
    @ObservedObject private var s = Settings.shared
    @State private var apiKey = Keychain.llmAPIKey(for: Settings.shared.llm.baseURL) ?? ""
    /// Only after choosing a preset or turning this on may a listed model replace the configured one.
    @State private var adoptListedModel = false
    @State private var testStatus: String?
    @State private var models: [String] = []

    var body: some View {
        Form {
            Section {
                Picker(L("settings.translate.primary"), selection: $s.primaryLanguage) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                Picker(L("settings.translate.secondary"), selection: $s.secondaryLanguage) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                Toggle(L("settings.translate.selectionIcon"), isOn: $s.selectionTranslateEnabled)
            } footer: {
                Text(L("settings.translate.languagesFooter")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L("service.apple")) {
                Toggle(L("settings.translate.enableApple"), isOn: $s.appleTranslateEnabled)
                Button(L("settings.translate.manageLanguages")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }

            Section {
                Toggle(L("settings.translate.enableGoogle"), isOn: $s.googleTranslateEnabled)
            } header: {
                Text(L("settings.translate.online"))
            } footer: {
                Text(L("settings.translate.googleFooter")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("settings.translate.enableLLM"), isOn: $s.llm.enabled)
                if s.llm.enabled {
                    Picker(L("settings.translate.preset"), selection: Binding(
                        get: { LLMConfig.presets.first { $0.baseURL == s.llm.baseURL }?.id ?? "" },
                        set: { id in
                            guard let p = LLMConfig.presets.first(where: { $0.id == id }) else { return }
                            s.llm.baseURL = p.baseURL
                            s.llm.model = p.model
                            s.llm.name = p.name
                            s.llm.disableThinking = p.disableThinking
                            adoptListedModel = true
                        })) {
                        ForEach(LLMConfig.presets) { Text($0.name).tag($0.id) }
                        Text(L("settings.translate.custom")).tag("")
                    }
                    TextField(L("settings.translate.endpoint"), text: $s.llm.baseURL, prompt: Text(verbatim: "https://…/v1"))
                    SecureField("API Key", text: $apiKey, prompt: Text(L("settings.translate.apiKeyPrompt")))
                        .onChange(of: apiKey) { _, key in
                            // Editing the address reloads the field with that server's key; nothing to store then,
                            // and a half-typed address (no key, nowhere to put one) is not a failure.
                            guard key != (Keychain.llmAPIKey(for: s.llm.baseURL) ?? "") else { return }
                            if !Keychain.setLLMAPIKey(key, for: s.llm.baseURL) {
                                Feedback.toast(L("settings.translate.apiKeyNotSaved"), symbol: "exclamationmark.triangle.fill")
                            }
                        }
                    LabeledContent(L("settings.translate.model")) {
                        HStack(spacing: 6) {
                            TextField(L("settings.translate.model"), text: $s.llm.model).labelsHidden()
                            if !models.isEmpty {
                                Menu {
                                    ForEach(models, id: \.self) { m in Button(m) { s.llm.model = m } }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                                .help(L("settings.translate.pickModel"))
                            }
                        }
                    }
                    .task(id: s.llm.baseURL + apiKey) { await loadModels() }
                    Toggle(L("settings.translate.disableThinking"), isOn: $s.llm.disableThinking)
                    LabeledContent {
                        Button(L("settings.translate.test"), action: test)
                    } label: {
                        Text(testStatus ?? L("settings.translate.compatible")).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text(L("settings.translate.llm"))
            } footer: {
                if s.llm.enabled {
                    Text(L("settings.translate.llmFooter"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.llm.baseURL) { _, url in apiKey = Keychain.llmAPIKey(for: url) ?? "" }
        .onChange(of: s.llm.enabled) { _, on in if on { adoptListedModel = true } }
        .onChange(of: s.primaryLanguage) { old, new in
            if new == s.secondaryLanguage { s.secondaryLanguage = old }
        }
        .onChange(of: s.secondaryLanguage) { old, new in
            if new == s.primaryLanguage { s.primaryLanguage = old }
        }
    }

    /// Lists the endpoint's models; a just-chosen preset's default model gives way to an installed one.
    private func loadModels() async {
        try? await Task.sleep(for: .milliseconds(400)) // debounce typing in the URL / key fields
        guard !Task.isCancelled else { return }
        let listed = (try? await LLMTranslationService.models(config: s.llm, apiKey: Keychain.llmAPIKey(for: s.llm.baseURL))) ?? []
        guard !Task.isCancelled else { return }
        models = listed
        if adoptListedModel, let first = listed.first, !listed.contains(s.llm.model) { s.llm.model = first }
        adoptListedModel = false
    }

    private func test() {
        testStatus = L("settings.translate.testing")
        let service = LLMTranslationService(config: s.llm, apiKey: Keychain.llmAPIKey(for: s.llm.baseURL))
        Task { @MainActor in
            do {
                var output = ""
                for try await partial in service.translate("Hello, world", from: .named("en"), to: .named("zh-Hans")) {
                    output = partial
                }
                testStatus = L("settings.translate.connected", output)
            } catch {
                testStatus = "✗ \(error.localizedDescription)"
            }
        }
    }
}
