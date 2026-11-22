import AppKit
import SwiftUI
import Translation

struct TranslateView: View {
    @ObservedObject var model: TranslateModel
    /// Closes the panel itself; `NSApp.keyWindow` may be another window (a pinned image, Settings) or none.
    let onClose: () -> Void
    @ObservedObject private var speaker = Speaker.shared
    @FocusState private var inputFocused: Bool
    @State private var inputSelection: TextSelection?
    @State private var resultsHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0
    @State private var inputTextHeight: CGFloat = 0
    @State private var downloadRequest: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: TranslatePanelLayout.spacing) {
            VStack(spacing: TranslatePanelLayout.spacing) {
                header
                inputCard
                languageBar
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
            if !model.results.isEmpty || model.definition != nil || !model.hasServices {
                ScrollView {
                    VStack(spacing: 8) {
                        if !model.hasServices { noServiceCard }
                        if let definition = model.definition { DefinitionCard(word: model.input, text: definition) }
                        ForEach(model.results) { ResultCard(result: $0, language: model.resolvedTarget, onDownload: requestDownload) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
                }
                .scrollIndicators(TranslatePanelLayout.resultsScrollIndicators)
                // Capped so the whole panel fits its display; the rest scrolls.
                .frame(height: TranslatePanelLayout.resultsHeight(content: resultsHeight, chrome: chromeHeight,
                                                                  maxPanelHeight: model.maxPanelHeight))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, TranslatePanelLayout.bottomPadding)
        .padding(.top, TranslatePanelLayout.topPadding)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        // Lets Apple's own sheet download missing offline languages, then retries.
        .translationTask(downloadRequest) { session in
            try? await session.prepareTranslation()
            model.translate()
        }
        .animation(.easeOut(duration: 0.18), value: model.results.count)
        .background {
            // ⇧⌘C copies the first finished translation, like the OCR window's copy shortcut.
            Button("") { copyFirstResult() }.keyboardShortcut("c", modifiers: [.command, .shift]).hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTranslateInput)) { note in
            // New text: a fresh caret rather than a stale selection from the previous query. At the start for
            // recognized or selected text, so a long text shows its beginning rather than its end.
            let atStart = note.userInfo?[TranslatePanel.caretAtStartKey] as? Bool == true
            inputSelection = TextSelection(insertionPoint: atStart ? model.input.startIndex : model.input.endIndex)
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Image(systemName: "translate").foregroundStyle(.secondary)
            Text(L("common.translate")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? L("translate.unpin") : L("translate.pin"),
                       active: model.pinned) { model.pinned.toggle() }
            IconButton(symbol: "gearshape", help: L("translate.settings")) { SettingsWindow.show(tab: .translate) }
            IconButton(symbol: "xmark", help: L("common.closeEsc"), action: onClose)
        }
        .frame(height: 22)
        // The header is the panel's title bar: drag it to move the borderless panel. The buttons keep their clicks.
        // Not `WindowDragGesture`: dropped in the menu bar, a system drag tiles the panel to the screen centre.
        .background { HeaderDragHandle() }
    }

    private func copyFirstResult() {
        guard let text = model.results.first(where: { $0.error == nil && !$0.isLoading && !$0.text.isEmpty })?.text
        else { return }
        ImageOutput.copyText(text)
        Feedback.toast(L("translate.copiedTranslation"))
    }

    private func requestDownload() {
        guard let source = model.resolvedSource, let target = model.resolvedTarget else { return }
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
                if model.isRecognizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("translate.recognizing"))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                } else if model.input.isEmpty {
                    Text(L("translate.placeholder"))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.input, selection: $inputSelection)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        model.translate()
                        return .handled
                    }
                    .mask {
                        // Capped and scrolling: fade the bottom edge so it is clear there is more below.
                        if TranslatePanelLayout.inputOverflows(natural: inputTextHeight) {
                            VStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: TranslatePanelLayout.inputFadeHeight)
                            }
                        } else {
                            Rectangle()
                        }
                    }
            }
            // The editor's own ideal height is its whole text (a full-screen OCR made the panel 1800 pt tall), so
            // it gets a fixed height instead: a hidden copy of the text measures it, capped; longer text scrolls.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: TranslatePanelLayout.inputHeight(natural: inputTextHeight))
            .background(alignment: .topLeading) {
                Text(model.input + " ")
                    .font(.system(size: 14))
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputTextHeight = $0 }
            }
            HStack(spacing: 2) {
                if let caption = model.sourceCaption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                IconButton(symbol: speaker.speakingID == "input" ? "stop.fill" : "speaker.wave.2", help: L("translate.speak")) {
                    speaker.toggle(model.input, language: model.detected ?? model.resolvedSource, id: "input")
                }
                .disabled(model.input.isEmpty)
                IconButton(symbol: "doc.on.doc", help: L("translate.copySource")) { ImageOutput.copyText(model.input) }
                    .disabled(model.input.isEmpty)
                IconButton(symbol: "xmark.circle.fill", help: L("translate.clear")) { model.clear(); inputFocused = true }
                    .disabled(model.input.isEmpty)
            }
            .padding(.leading, 5)
            .padding(.trailing, 3)
        }
        // The editor insets its text by 5 pt, so this lines the text up with the result cards (10 pt).
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .card()
    }

    // MARK: Languages

    private var languageBar: some View {
        HStack(spacing: 8) {
            LanguageMenu(selection: $model.source, automaticTitle: L("translate.autoDetect"), resolved: model.resolvedSource) { model.translate() }
            Button(action: model.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("translate.swap"))
            .accessibilityLabel(L("translate.swap"))
            .disabled(!model.canSwap)
            .opacity(model.canSwap ? 1 : 0.4)
            LanguageMenu(selection: $model.target, automaticTitle: L("translate.auto"), resolved: model.resolvedTarget) { model.translate() }
        }
    }

    private var noServiceCard: some View {
        HStack {
            Text(L("translate.noServices")).foregroundStyle(.secondary)
            Spacer()
            Button(L("translate.openSettings")) { SettingsWindow.show(tab: .translate) }
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
        let title = LanguageMenuTitle(selection: selection, resolved: resolved, automaticTitle: automaticTitle)
        Menu {
            // Toggles, so the menu ticks the current choice.
            Toggle(automaticTitle, isOn: choosing(nil))
            Divider()
            ForEach(Language.all) { lang in
                Toggle(lang.name, isOn: choosing(lang))
            }
        } label: {
            HStack(spacing: 4) {
                if title.showsAutomaticMark {
                    Image(systemName: LanguageMenuTitle.automaticSymbol)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(title.full)
        // Named after the full title; the icons are hidden (the chevron was read as "Up And Down Chevrons").
        .accessibilityLabel(title.full)
        .card()
    }

    private func choosing(_ language: Language?) -> Binding<Bool> {
        Binding(get: { selection == language }) { isOn in
            guard isOn, selection != language else { return }
            selection = language
            onChange()
        }
    }
}

/// What a language menu's button says. Detect / Automatic show just the language they resolved to, with a
/// small mark, so the title fits the half-width button ("Automatic · Chinese (Simplified)" was cut off); the
/// full wording goes to the tooltip and VoiceOver.
struct LanguageMenuTitle: Equatable {
    static let automaticSymbol = "wand.and.stars"
    let text: String
    let showsAutomaticMark: Bool
    let full: String

    init(selection: Language?, resolved: Language?, automaticTitle: String) {
        if let selection {
            (text, showsAutomaticMark, full) = (selection.name, false, selection.name)
        } else if let resolved {
            (text, showsAutomaticMark, full) = (resolved.name, true, "\(automaticTitle) · \(resolved.name)")
        } else {
            (text, showsAutomaticMark, full) = (automaticTitle, false, automaticTitle)
        }
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
                    IconButton(symbol: speaker.speakingID == "r\(result.id)" ? "stop.fill" : "speaker.wave.2", help: L("translate.speak")) {
                        speaker.toggle(result.text, language: language, id: "r\(result.id)")
                    }
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: L("translate.copyTranslation")) {
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
                Button(L("translate.download"), action: onDownload)
            case .openSettings:
                Button(L("translate.settingsButton")) { SettingsWindow.show(tab: .translate) }
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
                Text(L("translate.dictionary")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: expanded ? "chevron.up" : "chevron.down", help: expanded ? L("translate.collapse") : L("translate.expand")) { expanded.toggle() }
                IconButton(symbol: "arrow.up.right", help: L("translate.openInDictionary")) { SystemDictionary.open(word) }
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
        .accessibilityLabel(help)
    }
}

extension View {
    /// The shared rounded "card" surface used across the translation UI.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
