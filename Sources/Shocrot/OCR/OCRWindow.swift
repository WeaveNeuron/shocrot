import AppKit
import SwiftUI

final class OCRModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    let historyID: UUID?
    @Published var result: OCRResult?
    @Published var text = ""
    @Published var error: String?
    @Published var keepLineBreaks = Settings.shared.ocrKeepLineBreaks {
        didSet {
            Settings.shared.ocrKeepLineBreaks = keepLineBreaks
            if let result { text = result.text(keepLineBreaks: keepLineBreaks) }
        }
    }

    init(image: CGImage, scale: CGFloat, historyID: UUID?) {
        self.image = image
        self.scale = scale
        self.historyID = historyID
    }

    var isLoading: Bool { result == nil && error == nil }

    @MainActor
    func run() async {
        do {
            let r = try await OCRService.recognize(image, languages: Settings.shared.ocrLanguages)
            result = r
            text = r.text(keepLineBreaks: keepLineBreaks)
            if let historyID, !text.isEmpty { HistoryStore.shared.setText(text, for: historyID) }
            if Settings.shared.ocrAutoCopy, !text.isEmpty { ImageOutput.copyText(text) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum OCRWindow {
    private static var windows: [NSWindow] = []

    static func show(model: OCRModel) {
        let host = NSHostingController(rootView: OCRView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = L("common.recognizeText")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 620, height: 380)
        window.setFrame(initialFrame(for: window), display: false)
        windows.append(window)
        // The observer goes with the window: left registered, its block would keep the window, the model
        // and the whole capture alive after closing.
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                          queue: .main) { [weak window] _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            windows.removeAll { $0 === window }
            FocusReturn.windowDidGoAway()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Centred on the display under the pointer (where the capture or the History window is), not wherever
    /// `center()` would put a new window; a further window cascades from the last one on that display.
    /// Always inside the display's visible frame, so the title bar can be reached and dragged.
    private static func initialFrame(for window: NSWindow) -> CGRect {
        let preferred = CGSize(width: 880, height: 540)
        guard let vf = WindowPlacement.mouseScreen?.visibleFrame else {
            return CGRect(origin: window.frame.origin, size: preferred)
        }
        let inset = WindowPlacement.margin
        let size = CGSize(width: min(preferred.width, vf.width - 2 * inset),
                          height: min(preferred.height, vf.height - 2 * inset))
        var frame = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                           width: size.width, height: size.height)
        if let last = windows.last(where: { vf.intersects($0.frame) }) {
            frame.origin = CGPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24 - size.height)
        }
        return WindowPlacement.fit(frame, in: vf)
    }
}

struct OCRView: View {
    @ObservedObject var model: OCRModel
    @State private var hoveredLine: UUID?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            imagePane
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            textPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .task { if model.isLoading { await model.run() } }
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }

    // MARK: Image with recognized line boxes

    private var imagePane: some View {
        ZStack {
            Rectangle().fill(.background.secondary)
            GeometryReader { geo in
                let imgSize = CGSize(width: CGFloat(model.image.width) / model.scale,
                                     height: CGFloat(model.image.height) / model.scale)
                let avail = CGSize(width: geo.size.width - 48, height: geo.size.height - 72)
                let fit = min(1, avail.width / imgSize.width, avail.height / imgSize.height)
                let size = CGSize(width: imgSize.width * fit, height: imgSize.height * fit)
                ZStack(alignment: .topLeading) {
                    Image(decorative: model.image, scale: model.scale)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                    if let lines = model.result?.lines {
                        ForEach(lines) { line in
                            let r = CGRect(x: line.box.minX * size.width, y: (1 - line.box.maxY) * size.height,
                                           width: line.box.width * size.width, height: line.box.height * size.height)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(hoveredLine == line.id ? 0.28 : 0.08))
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.accentColor.opacity(hoveredLine == line.id ? 0.9 : 0.35), lineWidth: 1))
                                .frame(width: r.width + 4, height: r.height + 4)
                                .offset(x: r.minX - 2, y: r.minY - 2)
                                .onHover { hoveredLine = $0 ? line.id : (hoveredLine == line.id ? nil : hoveredLine) }
                                .onTapGesture {
                                    ImageOutput.copyText(line.text)
                                    Feedback.toast(L("ocr.copiedLine", line.text))
                                }
                                .help(L("ocr.clickToCopyLine"))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .position(x: geo.size.width / 2, y: geo.size.height / 2 + 12)
                .onDrag { NSItemProvider(object: ImageOutput.nsImage(model.image, scale: model.scale)) }
            }
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Text

    private var textPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("ocr.result")).font(.system(size: 15, weight: .semibold))
                Text(stats).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.keepLineBreaks) {
                    Text(L("ocr.keepLineBreaks")).tag(true)
                    Text(L("ocr.joinParagraphs")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 10)

            Group {
                if let error = model.error {
                    placeholder(symbol: "exclamationmark.triangle", text: error)
                } else if !model.isLoading && model.text.isEmpty && (model.result?.barcodes.isEmpty ?? true) {
                    placeholder(symbol: "text.magnifyingglass", text: L("common.noTextFound"))
                } else {
                    TextEditor(text: $model.text)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 13)
                }
            }
            .frame(maxHeight: .infinity)

            if let codes = model.result?.barcodes, !codes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("ocr.codes"), systemImage: "qrcode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(codes, id: \.self) { code in
                        HStack {
                            if let url = URL(string: code), url.scheme?.hasPrefix("http") == true {
                                Link(code, destination: url).lineLimit(1).truncationMode(.middle)
                            } else {
                                Text(code).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button { ImageOutput.copyText(code); Feedback.toast(L("common.qrCopied")) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            Divider()
            HStack(spacing: 8) {
                Button { TranslatePanel.show(text: model.text) } label: { Label(L("common.translate"), systemImage: "translate") }
                    .disabled(model.text.isEmpty)
                Button(action: search) { Label(L("ocr.search"), systemImage: "magnifyingglass") }
                    .disabled(model.text.isEmpty)
                Button { PinWindow.pin(model.image, scale: model.scale) } label: { Label(L("common.pin"), systemImage: "pin") }
                Spacer()
                Button(action: copy) {
                    Label(copied ? L("common.copied") : L("common.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 64)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .buttonStyle(.glassProminent)
                .disabled(model.text.isEmpty)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stats: String {
        guard let r = model.result else { return model.isLoading ? L("ocr.recognizing") : "" }
        let chars = model.text.filter { !$0.isWhitespace }.count
        return L10n.plural("ocr.lines", r.lines.count) + " · " + L10n.plural("ocr.characters", chars)
    }

    private func copy() {
        ImageOutput.copyText(model.text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func search() {
        let q = model.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: String(q))]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
