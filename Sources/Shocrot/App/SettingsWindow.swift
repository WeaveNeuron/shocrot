import AppKit
import SwiftUI

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: SettingsTab? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Shocrot 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: Hashable { case general, shortcuts, ocr, translate, about }

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsTab.general)
            ShortcutSettings().tabItem { Label("快捷键", systemImage: "command") }.tag(SettingsTab.shortcuts)
            OCRSettings().tabItem { Label("文字识别", systemImage: "text.viewfinder") }.tag(SettingsTab.ocr)
            TranslateSettings().tabItem { Label("翻译", systemImage: "translate") }.tag(SettingsTab.translate)
            AboutView().tabItem { Label("关于", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 540, height: 540)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var s = Settings.shared
    @State private var hasPermission = ScreenCapturer.hasPermission

    var body: some View {
        Form {
            Section {
                Toggle("登录时自动启动", isOn: $s.launchAtLogin)
                Toggle("截图时播放快门声", isOn: $s.playSound)
                Toggle("选区时显示放大镜和取色", isOn: $s.showMagnifier)
                Toggle("截图后在角落显示预览", isOn: $s.showPreview)
                Toggle("保留历史记录", isOn: $s.keepHistory)
            }
            Section("截图") {
                Picker("选区完成后", selection: $s.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.title).tag($0) }
                }
                Picker("图片格式", selection: $s.imageFormat) {
                    Text("PNG（无损）").tag(ImageFormat.png)
                    Text("JPEG（体积小）").tag(ImageFormat.jpeg)
                }
                LabeledContent("保存位置") {
                    HStack {
                        Text(s.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("更改…", action: chooseFolder)
                    }
                }
            }
            Section("权限") {
                LabeledContent("屏幕录制") {
                    if hasPermission {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("前往授权") {
                            ScreenCapturer.requestPermission()
                            ScreenCapturer.openPermissionSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = ScreenCapturer.hasPermission
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = s.saveDirectory
        panel.prompt = "选择"
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
                        HotKeyRecorder(hotKey: Binding(get: { s.hotKeys[action] }, set: { s.hotKeys[action] = $0 }))
                    } label: {
                        HStack {
                            Label(action.title, systemImage: action.symbol)
                            if app.failedHotKeys.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("此快捷键已被其他应用占用")
                            }
                        }
                    }
                }
            } footer: {
                Text("点击后按下新的组合键；按 ⌫ 清除，按 Esc 取消。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("截图时的快捷操作") {
                shortcutRow("复制并完成", "↩  ⌘C  双击")
                shortcutRow("保存 / 另存为", "⌘S  ⇧⌘S")
                shortcutRow("识别文字 / 贴图", "⌘T  ⌘P")
                shortcutRow("标注工具", "R O A P H M T N")
                shortcutRow("撤销 / 重做", "⌘Z  ⇧⌘Z")
                shortcutRow("微调选区", "方向键（⇧ 10 倍）")
                shortcutRow("复制取色 / 全屏选区", "C  ⌘A")
                shortcutRow("取消", "Esc  右键")
            }
            Section {
                Button("恢复默认快捷键") {
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
    @Binding var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "请按下快捷键…" : (hotKey?.displayString ?? "未设置"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : (hotKey == nil ? .secondary : .primary))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        HotKeyCenter.shared.unregisterAll() // so the current combos reach us
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop() // Esc
            case 51, 117: hotKey = nil; stop() // Delete
            default:
                if let hk = HotKey(event: event) { hotKey = hk; stop() } else { NSSound.beep() }
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppController.shared.registerHotKeys()
    }
}

private struct OCRSettings: View {
    @ObservedObject private var s = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle("识别后自动复制文字", isOn: $s.ocrAutoCopy)
                Toggle("识别后显示结果窗口", isOn: $s.ocrShowWindow)
                Toggle("默认保留原始换行", isOn: $s.ocrKeepLineBreaks)
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
                Text("识别语言")
            } footer: {
                Text("使用 macOS 内置的 Vision 引擎，完全离线。全部不选时自动检测语言（推荐）；仅在识别不准时手动指定。")
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
            Text("Shocrot").font(.system(size: 22, weight: .semibold))
            Text("截图 · 标注 · 贴图 · 文字识别")
                .foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranslateSettings: View {
    @ObservedObject private var s = Settings.shared
    @State private var apiKey = Keychain.llmAPIKey ?? ""
    @State private var testStatus: String?
    @State private var axTrusted = SelectionReader.isTrusted

    var body: some View {
        Form {
            Section {
                Picker("首选语言", selection: $s.primaryLanguage) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                Picker("第二语言", selection: $s.secondaryLanguage) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
            } footer: {
                Text("首选语言的文字译为第二语言，其他语言一律译为首选语言。").font(.caption).foregroundStyle(.secondary)
            }

            Section("Apple 翻译") {
                Toggle("启用 Apple 翻译（离线，免费）", isOn: $s.appleTranslateEnabled)
                Button("管理离线语言…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                }
            }

            Section {
                Toggle("启用 Google 翻译（免费，无需配置）", isOn: $s.googleTranslateEnabled)
            } header: {
                Text("在线翻译")
            } footer: {
                Text("需要联网，要翻译的文字会发送给 Google。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("启用大模型翻译", isOn: $s.llm.enabled)
                if s.llm.enabled {
                    Picker("预设", selection: Binding(
                        get: { LLMConfig.presets.first { $0.baseURL == s.llm.baseURL }?.id ?? "" },
                        set: { id in
                            guard let p = LLMConfig.presets.first(where: { $0.id == id }) else { return }
                            s.llm.baseURL = p.baseURL
                            s.llm.model = p.model
                            s.llm.name = p.name
                            s.llm.disableThinking = p.disableThinking
                        })) {
                        ForEach(LLMConfig.presets) { Text($0.name).tag($0.id) }
                        Text("自定义").tag("")
                    }
                    TextField("接口地址", text: $s.llm.baseURL, prompt: Text("https://…/v1"))
                    SecureField("API Key", text: $apiKey, prompt: Text("本地模型可留空"))
                        .onChange(of: apiKey) { _, key in Keychain.llmAPIKey = key }
                    TextField("模型", text: $s.llm.model)
                    Toggle("关闭思考（推理模型响应更快）", isOn: $s.llm.disableThinking)
                    LabeledContent {
                        Button("测试连接", action: test)
                    } label: {
                        Text(testStatus ?? "支持所有 OpenAI 兼容接口").foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("大模型")
            } footer: {
                if s.llm.enabled {
                    Text("本地模型（Ollama / LM Studio）不出本机；云端服务会把待翻译文字发送给对应服务商。API Key 保存在钥匙串中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("划词翻译") {
                LabeledContent("辅助功能权限") {
                    if axTrusted {
                        Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("前往授权") { SelectionReader.requestTrust(); SelectionReader.openSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = SelectionReader.isTrusted
        }
    }

    private func test() {
        testStatus = "正在测试…"
        let service = LLMTranslationService(config: s.llm, apiKey: apiKey)
        Task { @MainActor in
            do {
                var output = ""
                for try await partial in service.translate("Hello, world", from: .named("en"), to: .named("zh-Hans")) {
                    output = partial
                }
                testStatus = "✓ 连接成功：\(output)"
            } catch {
                testStatus = "✗ \(error.localizedDescription)"
            }
        }
    }
}
