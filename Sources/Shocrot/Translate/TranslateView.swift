import AppKit
import SwiftUI
import Translation

struct TranslateView: View {
    @ObservedObject var model: TranslateModel
    @ObservedObject private var speaker = Speaker.shared
    @FocusState private var inputFocused: Bool
    @State private var resultsHeight: CGFloat = 0
    @State private var downloadRequest: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 10) {
            header
            inputCard
            languageBar
            if !model.results.isEmpty || model.definition != nil || !model.hasServices {
                ScrollView {
                    VStack(spacing: 8) {
                        if !model.hasServices { noServiceCard }
                        if let definition = model.definition { DefinitionCard(word: model.input, text: definition) }
                        ForEach(model.results) { ResultCard(result: $0, language: model.resolvedTarget, onDownload: requestDownload) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(resultsHeight, 460))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        // Lets Apple's own sheet download missing offline languages, then retries.
        .translationTask(downloadRequest) { session in
            try? await session.prepareTranslation()
            model.translate()
        }
        .animation(.easeOut(duration: 0.18), value: model.results.count)
        .onReceive(NotificationCenter.default.publisher(for: .focusTranslateInput)) { _ in inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Image(systemName: "translate").foregroundStyle(.secondary)
            Text("翻译").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消固定" : "固定窗口（失去焦点不关闭）",
                       active: model.pinned) { model.pinned.toggle() }
            IconButton(symbol: "gearshape", help: "翻译设置") { SettingsWindow.show(tab: .translate) }
            IconButton(symbol: "xmark", help: "关闭 (Esc)") { NSApp.keyWindow?.close() }
        }
        .frame(height: 22)
    }

    private func requestDownload() {
        guard let source = model.detected, let target = model.resolvedTarget else { return }
        if downloadRequest?.source == source.locale && downloadRequest?.target == target.locale {
            downloadRequest?.invalidate()
        } else {
            downloadRequest = TranslationSession.Configuration(source: source.locale, target: target.locale)
        }
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if model.input.isEmpty {
                    Text("输入文字，↩ 翻译，⇧↩ 换行")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                // TextEditor has no intrinsic height; a hidden copy of the text sizes it to fit.
                Text(model.input + " ")
                    .font(.system(size: 14))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 140, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                TextEditor(text: $model.input)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        model.translate()
                        return .handled
                    }
            }
            HStack(spacing: 2) {
                if let detected = model.detected {
                    Text(model.source == nil ? "检测到 \(detected.name)" : detected.name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(symbol: speaker.speakingID == "input" ? "stop.fill" : "speaker.wave.2", help: "朗读") {
                    speaker.toggle(model.input, language: model.detected, id: "input")
                }
                .disabled(model.input.isEmpty)
                IconButton(symbol: "doc.on.doc", help: "复制原文") { ImageOutput.copyText(model.input) }
                    .disabled(model.input.isEmpty)
                IconButton(symbol: "xmark.circle.fill", help: "清空") { model.clear(); inputFocused = true }
                    .disabled(model.input.isEmpty)
            }
        }
        .padding(8)
        .card()
    }

    // MARK: Languages

    private var languageBar: some View {
        HStack(spacing: 8) {
            LanguageMenu(selection: $model.source, automaticTitle: "自动检测", resolved: model.detected) { model.translate() }
            Button(action: model.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("互换语言")
            LanguageMenu(selection: $model.target, automaticTitle: "自动", resolved: model.resolvedTarget) { model.translate() }
        }
    }

    private var noServiceCard: some View {
        HStack {
            Text("还没有启用翻译服务").foregroundStyle(.secondary)
            Spacer()
            Button("去设置") { SettingsWindow.show(tab: .translate) }
        }
        .font(.callout)
        .padding(12)
        .card()
    }
}

// MARK: - Pieces

private struct LanguageMenu: View {
    @Binding var selection: Language?
    let automaticTitle: String
    let resolved: Language?
    let onChange: () -> Void

    var body: some View {
        Menu {
            Button(automaticTitle) { selection = nil; onChange() }
            Divider()
            ForEach(Language.all) { lang in
                Button(lang.name) { selection = lang; onChange() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection?.name ?? resolved.map { "\(automaticTitle) · \($0.name)" } ?? automaticTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .card()
    }
}

private struct ResultCard: View {
    let result: TranslateModel.ServiceResult
    let language: Language?
    let onDownload: () -> Void
    @ObservedObject private var speaker = Speaker.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: result.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(result.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if result.isLoading {
                    ProgressView().controlSize(.mini)
                } else if result.error == nil {
                    IconButton(symbol: speaker.speakingID == "r\(result.id)" ? "stop.fill" : "speaker.wave.2", help: "朗读") {
                        speaker.toggle(result.text, language: language, id: "r\(result.id)")
                    }
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "复制译文") {
                        ImageOutput.copyText(result.text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
            }
            .frame(height: 18)

            if let error = result.error {
                ErrorRow(error: error, onDownload: onDownload)
            } else if !result.text.isEmpty {
                Text(result.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06)).frame(height: 12)
                    .frame(maxWidth: 220, alignment: .leading)
            }
        }
        .padding(10)
        .card()
    }
}

private struct ErrorRow: View {
    let error: Error
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.localizedDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch (error as? TranslationFailure)?.recovery {
            case .downloadLanguages:
                Button("下载", action: onDownload)
            case .openSettings:
                Button("设置") { SettingsWindow.show(tab: .translate) }
            case nil:
                EmptyView()
            }
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct DefinitionCard: View {
    let word: String
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "character.book.closed").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("词典").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: expanded ? "chevron.up" : "chevron.down", help: expanded ? "收起" : "展开") { expanded.toggle() }
                IconButton(symbol: "arrow.up.right", help: "在“词典”中打开") { SystemDictionary.open(word) }
            }
            .frame(height: 18)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .card()
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension View {
    /// The shared rounded "card" surface used across the translation UI.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
