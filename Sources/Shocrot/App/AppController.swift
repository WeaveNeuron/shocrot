import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = AppController()

    @Published private(set) var failedHotKeys: Set<HotKeyAction> = []
    private var statusItem: NSStatusItem!

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Shocrot")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Shocrot"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()
        registerHotKeys()
        VisionOCREngine.warmUp(languages: Settings.shared.ocrLanguages)
        TranslatePanel.prepare()
        NotificationCenter.default.addObserver(forName: .hotKeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "onboarded") || !ScreenCapturer.hasPermission
            || defaults.bool(forKey: Permission.flowPendingKey) {
            defaults.removeObject(forKey: Permission.flowPendingKey)
            OnboardingWindow.show()
        }
    }

    func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        var failed: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let hk = Settings.shared.hotKeys[action] else { continue }
            if !center.register(hk, handler: { [weak self] in self?.perform(action) }) { failed.insert(action) }
        }
        failedHotKeys = failed
    }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .captureArea: startCapture(.area)
        case .captureOCR: startCapture(.ocr)
        case .captureScreen: captureFullScreen()
        case .pinClipboard: pinClipboard()
        case .translateSelection: translateSelection()
        case .translateCapture: startCapture(.translate)
        case .translateInput: TranslatePanel.show()
        }
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Without screen recording nothing but selection translation works, so lead with the fix.
        switch Permission.screenRecording.status {
        case .granted: break
        case .needsRelaunch: addItem(to: menu, "重新启动以启用屏幕录制", "arrow.clockwise", #selector(relaunch))
        case .missing: addItem(to: menu, "开启屏幕录制权限…", "exclamationmark.triangle.fill", #selector(showOnboarding))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for action in HotKeyAction.allCases {
            if action == .translateSelection {
                addItem(to: menu, "3 秒后区域截图", "timer", #selector(delayedCapture))
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let hk = Settings.shared.hotKeys[action], !hk.keyEquivalent.isEmpty {
                item.keyEquivalent = hk.keyEquivalent
                item.keyEquivalentModifierMask = hk.modifierFlags
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem(to: menu, "识别剪贴板图片中的文字", "doc.on.clipboard", #selector(recognizeClipboard))
        addItem(to: menu, "识别图片文件中的文字…", "photo", #selector(recognizeFile))
        menu.addItem(.separator())
        addItem(to: menu, "历史记录…", "clock.arrow.circlepath", #selector(showHistory))
        addItem(to: menu, "打开截图文件夹", "folder", #selector(openFolder))
        if PinWindow.hasOpen { addItem(to: menu, "关闭全部贴图", "pin.slash", #selector(closePins)) }
        menu.addItem(.separator())
        addItem(to: menu, "设置…", "gearshape", #selector(showSettings), key: ",")
        addItem(to: menu, "退出 Shocrot", "power", #selector(quit), key: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ symbol: String, _ selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Give the menu time to close so it isn't captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.perform(action) }
    }

    @objc func showHistory() { HistoryWindow.show() }
    @objc func showSettings() { SettingsWindow.show() }
    @objc func showOnboarding() { OnboardingWindow.show() }
    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: Settings.shared.saveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.shared.saveDirectory)
    }
    @objc private func closePins() { PinWindow.closeAll() }
    @objc private func relaunch() { Permission.relaunch() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Shocrot", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Shocrot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Capture

    func startCapture(_ mode: CaptureMode) {
        guard !CaptureSession.isActive, !ScrollCapture.isActive else { return }
        guard ScreenCapturer.canCapture else { OnboardingWindow.show(); return }
        // Keep our own transient windows out of the frozen screen.
        TranslatePanel.dismissUnpinned()
        CapturePreview.close(animated: false)
        Task { @MainActor in
            do {
                let snapshots = try await ScreenCapturer.captureAllScreens()
                CaptureSession.start(mode: mode, snapshots: snapshots) { [weak self] outcome, result in
                    self?.handle(outcome, result: result)
                }
            } catch {
                Feedback.error(error)
            }
        }
    }

    /// Counts down so menus, hover states and tooltips can be opened before the screen freezes.
    @objc func delayedCapture() {
        guard ScreenCapturer.canCapture else { OnboardingWindow.show(); return }
        Task { @MainActor in
            for n in stride(from: 3, through: 1, by: -1) {
                Feedback.toast("\(n) 秒后截图", symbol: "timer")
                try? await Task.sleep(for: .seconds(1))
            }
            Feedback.hideToast()
            try? await Task.sleep(for: .milliseconds(80)) // let the toast leave the screen
            startCapture(.area)
        }
    }

    func captureFullScreen() {
        guard ScreenCapturer.canCapture else { OnboardingWindow.show(); return }
        Task { @MainActor in
            do {
                let snapshots = try await ScreenCapturer.captureAllScreens()
                let mouse = NSEvent.mouseLocation
                guard let snap = snapshots.first(where: { $0.screen.frame.contains(mouse) }) ?? snapshots.first else { return }
                let scale = CGFloat(snap.image.width) / snap.screen.frame.width
                let result = CaptureResult(image: snap.image, rawImage: snap.image, globalRect: snap.screen.frame, scale: scale)
                Feedback.shutter()
                HistoryStore.shared.add(snap.image, scale: scale)
                ImageOutput.copy(snap.image, scale: scale)
                let url = try ImageOutput.save(result.image)
                CapturePreview.show(image: result.image, scale: scale, status: "已复制并保存", savedURL: url, on: snap.screen)
            } catch {
                Feedback.error(error)
            }
        }
    }

    private func handle(_ outcome: CaptureOutcome, result: CaptureResult) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: result.globalRect.midX, y: result.globalRect.midY)) }
        if outcome == .scroll, let screen {
            ScrollCapture.start(rect: result.globalRect, on: screen) { image, scale in
                Feedback.shutter()
                HistoryStore.shared.add(image, scale: scale)
                ImageOutput.copy(image, scale: scale)
                CapturePreview.show(image: image, scale: scale, status: "已复制长截图", savedURL: nil, on: screen)
            }
            return
        }
        if outcome != .ocr { Feedback.shutter() }
        let historyID = HistoryStore.shared.add(result.image, scale: result.scale)
        switch outcome {
        case .copy:
            ImageOutput.copy(result.image, scale: result.scale)
            CapturePreview.show(image: result.image, scale: result.scale, status: "已复制", savedURL: nil, on: screen)
        case .save:
            do {
                let url = try ImageOutput.save(result.image)
                CapturePreview.show(image: result.image, scale: result.scale, status: "已保存", savedURL: url, on: screen)
            } catch {
                Feedback.error(error)
            }
        case .saveAs:
            ImageOutput.saveAs(result.image)
        case .pin:
            PinWindow.pin(result.image, scale: result.scale, at: result.globalRect)
        case .translate:
            translate(image: result.rawImage, historyID: historyID,
                      near: CGPoint(x: result.globalRect.minX + 40, y: result.globalRect.minY))
        case .ocr:
            recognize(image: result.rawImage, scale: result.scale, historyID: historyID)
        case .scroll:
            break
        }
    }

    // MARK: - OCR

    func recognize(image: CGImage, scale: CGFloat, historyID: UUID? = nil) {
        let model = OCRModel(image: image, scale: scale, historyID: historyID)
        if Settings.shared.ocrShowWindow {
            OCRWindow.show(model: model)
            return
        }
        Task { @MainActor in
            let wasAutoCopy = Settings.shared.ocrAutoCopy
            await model.run()
            if let error = model.error {
                Feedback.toast(error, symbol: "exclamationmark.triangle.fill")
            } else if model.text.isEmpty {
                Feedback.toast("没有识别到文字", symbol: "exclamationmark.triangle.fill")
            } else {
                if !wasAutoCopy { ImageOutput.copyText(model.text) }
                Feedback.toast("已复制 \(model.text.filter { !$0.isWhitespace }.count) 个字")
            }
        }
    }

    // MARK: - Translate

    func translate(image: CGImage, historyID: UUID? = nil, near point: CGPoint? = nil) {
        TranslatePanel.showRecognizing(near: point)
        Task { @MainActor in
            do {
                let result = try await OCRService.recognize(image, languages: Settings.shared.ocrLanguages)
                let text = result.text(keepLineBreaks: false)
                guard !text.isEmpty else {
                    TranslatePanel.cancelRecognizing()
                    Feedback.toast("没有识别到文字", symbol: "exclamationmark.triangle.fill")
                    return
                }
                if let historyID { HistoryStore.shared.setText(text, for: historyID) }
                TranslatePanel.show(text: text, near: point)
            } catch {
                TranslatePanel.cancelRecognizing()
                Feedback.error(error)
            }
        }
    }

    func translateSelection() {
        SelectionReader.log.info("translate selection: trusted=\(SelectionReader.isTrusted, privacy: .public)")
        guard SelectionReader.isTrusted else {
            Permission.accessibility.request()
            Feedback.toast("划词翻译需要“辅助功能”权限", symbol: "exclamationmark.triangle.fill")
            return
        }
        let mouse = NSEvent.mouseLocation
        Task { @MainActor in
            let text = await SelectionReader.selectedText()
            TranslatePanel.show(text: text?.isEmpty == false ? text : nil, near: mouse)
            SelectionReader.log.info("translate panel shown")
        }
    }

    private func clipboardImage() -> (CGImage, CGFloat)? {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let img = loadImage(url) { return img }
        guard let image = NSImage(pasteboard: pb) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cg, max(1, CGFloat(cg.width) / max(image.size.width, 1)))
    }

    private func loadImage(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        return (cg, max(1, round(dpi / 72)))
    }

    @objc func recognizeClipboard() {
        guard let (img, scale) = clipboardImage() else {
            Feedback.toast("剪贴板中没有图片", symbol: "exclamationmark.triangle.fill")
            return
        }
        recognize(image: img, scale: scale)
    }

    @objc func recognizeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let (img, scale) = self.loadImage(url) { self.recognize(image: img, scale: scale) }
            }
        }
    }

    func pinClipboard() {
        if let (img, scale) = clipboardImage() { return PinWindow.pin(img, scale: scale) }
        // Copied text is pinned as a note, so a snippet can stay in view while you type elsewhere.
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, let img = ImageOutput.textImage(text, scale: NSScreen.main?.backingScaleFactor ?? 2) {
            return PinWindow.pin(img, scale: NSScreen.main?.backingScaleFactor ?? 2)
        }
        Feedback.toast("剪贴板中没有图片或文字", symbol: "exclamationmark.triangle.fill")
    }
}
