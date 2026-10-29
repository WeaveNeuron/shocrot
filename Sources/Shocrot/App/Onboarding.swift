import AppKit
import SwiftUI

enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView())
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
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
    @State private var canCapture = ScreenCapturer.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.top, 28)
            Text("欢迎使用 Shocrot").font(.system(size: 22, weight: .semibold)).padding(.top, 8)
            Text("一个按键，截图、标注、贴图、识别与翻译。").foregroundStyle(.secondary).padding(.top, 4)

            card("快捷键") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], spacing: 10) {
                    ForEach(HotKeyAction.allCases) { action in
                        HStack(spacing: 8) {
                            Image(systemName: action.symbol)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                            Text(action.title).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Settings.shared.hotKeys[action]?.displayString ?? "—")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 22)

            card("权限") {
                VStack(spacing: 12) {
                    ForEach(Permission.allCases) { PermissionRow($0) }
                }
            }
            .padding(.top, 14)

            HStack {
                Label("所有内容只在本机处理", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(canCapture ? "开始使用" : "稍后") {
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    PermissionGuide.close()
                    OnboardingWindow.close()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 28)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(timer) { _ in canCapture = ScreenCapturer.hasPermission }
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
