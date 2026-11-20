import ScreenCaptureKit
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
        refreshStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.mainMenu = makeMainMenu()
        Keychain.migrateLegacyLLMKey(to: Settings.shared.llm.baseURL)
        registerHotKeys()
        VisionOCREngine.warmUp(languages: Settings.shared.ocrLanguages)
        TranslatePanel.prepare()
        // The first ScreenCaptureKit call of a session is slow; pay for it now rather than on the first hotkey.
        if ScreenCapturer.hasPermission {
            Task { _ = try? await SCScreenshotManager.captureImage(in: CGRect(x: 0, y: 0, width: 2, height: 2)) }
        }
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

    // MARK: - Status icon

    private var statusNeedsAttention: Bool?
    private var permissionTimer: Timer?

    /// Without Screen Recording nearly nothing works, so the menu bar icon carries a small dot until it is
    /// granted (and the app relaunched). Polled only while it is missing; the check is cheap.
    private func refreshStatusIcon() {
        let attention = Permission.screenRecording.status != .granted
        if attention != statusNeedsAttention {
            statusNeedsAttention = attention
            statusItem.button?.image = StatusIcon.image(attention: attention)
            statusItem.button?.toolTip = attention ? L("status.tooltip.attention") : "Shocrot"
        }
        if attention, permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusIcon() }
            }
        } else if !attention {
            permissionTimer?.invalidate()
            permissionTimer = nil
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
        case .needsRelaunch:
            addAttentionItem(to: menu, L("menu.relaunch"), subtitle: L("menu.relaunch.subtitle"),
                             symbol: "arrow.clockwise.circle.fill", color: .controlAccentColor, #selector(relaunch))
        case .missing:
            addAttentionItem(to: menu, L("menu.grantScreenRecording"), subtitle: L("menu.grantScreenRecording.subtitle"),
                             symbol: "exclamationmark.circle.fill", color: .systemOrange, #selector(showOnboarding))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for action in HotKeyAction.allCases {
            if action == .translateSelection {
                addItem(to: menu, L("menu.delayedCapture"), "timer", #selector(delayedCapture))
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
            // Accessibility is optional, so no dot on the icon; the one item that needs it says so.
            if action == .translateSelection, Permission.accessibility.status == .missing {
                item.subtitle = L("menu.needsAccessibility")
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addItem(to: menu, L("menu.recognizeClipboard"), "doc.on.clipboard", #selector(recognizeClipboard))
        addItem(to: menu, L("menu.recognizeFile"), "photo", #selector(recognizeFile))
        menu.addItem(.separator())
        addItem(to: menu, L("menu.history"), "clock.arrow.circlepath", #selector(showHistory))
        addItem(to: menu, L("menu.openFolder"), "folder", #selector(openFolder))
        if PinWindow.hasOpen { addItem(to: menu, L("menu.closeAllPins"), "pin.slash", #selector(closePins)) }
        menu.addItem(.separator())
        addItem(to: menu, L("menu.settings"), "gearshape", #selector(showSettings), key: ",")
        addItem(to: menu, L("menu.quit"), "power", #selector(quit), key: "q")
    }

    private func addItem(to menu: NSMenu, _ title: String, _ symbol: String, _ selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    /// A menu item that stands out a little: colored symbol and a one-line explanation.
    private func addAttentionItem(to menu: NSMenu, _ title: String, subtitle: String, symbol: String,
                                  color: NSColor, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.subtitle = subtitle
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, color]))
        menu.addItem(item)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotKeyAction(rawValue: raw) else { return }
        // Start as soon as the menu has faded out, so it isn't captured but no time is wasted.
        Task { @MainActor in
            for _ in 0..<30 {
                guard Self.menuOnScreen() else { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            perform(action)
        }
    }

    /// Whether one of our menus is still on screen (including its fade-out).
    private static func menuOnScreen() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains {
            $0[kCGWindowOwnerPID as String] as? Int32 == pid
                && $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
    }

    @objc func showHistory() { HistoryWindow.show() }
    @objc func showSettings() { SettingsWindow.show() }
    @objc func showOnboarding() { OnboardingWindow.show() }
    /// Created first: before the first save the folder doesn't exist, and opening it would silently do nothing.
    @objc func openFolder() {
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
        appMenu.addItem(withTitle: L("menu.about"), action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("menu.settings"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("menu.edit"))
        edit.addItem(withTitle: L("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("menu.window"))
        window.addItem(withTitle: L("common.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: L("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Capture

    /// A capture is being taken but its overlay isn't up yet; further requests are dropped.
    private var isPreparingCapture = false

    /// `selectingScreen`: the display under the pointer starts out selected (full-screen capture that is to be annotated).
    func startCapture(_ mode: CaptureMode, selectingScreen: Bool = false) {
        guard !isPreparingCapture, !CaptureSession.isActive, !ScrollCapture.isActive, !ScreenRecording.isActive else { return }
        guard ScreenCapturer.canCapture else { OnboardingWindow.show(); return }
        // Keep our own transient windows out of the frozen screen.
        TranslatePanel.dismissUnpinned()
        CapturePreview.close(animated: false)
        isPreparingCapture = true
        Task { @MainActor [self] in
            defer { isPreparingCapture = false }
            do {
                // The window list for snapping is read off the main thread while the screens are captured.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let screens = NSScreen.screens.map {
                    CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
                }
                let windows = Task.detached(priority: .userInitiated) {
                    ScreenCapturer.visibleWindows(primaryHeight: primaryHeight, screens: screens)
                }
                let snapshots = try await ScreenCapturer.captureAllScreens()
                let session = CaptureSession.start(mode: mode, snapshots: snapshots, windows: await windows.value) {
                    [weak self] outcome, result in self?.handle(outcome, result: result)
                }
                session?.onWindowCapture = { [weak self] id, screen in self?.captureWindow(id, on: screen) }
                if selectingScreen { session?.selectScreen(containing: NSEvent.mouseLocation) }
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
                Feedback.toast(L("toast.countdown", n), symbol: "timer")
                try? await Task.sleep(for: .seconds(1))
            }
            Feedback.hideToast()
            try? await Task.sleep(for: .milliseconds(80)) // let the toast leave the screen
            startCapture(.area)
        }
    }

    /// Follows the same “after selection” setting as an area capture: annotate, copy only, or save only.
    func captureFullScreen() {
        guard !isPreparingCapture, !CaptureSession.isActive, !ScrollCapture.isActive, !ScreenRecording.isActive else { return }
        guard ScreenCapturer.canCapture else { OnboardingWindow.show(); return }
        let after = Settings.shared.afterCapture
        if after == .edit { startCapture(.area, selectingScreen: true); return }
        TranslatePanel.dismissUnpinned()
        CapturePreview.close(animated: false)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else { return }
        isPreparingCapture = true
        Task { @MainActor in
            do {
                let snaps = try await ScreenCapturer.capture([screen])
                isPreparingCapture = false
                guard let snap = snaps.first else { return }
                let scale = CGFloat(snap.image.width) / snap.screen.frame.width
                Feedback.shutter()
                HistoryStore.shared.add(snap.image, scale: scale)
                if after == .save {
                    let url = try await ImageOutput.saveInBackground(snap.image, scale: scale)
                    CapturePreview.show(image: snap.image, scale: scale, status: L("common.saved"), savedURL: url, on: snap.screen)
                } else {
                    ImageOutput.copy(snap.image, scale: scale)
                    CapturePreview.show(image: snap.image, scale: scale, status: L("common.copied"), savedURL: nil, on: snap.screen)
                }
            } catch {
                isPreparingCapture = false
                Feedback.error(error)
            }
        }
    }

    /// ⌥-click in the overlay: the window on its own, transparent background and shadow included.
    private func captureWindow(_ id: CGWindowID, on screen: NSScreen?) {
        Task { @MainActor in
            do {
                let (image, scale) = try await ScreenCapturer.captureWindow(id)
                Feedback.shutter()
                HistoryStore.shared.add(image, scale: scale)
                if Settings.shared.afterCapture == .save {
                    let url = try await ImageOutput.saveInBackground(image, scale: scale)
                    CapturePreview.show(image: image, scale: scale, status: L("preview.windowSaved"), savedURL: url, on: screen)
                } else {
                    ImageOutput.copy(image, scale: scale)
                    CapturePreview.show(image: image, scale: scale, status: L("preview.windowCopied"), savedURL: nil, on: screen)
                }
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
                CapturePreview.show(image: image, scale: scale, status: L("preview.scrollCopied"), savedURL: nil, on: screen)
            }
            return
        }
        if outcome == .record, let screen {
            ScreenRecording.start(rect: result.globalRect, on: screen) { url, duration in
                Task { @MainActor in
                    guard let poster = await GIFExport.poster(of: url) else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        return
                    }
                    CapturePreview.show(image: poster, scale: screen.backingScaleFactor,
                                        status: L("preview.recordingSaved", RecordingModel.format(duration)),
                                        savedURL: url, videoURL: url, on: screen)
                }
            }
            return
        }
        if outcome != .ocr { Feedback.shutter() }
        let historyID = HistoryStore.shared.add(result.image, scale: result.scale)
        switch outcome {
        case .copy:
            ImageOutput.copy(result.image, scale: result.scale)
            CapturePreview.show(image: result.image, textImage: result.ocrImage, scale: result.scale, status: L("common.copied"),
                                savedURL: nil, on: screen)
        case .save:
            Task { @MainActor in
                do {
                    let url = try await ImageOutput.saveInBackground(result.image, scale: result.scale)
                    CapturePreview.show(image: result.image, textImage: result.ocrImage, scale: result.scale,
                                        status: L("common.saved"), savedURL: url, on: screen)
                } catch {
                    Feedback.error(error)
                }
            }
        case .saveAs:
            ImageOutput.saveAs(result.image, scale: result.scale)
        case .pin:
            PinWindow.pin(result.image, textImage: result.ocrImage, scale: result.scale, at: result.globalRect)
        case .translate:
            translate(image: result.ocrImage, historyID: historyID,
                      near: CGPoint(x: result.globalRect.minX + 40, y: result.globalRect.minY))
        case .ocr:
            recognize(image: result.ocrImage, scale: result.scale, historyID: historyID)
        case .scroll, .record:
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
            let codes = model.result?.barcodes ?? []
            if let error = model.error {
                Feedback.toast(error, symbol: "exclamationmark.triangle.fill")
            } else if model.text.isEmpty, !codes.isEmpty {
                // Without the result window the code's content would otherwise be lost.
                ImageOutput.copyText(codes.joined(separator: "\n"))
                Feedback.toast(codes.count == 1 ? L("common.qrCopied") : L("toast.qrCodesCopied", codes.count))
            } else if model.text.isEmpty {
                Feedback.toast(L("common.noTextFound"), symbol: "exclamationmark.triangle.fill")
            } else {
                if !wasAutoCopy { ImageOutput.copyText(model.text) }
                let count = L10n.plural("toast.charsCopied", model.text.filter { !$0.isWhitespace }.count)
                if codes.isEmpty {
                    Feedback.toast(count)
                } else {
                    Feedback.offer(L("toast.alsoQRCode", count), symbol: "qrcode", action: L("toast.copyQRCode")) {
                        ImageOutput.copyText(codes.joined(separator: "\n"))
                    }
                }
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
                    Feedback.toast(L("common.noTextFound"), symbol: "exclamationmark.triangle.fill")
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
            Feedback.toast(L("toast.selectionNeedsAccessibility"), symbol: "exclamationmark.triangle.fill")
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
        ImageFile.load(url)
    }

    @objc func recognizeClipboard() {
        guard let (img, scale) = clipboardImage() else {
            Feedback.toast(L("toast.noImageInClipboard"), symbol: "exclamationmark.triangle.fill")
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
        Feedback.toast(L("toast.noImageOrTextInClipboard"), symbol: "exclamationmark.triangle.fill")
    }
}
