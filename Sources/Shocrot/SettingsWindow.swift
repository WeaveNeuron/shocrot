import AppKit
import SwiftUI

enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
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

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("快捷键", systemImage: "command") }
            OCRSettings().tabItem { Label("文字识别", systemImage: "text.viewfinder") }
            AboutView().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 500)
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
                Text("使用 macOS 内置的 Vision 引擎，完全离线。全部不选时自动检测语言。")
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
