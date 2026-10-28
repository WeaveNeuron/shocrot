import AppKit
import SwiftUI
import Translation

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
        window.title = "识别文字"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 880, height: 540))
        window.minSize = CGSize(width: 620, height: 380)
        window.center()
        if let last = windows.last { window.setFrameTopLeftPoint(CGPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) }
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            windows.removeAll { $0 === window }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct OCRView: View {
    @ObservedObject var model: OCRModel
    @State private var hoveredLine: UUID?
    @State private var showTranslation = false
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
        .translationPresentation(isPresented: $showTranslation, text: model.text)
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
                                    Feedback.toast("已复制：\(line.text)")
                                }
                                .help("点击复制这一行")
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
                Text("识别结果").font(.system(size: 15, weight: .semibold))
                Text(stats).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.keepLineBreaks) {
                    Text("保留换行").tag(true)
                    Text("合并为段").tag(false)
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
                    placeholder(symbol: "text.magnifyingglass", text: "没有识别到文字")
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
                    Label("二维码 / 条形码", systemImage: "qrcode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(codes, id: \.self) { code in
                        HStack {
                            if let url = URL(string: code), url.scheme?.hasPrefix("http") == true {
                                Link(code, destination: url).lineLimit(1).truncationMode(.middle)
                            } else {
                                Text(code).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button { ImageOutput.copyText(code); Feedback.toast("已复制二维码内容") } label: {
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
                Button { showTranslation = true } label: { Label("翻译", systemImage: "translate") }
                    .disabled(model.text.isEmpty)
                Button(action: search) { Label("搜索", systemImage: "magnifyingglass") }
                    .disabled(model.text.isEmpty)
                Button { PinWindow.pin(model.image, scale: model.scale) } label: { Label("贴图", systemImage: "pin") }
                Spacer()
                Button(action: copy) {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 64)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .disabled(model.text.isEmpty)
            }
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
        guard let r = model.result else { return model.isLoading ? "正在识别…" : "" }
        let chars = model.text.filter { !$0.isWhitespace }.count
        return "\(r.lines.count) 行 · \(chars) 字"
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
