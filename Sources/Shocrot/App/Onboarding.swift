import AppKit
import SwiftUI

enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView())
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.title = L("onboarding.welcome")
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
                .frame(width: 72, height: 72)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 18, y: 6)
                .padding(.top, 30)
            Text(L("onboarding.welcome")).font(.system(size: 22, weight: .semibold)).padding(.top, 8)
            Text(L("onboarding.tagline")).foregroundStyle(.secondary).padding(.top, 4)

            card(L("onboarding.shortcuts")) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], spacing: 10) {
                    ForEach(HotKeyAction.allCases) { action in
                        HStack(spacing: 8) {
                            Image(systemName: action.symbol)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text(action.title).lineLimit(1)
                            Spacer(minLength: 4)
                            KeyCaps(Settings.shared.hotKeys[action]?.displayString ?? "—")
                        }
                    }
                }
            }
            .padding(.top, 22)

            // Only what nothing works without; Accessibility is asked for when a feature first needs it.
            card(L("onboarding.permissions")) {
                PermissionRow(.screenRecording)
            }
            .padding(.top, 14)

            HStack {
                Label(L("onboarding.privacy"), systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(canCapture ? L("onboarding.start") : L("onboarding.later")) {
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    PermissionGuide.close()
                    OnboardingWindow.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 28)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) {
            // A soft glow behind the icon gives the window depth without decoration.
            RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 320)
                .frame(height: 320)
                .ignoresSafeArea()
        }
        .onReceive(timer) { _ in canCapture = ScreenCapturer.hasPermission }
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
        }
    }
}

/// A shortcut such as "⌥⇧A" drawn as individual key caps.
struct KeyCaps: View {
    let keys: [String]
    init(_ shortcut: String) { keys = Self.parts(of: shortcut) }

    /// "⌥⇧F12" → ["⌥", "⇧", "F12"]: one cap per modifier, the key name stays whole.
    static func parts(of shortcut: String) -> [String] {
        let modifiers = shortcut.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = shortcut.dropFirst(modifiers.count)
        return modifiers.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 3 : 0)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.primary.opacity(0.10))
                    }
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            }
        }
    }
}
