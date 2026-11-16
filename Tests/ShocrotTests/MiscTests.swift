import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Testing
@testable import Shocrot

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func displayStringOrdersModifiersLikeMacOS() {
        let hk = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
        #expect(hk.displayString == "⌥⇧A")
        let all = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(all.displayString == "⌃⌥⇧⌘X")
    }

    @Test func keyCapsKeepMultiCharacterKeysWhole() {
        #expect(KeyCaps.parts(of: "⌥⇧A") == ["⌥", "⇧", "A"])
        #expect(KeyCaps.parts(of: "⌥F12") == ["⌥", "F12"])
        #expect(KeyCaps.parts(of: "F5") == ["F5"])
        #expect(KeyCaps.parts(of: "—") == ["—"])
    }
}

@Suite("Language")
struct LanguageTests {
    @Test func detectsCommonLanguages() {
        #expect(Language.detect("Screenshots are the fastest way to share what you see.")?.code == "en")
        #expect(Language.detect("一个按键，截图、标注、贴图、识别与翻译。")?.code == "zh-Hans")
        #expect(Language.detect("スクリーンショットを撮って翻訳します。")?.code == "ja")
    }

    @Test func unknownCodesFallBackToTheCode() {
        #expect(Language.named("xx").name == "xx")
        #expect(Language.named("zh-Hans").name == "简体中文")
    }
}

@Suite("Pinned text")
struct PinnedTextTests {
    @Test func shortTextMakesACompactCard() throws {
        let image = try #require(ImageOutput.textImage("Hello", scale: 2))
        #expect(image.width < 200 && image.height < 120)
    }

    @Test func longTextWrapsAtTheMaximumWidth() throws {
        let text = String(repeating: "Shocrot pins copied text as a note. ", count: 40)
        let image = try #require(ImageOutput.textImage(text, scale: 1, maxWidth: 400))
        #expect(image.width <= 400 + 28)
        #expect(image.height > 100)
    }
}

@Suite("Beautify")
struct BeautifyTests {
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2])
    }

    @Test func padsEvenlyAndKeepsTheCaptureSharp() throws {
        let out = try #require(ImageOutput.beautified(solid(800, 400), scale: 2))
        // 8% of the short side (200 pt) is 16 pt, clamped up to 32 pt = 64 px per edge.
        #expect(out.width == 800 + 128)
        #expect(out.height == 400 + 128)
        let center = pixel(out, out.width / 2, out.height / 2)
        #expect(center.r == 255 && center.g == 0 && center.b == 0)
        let corner = pixel(out, 2, 2) // background gradient, not the capture
        #expect(corner.b > 200 && corner.r < 200)
    }

    @Test func paddingIsCappedForLargeCaptures() throws {
        let out = try #require(ImageOutput.beautified(solid(4000, 3000), scale: 1))
        #expect(out.width == 4000 + 160)
    }
}

@Suite("Pin transforms")
struct TransformTests {
    /// 2×1: red on the left, blue on the right.
    private let source: CGImage = {
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }()

    /// "r" or "b" for each pixel, row by row from the top.
    private func layout(_ image: CGImage) -> [String] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in String((0..<w).map { x in px[(y * w + x) * 4] > 128 ? "r" : "b" }) }
    }

    @Test func rotationsAndFlipsPutPixelsWhereExpected() throws {
        #expect(layout(source) == ["rb"])
        #expect(layout(try #require(ImageOutput.transformed(source, .rotateRight))) == ["r", "b"])
        #expect(layout(try #require(ImageOutput.transformed(source, .rotateLeft))) == ["b", "r"])
        #expect(layout(try #require(ImageOutput.transformed(source, .flipHorizontal))) == ["br"])
        let tall = try #require(ImageOutput.transformed(source, .rotateRight))
        #expect(layout(try #require(ImageOutput.transformed(tall, .flipVertical))) == ["b", "r"])
    }
}

@Suite struct RulerTests {
    @Test func measuresInImagePixels() {
        var a = Annotation(tool: .ruler, points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 50)], color: .red, width: 4)
        #expect(a.measurement == "50 px")
        a.pixelScale = 2
        #expect(a.measurement == "100 px")
        #expect(Tool.allCases.filter { $0.shortcut == "u" } == [.ruler])
    }
}

@Suite struct AnnotationHistoryTests {
    private func arrow(_ x: CGFloat) -> Annotation {
        Annotation(tool: .arrow, points: [CGPoint(x: x, y: 0), CGPoint(x: x + 10, y: 0)], color: .red, width: 2)
    }

    @Test func undoAfterMovingTheSelectionKeepsAnnotationsInPlace() {
        var history = AnnotationHistory()
        let first = [arrow(0)]
        history.record(first)
        history.shift(by: CGPoint(x: 100, y: 50))
        let restored = history.undo(from: [arrow(100), arrow(200)])
        #expect(restored?.first?.points.first == CGPoint(x: 100, y: 50))
        #expect(history.canRedo)
    }

    @Test func recordingClearsRedo() {
        var history = AnnotationHistory()
        history.record([])
        _ = history.undo(from: [arrow(0)])
        #expect(history.canRedo)
        history.record([])
        #expect(!history.canRedo)
    }
}

@Suite struct SelectionGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func clampingKeepsTheSize() {
        let r = SelectionGeometry.clamped(CGRect(x: 90, y: -5, width: 20, height: 20), in: bounds)
        #expect(r == CGRect(x: 80, y: 0, width: 20, height: 20))
    }

    @Test func resizingPastTheOppositeEdgeFlips() {
        let o = CGRect(x: 20, y: 20, width: 20, height: 20)
        #expect(SelectionGeometry.resized(o, handle: .left, to: CGPoint(x: 50, y: 30), in: bounds)
            == CGRect(x: 40, y: 20, width: 10, height: 20))
    }

    @Test func tooSmallAResizeIsRefused() {
        let o = CGRect(x: 20, y: 20, width: 20, height: 20)
        #expect(SelectionGeometry.resized(o, handle: .right, to: CGPoint(x: 20.5, y: 30), in: bounds) == nil)
    }
}

@Suite struct OutputTests {
    private func image(_ w: Int = 40, _ h: Int = 20) -> CGImage {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()!
    }

    private func dpi(_ data: Data?) -> CGFloat? {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyDPIWidth] as? CGFloat
    }

    @Test func retinaFilesCarryTheirDPI() {
        #expect(dpi(ImageOutput.data(image(), format: .png, scale: 2)) == 144)
        #expect(dpi(ImageOutput.data(image(), format: .jpeg, scale: 2)) == 144)
    }

    @Test func clipboardEncodesOnDemand() {
        let pb = NSPasteboard(name: NSPasteboard.Name("shocrot-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        var encoded: [NSPasteboard.PasteboardType] = []
        ImageOutput.onClipboardEncode = { encoded.append($0) }
        defer { ImageOutput.onClipboardEncode = { _ in } }
        ImageOutput.copy(image(), scale: 2, to: pb)
        #expect(pb.availableType(from: [.png]) == .png)
        #expect(encoded.isEmpty)
        #expect(dpi(pb.data(forType: .png)) == 144)
        #expect(encoded == [.png])
        #expect(pb.data(forType: .tiff) != nil)
        #expect(encoded == [.png, .tiff])
    }

    @Test func concurrentSavesNeverShareAFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shocrot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let picture = image()
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 { group.addTask { try await ImageOutput.save(picture, scale: 2, format: .png, in: dir) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(urls).count == 8)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 8)
    }

    @Test func mosaicHidesTheAreaEvenWithoutAPixelatedImage() {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let mosaic = Annotation(tool: .mosaic, points: [.zero, CGPoint(x: 20, y: 20)], color: .red, width: 2)
        AnnotationRenderer(mosaicImage: { nil }, backdropRect: CGRect(x: 0, y: 0, width: 20, height: 20)).draw(mosaic, in: ctx)
        let color = NSBitmapImageRep(cgImage: ctx.makeImage()!).colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)
        #expect(color?.redComponent == 0)
    }

    @Test func detachedCopyKeepsThePixels() {
        let copy = image().cropping(to: CGRect(x: 0, y: 0, width: 10, height: 10))!.detachedCopy()
        #expect(copy.width == 10 && copy.height == 10)
        let color = NSBitmapImageRep(cgImage: copy).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB)
        #expect(color?.redComponent == 1 && color?.blueComponent == 0)
    }
}

@Suite struct KeychainMigrationTests {
    private func run(_ legacy: Keychain.Lookup, storeSucceeds: Bool = true) -> (finished: Bool, stored: Bool, removed: Bool) {
        var stored = false, removed = false
        let finished = Keychain.migrateLegacyKey(legacy,
                                                 store: { _ in stored = true; return storeSucceeds },
                                                 remove: { removed = true; return true })
        return (finished, stored, removed)
    }

    @Test func deniedAccessIsRetriedAndTouchesNothing() {
        let r = run(.unavailable)
        #expect(!r.finished && !r.stored && !r.removed)
    }

    @Test func failedStoreKeepsTheOldKey() {
        let r = run(.found("k"), storeSucceeds: false)
        #expect(!r.finished && r.stored && !r.removed)
    }

    @Test func successMovesTheKey() {
        let r = run(.found("k"))
        #expect(r.finished && r.stored && r.removed)
    }

    @Test func nothingToMigrateFinishes() {
        #expect(run(.missing).finished)
    }
}

@Suite struct HistoryWriteFailureTests {
    @MainActor @Test func failedWriteDropsOnlyTheNewItem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shocrot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        let picture = ctx.makeImage()!
        let kept = try #require(store.add(picture, scale: 1))
        store.finishPendingWrites()
        // Writes to a directory that no longer exists fail.
        try FileManager.default.removeItem(at: dir)
        let failed = try #require(store.add(picture, scale: 1))
        store.finishPendingWrites()
        for _ in 0..<100 {
            guard store.items.contains(where: { $0.id == failed }) else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.items.map(\.id) == [kept])
    }
}

@Suite struct KeychainOriginTests {
    @Test func sameServerSharesAnOrigin() {
        #expect(Keychain.origin(of: "https://API.openai.com/v1/") == "https://api.openai.com")
        #expect(Keychain.origin(of: "http://localhost:11434/v1") == "http://localhost:11434")
    }

    @Test func differentServersDoNot() {
        #expect(Keychain.origin(of: "https://api.openai.com/v1") != Keychain.origin(of: "https://api.deepseek.com/v1"))
        #expect(Keychain.origin(of: "not a url") == nil)
    }
}

@Suite struct HistoryRebuildTests {
    @Test func recoversImagesAndIgnoresOtherFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let id = UUID()
        try ImageOutput.data(c.makeImage()!, format: .png, scale: 2)!
            .write(to: dir.appendingPathComponent("\(id.uuidString).png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("index.corrupt.json"))
        let items = HistoryStore.rebuildItems(in: dir)
        #expect(items.map(\.id) == [id])
        #expect(items.first?.scale == 2)
        #expect(items.first?.pixelSize == CGSize(width: 40, height: 20))
    }
}

@Suite struct HotKeyRuleTests {
    private func event(_ flags: NSEvent.ModifierFlags, _ code: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
    }

    @Test func shiftAloneIsNotEnough() {
        #expect(HotKey(event: event(.shift, kVK_ANSI_A)) == nil)
        #expect(HotKey(event: event([.shift, .option], kVK_ANSI_A)) != nil)
        #expect(HotKey(event: event([], kVK_F5)) != nil)
    }
}

@Suite struct WindowListTests {
    private func info(pid: Int32, layer: Int = 0, owner: String = "App", x: CGFloat = 10, y: CGFloat = 20,
                      w: CGFloat = 300, h: CGFloat = 200) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowOwnerName as String: owner,
         kCGWindowNumber as String: Int(pid) * 100,
         kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation]
    }

    @Test func flipsToAppKitAndDropsOwnTinyAndSystemWindows() {
        let list = [info(pid: 1), info(pid: 99), info(pid: 2, w: 30), info(pid: 3, owner: "Window Server"),
                    info(pid: 4, layer: 2000)]
        let windows = ScreenCapturer.windows(from: list, primaryHeight: 1000, ownPID: 99)
        #expect(windows.map(\.frame) == [CGRect(x: 10, y: 780, width: 300, height: 200)])
        #expect(windows.first?.title == "App")
        #expect(windows.first?.id == 100 && windows.first?.pid == 1) // for ⌥-click window capture
    }
}

@Suite struct CaptureFocusTests {
    @Test func onlyWindowOpeningOutcomesKeepFocus() {
        #expect(CaptureOutcome.saveAs.opensFocusedWindow(ocrShowsWindow: false))
        #expect(CaptureOutcome.ocr.opensFocusedWindow(ocrShowsWindow: true))
        #expect(!CaptureOutcome.ocr.opensFocusedWindow(ocrShowsWindow: false))
        for outcome in [CaptureOutcome.copy, .save, .pin, .translate, .scroll, .record] {
            #expect(!outcome.opensFocusedWindow(ocrShowsWindow: true))
        }
    }
}

@Suite struct MosaicSourceTests {
    private func image() -> CGImage {
        let c = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 20, height: 32))
        return c.makeImage()!
    }

    @Test func preparedImageIsReusedAndMatchesTheSource() throws {
        let source = MosaicSource(source: image(), blockSize: 8)
        source.prepare()
        let first = try #require(source.get())
        #expect(first.width == 64 && first.height == 32)
        #expect(source.get() === first)
    }

    @Test func worksWithoutPreparing() {
        #expect(MosaicSource(source: image(), blockSize: 8).get() != nil)
    }
}

@Suite struct FocusReturnTests {
    @Test func returnsOnlyWhenShocrotIsLeftWithNothingToTypeInto() {
        #expect(FocusReturn.shouldReturn(appIsActive: true, hasTitledWindow: false, targetTerminated: false))
        #expect(!FocusReturn.shouldReturn(appIsActive: false, hasTitledWindow: false, targetTerminated: false))
        #expect(!FocusReturn.shouldReturn(appIsActive: true, hasTitledWindow: true, targetTerminated: false))
        #expect(!FocusReturn.shouldReturn(appIsActive: true, hasTitledWindow: false, targetTerminated: true))
    }
}

@Suite struct SettingsGeometryTests {
    private let main = CGRect(x: 796, y: 30, width: 740, height: 960)

    private func window(_ owner: String, pid: pid_t, layer: Int = 0, _ rect: CGRect) -> [CFString: Any] {
        [kCGWindowOwnerName: owner, kCGWindowOwnerPID: pid, kCGWindowLayer: layer,
         kCGWindowBounds: rect.dictionaryRepresentation]
    }

    private func geometry(_ list: [[CFString: Any]]) -> (window: CGRect, dialog: CGRect?)? {
        PermissionGuide.settingsGeometry(in: list, settingsPID: 10, ownPID: 1, isRegularApp: { $0 != 20 })
    }

    @Test func theDialogIsSettingsOwnSmallWindowInFrontOfItsMainWindow() {
        // As logged on macOS 26: the Touch ID prompt is a 260 × 204 System Settings window.
        let dialog = CGRect(x: 1036, y: 408, width: 260, height: 204)
        let g = geometry([window("Shocrot", pid: 1, layer: 3, CGRect(x: 1036, y: 841, width: 492, height: 141)),
                          window("System Settings", pid: 10, dialog), window("System Settings", pid: 10, main)])
        #expect(g?.window == main)
        #expect(g?.dialog == dialog)
    }

    @Test func noDialogWhenOnlyTheMainWindowIsUp() {
        let g = geometry([window("Dock", pid: 20, layer: 20, CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                          window("System Settings", pid: 10, main)])
        #expect(g?.window == main)
        #expect(g?.dialog == nil)
    }

    @Test func stepsAsideWhenAnotherAppIsInFront() {
        #expect(geometry([window("Notes", pid: 30, CGRect(x: 0, y: 0, width: 800, height: 600)),
                          window("System Settings", pid: 10, main)]) == nil)
    }

    @Test func picksUpASecurityAgentDialogToo() {
        let dialog = CGRect(x: 1000, y: 400, width: 260, height: 240)
        let g = geometry([window("SecurityAgent", pid: 20, layer: 1000, dialog), window("System Settings", pid: 10, main)])
        #expect(g?.dialog == dialog)
    }
}

@Suite struct StatusIconTests {
    @Test func plainIconIsATemplateAndTheAttentionIconIsNot() throws {
        let plain = try #require(StatusIcon.image(attention: false))
        let flagged = try #require(StatusIcon.image(attention: true))
        #expect(plain.isTemplate)
        #expect(!flagged.isTemplate)
        #expect(flagged.size == plain.size)
        #expect(flagged.accessibilityDescription?.contains("屏幕录制") == true)
    }
}

@Suite struct ElementSnappingTests {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func levelsGoOutwardAndEndWithTheWindow() {
        let button = CGRect(x: 120, y: 120, width: 60, height: 24)
        let toolbar = CGRect(x: 100, y: 110, width: 800, height: 44)
        let levels = ElementProbe.levels([button, toolbar, window], window: window)
        #expect(levels == [button, toolbar, window])
    }

    @Test func dropsTinyDuplicateAndNonEnclosingFrames() {
        let label = CGRect(x: 130, y: 130, width: 40, height: 16)
        let sameAsLabel = CGRect(x: 129, y: 129, width: 42, height: 18) // its wrapper, 1 px larger
        let elsewhere = CGRect(x: 600, y: 600, width: 100, height: 100) // a parent that doesn't contain it
        let dot = CGRect(x: 131, y: 131, width: 4, height: 4)
        let levels = ElementProbe.levels([dot, label, sameAsLabel, elsewhere], window: window)
        #expect(levels == [label, window])
    }

    @Test func clipsToTheWindowAndWorksWithNothingFound() {
        let overhanging = CGRect(x: 50, y: 150, width: 200, height: 100)
        #expect(ElementProbe.levels([overhanging], window: window) == [CGRect(x: 100, y: 150, width: 150, height: 100), window])
        #expect(ElementProbe.levels([], window: window) == [window])
    }
}

@Suite struct WindowCaptureTests {
    @Test func shadowKeepsTheWindowAtFullSizeOnATransparentCanvas() throws {
        let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let out = try #require(ImageOutput.addingWindowShadow(c.makeImage()!, scale: 2))
        // blur 48 px, drop 20 px: 60 px each side, 40 above, 80 below
        #expect(out.width == 200 + 120 && out.height == 100 + 120)
        let rep = NSBitmapImageRep(cgImage: out)
        #expect(rep.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        let center = try #require(rep.colorAt(x: 160, y: 90)?.usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.99 && center.alphaComponent > 0.99)
    }

    @Test func fullScreenOverlaysOfBackgroundAppsAreNotSnapTargets() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func info(_ pid: Int32, _ r: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: 0, kCGWindowOwnerName as String: "App\(pid)",
             kCGWindowNumber as String: Int(pid), kCGWindowBounds as String: r.dictionaryRepresentation]
        }
        let list = [info(5, screen), info(6, screen), info(7, CGRect(x: 100, y: 100, width: 400, height: 300))]
        let windows = ScreenCapturer.windows(from: list, primaryHeight: 1080, ownPID: 1, screens: [screen],
                                             isRegularApp: { $0 != 5 })
        #expect(windows.map(\.pid) == [6, 7]) // the overlay of background app 5 is skipped, a full-screen app is not
    }
}

@Suite struct WheelStepperTests {
    private func run(_ events: [(CGFloat, TimeInterval)], precise: Bool = false, phased: Bool = false) -> [Int] {
        var stepper = WheelStepper()
        return events.map { stepper.step(delta: $0.0, precise: precise, phased: phased, at: $0.1) }.filter { $0 != 0 }
    }

    @Test func eachDeliberateWheelNotchIsOneStep() {
        #expect(run([(1, 0), (1, 0.4), (1, 0.8)]) == [1, 1, 1])
        #expect(run([(-1, 0), (-1, 0.4)]) == [-1, -1])
    }

    @Test func aRemoteSwipeBurstIsOneStep() {
        // As logged from a remote desktop session: fractions, then large accelerated deltas, ~20 ms apart.
        let burst: [CGFloat] = [0.1, 0.1, 0.46, 1.74, 3.54, 5.7, 6.3, 10.38, 13.57, 6.86, 5.86, 2.36]
        #expect(run(burst.enumerated().map { ($0.element, Double($0.offset) * 0.02) }) == [1])
    }

    @Test func fractionsAloneWaitUntilTheyAddUpToALine() {
        #expect(run([(0.1, 0), (0.1, 0.05), (0.1, 0.1)]).isEmpty)
        #expect(run((0..<10).map { (0.1, Double($0) * 0.05) }) == [1])
    }

    @Test func aPreciseWheelNotchWithoutPhaseIsOneStep() {
        #expect(run([(10, 0)], precise: true) == [1])
    }

    @Test func trackpadStepsByDistanceAndNotTooFast() {
        let swipe = (0..<12).map { (CGFloat(5), Double($0) * 0.05) } // 60 pt over 0.55 s
        #expect(run(swipe, precise: true, phased: true) == [1, 1, 1, 1])
    }
}

@Suite struct LaunchAtLoginTests {
    @Test func pendingApprovalShowsAsOn() {
        #expect(Settings.launchesAtLogin(.enabled))
        #expect(Settings.launchesAtLogin(.requiresApproval))
        #expect(!Settings.launchesAtLogin(.notRegistered))
        #expect(!Settings.launchesAtLogin(.notFound))
    }
}

@Suite struct TimestampNameTests {
    @Test func usesGregorianDigitsAndTwentyFourHours() {
        let date = Date(timeIntervalSince1970: 1_794_844_800) // 2026-11-16 16:00:00 UTC
        #expect(ImageOutput.timestampName(for: date, timeZone: TimeZone(identifier: "UTC")!)
                == "Shocrot 2026-11-16 at 16.00.00")
    }
}

@Suite("LLM reasoning")
struct ThinkingTests {
    @Test func reasoningIsHidden() {
        #expect(LLMTranslationService.stripThinking("<think>plan</think>\n\n你好") == "你好")
        #expect(LLMTranslationService.stripThinking("\n<think>plan</think>你好") == "你好")
        #expect(LLMTranslationService.stripThinking("\n<think>still thinking") == "")
    }

    @Test func aTagStillArrivingShowsNothing() {
        for partial in ["", "\n", "<", "<th", "<think"] { #expect(LLMTranslationService.stripThinking(partial) == "") }
    }

    @Test func plainTranslationsAreLeftAlone() {
        #expect(LLMTranslationService.stripThinking("你好") == "你好")
        #expect(LLMTranslationService.stripThinking("<b>粗体</b>") == "<b>粗体</b>")
        #expect(LLMTranslationService.stripThinking("think about it") == "think about it")
    }
}
