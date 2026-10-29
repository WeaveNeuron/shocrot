import AppKit
import SwiftUI

enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView()))
            w.title = "欢迎使用 Shocrot"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct OnboardingView: View {
    @State private var hasPermission = ScreenCapturer.hasPermission
    @State private var requested = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 36)
            Text("欢迎使用 Shocrot").font(.system(size: 24, weight: .semibold)).padding(.top, 10)
            Text("一个按键，截图、标注、贴图、识别与翻译。").foregroundStyle(.secondary).padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(HotKeyAction.allCases) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        Text(action.title)
                        Spacer()
                        Text(Settings.shared.hotKeys[action]?.displayString ?? "—")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(minWidth: 44)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(18)
            .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Group {
                if hasPermission {
                    Label("屏幕录制权限已就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(height: 44)
                } else {
                    VStack(spacing: 8) {
                        Text(requested
                             ? "在“系统设置 › 隐私与安全性 › 录屏与系统录音”中打开 Shocrot，然后重新启动应用。"
                             : "Shocrot 需要“屏幕录制”权限来截取屏幕，所有内容都只在本机处理。")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(requested ? "打开系统设置" : "授予权限") {
                                if !requested { ScreenCapturer.requestPermission() }
                                ScreenCapturer.openPermissionSettings()
                                requested = true
                            }
                            .buttonStyle(.borderedProminent)
                            if requested {
                                Button("重新启动 Shocrot", action: relaunch)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)

            Spacer(minLength: 16)
            Button(hasPermission ? "开始使用" : "稍后") {
                UserDefaults.standard.set(true, forKey: "onboarded")
                OnboardingWindow.close()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.bottom, 28)
        }
        .frame(width: 460, height: 560)
        .onReceive(timer) { _ in hasPermission = ScreenCapturer.hasPermission }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
