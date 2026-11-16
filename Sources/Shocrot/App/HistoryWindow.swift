import AppKit
import SwiftUI

enum HistoryWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: HistoryView()))
            w.title = "历史记录"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.setContentSize(CGSize(width: 820, height: 560))
            w.minSize = CGSize(width: 480, height: 360)
            w.center()
            w.setFrameAutosaveName("ShocrotHistory")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.items }
        return store.items.filter { $0.text?.localizedCaseInsensitiveContains(q) == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("历史记录").font(.system(size: 15, weight: .semibold))
                Text("\(store.items.count) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索识别过的文字", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 220)
                Button { AppController.shared.openFolder() } label: { Image(systemName: "folder") }
                    .help("打开截图保存文件夹")
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .help("清空历史记录")
                    .disabled(store.items.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 80)
            .padding(.trailing, 16)
            .frame(height: 52)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "photo.on.rectangle.angled" : "text.magnifyingglass")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "还没有截图，按 \(Settings.shared.hotKeys[.captureArea]?.displayString ?? "快捷键") 开始" : "没有匹配的记录")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                        ForEach(filtered) { item in
                            HistoryCell(item: item)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .confirmationDialog("清空所有历史记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clear() }
        } message: {
            Text("已保存到文件夹的截图不受影响。")
        }
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    @State private var hovering = false
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.background.secondary)
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if hovering {
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                    HStack(spacing: 6) {
                        action("doc.on.doc", "复制图片") { copy() }
                        action("text.viewfinder", "识别文字") { ocr() }
                        action("pin", "贴图") { pin() }
                        action("square.and.arrow.down", "另存为") { if let img = image { ImageOutput.saveAs(img, scale: item.scale) } }
                        action("trash", "删除") { HistoryStore.shared.delete(item) }
                    }
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { pin() }
            .onDrag {
                NSItemProvider(contentsOf: HistoryStore.shared.url(for: item)) ?? NSItemProvider()
            }

            HStack(spacing: 4) {
                if item.text != nil { Image(systemName: "text.alignleft").foregroundStyle(Color.accentColor) }
                Text(item.text?.replacingOccurrences(of: "\n", with: " ") ?? "\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height))")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .task(id: item.id) { await loadThumbnail() }
        .onReceive(HistoryStore.shared.objectWillChange) { _ in
            if thumb == nil { Task { await loadThumbnail() } }
        }
        .contextMenu {
            Button("复制图片") { copy() }
            if let text = item.text { Button("复制文字") { ImageOutput.copyText(text) } }
            Button("识别文字") { ocr() }
            Button("贴图") { pin() }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.url(for: item)]) }
            Divider()
            Button("删除", role: .destructive) { HistoryStore.shared.delete(item) }
        }
    }

    private var image: CGImage? { HistoryStore.shared.image(for: item) }

    /// Decoding takes ~100 ms for a full-screen capture, far too long for the main thread.
    private func loadThumbnail() async {
        let item = item
        thumb = await Task.detached(priority: .utility) { HistoryStore.shared.thumbnail(for: item) }.value
    }

    private func copy() {
        guard let img = image else { return }
        ImageOutput.copy(img, scale: item.scale)
        Feedback.toast("已复制图片")
    }

    private func ocr() {
        guard let img = image else { return }
        OCRWindow.show(model: OCRModel(image: img, scale: item.scale, historyID: item.id))
    }

    private func pin() {
        guard let img = image else { return }
        PinWindow.pin(img, scale: item.scale)
    }

    private func action(_ symbol: String, _ help: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.2), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
