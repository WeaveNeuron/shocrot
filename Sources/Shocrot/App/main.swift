import AppKit

// Command-line OCR: `Shocrot --ocr <image> [...]` prints recognized text and exits.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--ocr" {
    var status: Int32 = 0
    for path in args.dropFirst(2) {
        guard let (image, _) = ImageFile.load(URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write("Cannot read image: \(path)\n".data(using: .utf8)!)
            status = 1
            continue
        }
        do {
            let result = try VisionOCREngine.recognizeSync(image, languages: Settings.shared.ocrLanguages)
            print(result.text(keepLineBreaks: true))
            result.barcodes.forEach { print("[QR] \($0)") }
        } catch {
            FileHandle.standardError.write("OCR failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            status = 1
        }
    }
    exit(status)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHOCROT_DEMO_IMAGE"] != nil {
            OnboardingWindow.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppController.shared.perform(.captureArea) }
        }
        #endif
    }

    /// shocrot://capture | ocr | fullscreen | pin | ocr-clipboard | translate[?text=] | translate-selection | translate-capture | history | settings
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), let host = url.host else { return }
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
        let app = AppController.shared
        switch host {
        case "capture": app.perform(.captureArea)
        case "ocr": app.perform(.captureOCR)
        case "fullscreen": app.perform(.captureScreen)
        case "pin": app.perform(.pinClipboard)
        case "ocr-clipboard": app.recognizeClipboard()
        case "translate": TranslatePanel.show(text: text)
        case "translate-selection": app.perform(.translateSelection)
        case "translate-capture": app.perform(.translateCapture)
        case "history": app.showHistory()
        case "settings": app.showSettings()
        default: break
        }
    }

    private var quitReplied = false

    /// A running recording is saved first; the cap keeps a stuck stream from blocking the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecording.needsFinishing else { return .terminateNow }
        quitReplied = false
        let reply = { [weak self] in
            guard let self, !self.quitReplied else { return }
            self.quitReplied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await ScreenRecording.finishBeforeQuit()
            reply()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ImageOutput.resolveClipboard()
        ImageOutput.finishPendingSaves()
        HistoryStore.shared.finishPendingWrites()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again from Finder/Spotlight opens Settings.
        if !flag { SettingsWindow.show() }
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
