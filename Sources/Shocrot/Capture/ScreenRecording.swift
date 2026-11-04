import AppKit
import AVFoundation
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Records a screen region to an MP4 in the save folder. 停止 or ⌃⌘⎋ finishes, 取消 discards.
/// Plain ↩ and Esc stay with the recorded app: they are part of what people demonstrate.
@MainActor
final class ScreenRecording: NSObject {
    private static var current: ScreenRecording?

    private let rect: CGRect // AppKit global points
    private let screen: NSScreen
    private let completion: (URL, TimeInterval) -> Void
    private let model = RecordingModel()
    private let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Shocrot-\(UUID().uuidString).mp4")
    private var stream: SCStream?
    /// How the recording output ended; nil while it is still writing.
    private var outputResult: Result<Void, Error>?
    private var outputWaiter: CheckedContinuation<Void, Never>?
    private var border: NSPanel?
    private var hud: NSPanel?
    private var clock: Timer?
    private var startedAt: Date?
    private var stopping = false
    /// The system ended the stream before `startCapture()` returned.
    private var endedWhileStarting = false
    /// Saving what a stopped recording produced; outlives the session's `current` slot.
    private static var finishing: Task<Void, Never>?

    static var isActive: Bool { current != nil }
    static var needsFinishing: Bool { current != nil || finishing != nil }

    /// Stops a running recording and waits until it and any earlier one are saved.
    static func finishBeforeQuit() async {
        current?.stop()
        await finishing?.value
    }

    static func start(rect: CGRect, on screen: NSScreen, completion: @escaping (URL, TimeInterval) -> Void) {
        guard current == nil else { return }
        let session = ScreenRecording(rect: rect.integral, screen: screen, completion: completion)
        current = session
        session.begin()
    }

    private init(rect: CGRect, screen: NSScreen, completion: @escaping (URL, TimeInterval) -> Void) {
        self.rect = rect
        self.screen = screen
        self.completion = completion
    }

    private func begin() {
        border = Self.makeBorder(around: rect)
        showHUD()
        // Same combination as the system's own screen recording; needs no permission.
        let registered = HotKeyCenter.shared.setTransient(HotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | controlKey))) { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        if !registered {
            model.stopShortcutAvailable = false
            Feedback.toast("⌃⌘⎋ 已被占用，请点“停止”结束录屏", symbol: "exclamationmark.triangle.fill")
        }
        Task { await record() }
    }

    private func record() async {
        do {
            // Let the selection overlay leave the screen before the first frame.
            try await Task.sleep(for: .milliseconds(200))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.noDisplay
            }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                       width: rect.width, height: rect.height)
            // H.264 wants even dimensions.
            config.width = Int(rect.width * scale) / 2 * 2
            config.height = Int(rect.height * scale) / 2 * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB

            let output = SCRecordingOutputConfiguration()
            output.outputURL = tempURL
            output.outputFileType = .mp4
            output.videoCodecType = .h264
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
            guard Self.current === self, !stopping else { return }
            try await stream.startCapture()
            // Cancelled while starting: nobody else knows about this stream yet.
            guard Self.current === self, !stopping else { await discard(stream); return }
            self.stream = stream
            startedAt = Date()
            if endedWhileStarting || outputResult != nil {
                saveAndClose(interrupted: true)
                return
            }
            model.isRecording = true
            clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startedAt = self.startedAt else { return }
                    self.model.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        } catch {
            guard !stopping else { return } // cancelled while starting; the failure doesn't matter
            close()
            removeTempFile()
            Feedback.error(error)
        }
    }

    func stop() {
        guard Self.current === self, !stopping else { return }
        guard stream != nil else { cancel(); return }
        saveAndClose()
    }

    /// Stops the stream and saves whatever was recorded, also when the system ended it early.
    private func saveAndClose(interrupted: Bool = false) {
        guard let stream, let startedAt, !stopping else { return }
        stopping = true
        let duration = Date().timeIntervalSince(startedAt)
        close()
        Self.finishing = Task {
            defer { Self.finishing = nil }
            var stopError: Error?
            do { try await stream.stopCapture() } catch { stopError = error }
            await waitForOutput()
            do {
                switch outputResult {
                case .success:
                    let url = try moveIntoSaveFolder()
                    if interrupted { Feedback.toast("录屏被系统中断，已保存此前的内容", symbol: "exclamationmark.triangle.fill") }
                    completion(url, duration)
                case let .failure(error):
                    throw error
                case nil:
                    throw stopError ?? CocoaError(.fileWriteUnknown)
                }
            } catch {
                keepFailedRecording(error)
            }
        }
    }

    /// Only 取消 discards. A file that couldn't be delivered may be all the user has of this recording.
    private func keepFailedRecording(_ error: Error) {
        let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            removeTempFile()
            Feedback.error(error)
            return
        }
        // The temporary folder gets purged, so prefer somewhere lasting.
        var kept = tempURL
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let url = ImageOutput.uniqueURL(in: movies, ext: "mp4")
            if (try? FileManager.default.moveItem(at: tempURL, to: url)) != nil { kept = url }
        }
        Feedback.toast("录屏未能正常保存，文件已保留：\(kept.lastPathComponent)", symbol: "exclamationmark.triangle.fill")
        NSWorkspace.shared.activateFileViewerSelecting([kept])
    }

    func cancel() {
        guard Self.current === self else { return }
        stopping = true
        let stream = stream
        close()
        guard let stream else { return } // not started; record() cleans up if it is about to
        Task { await discard(stream) }
    }

    private func discard(_ stream: SCStream) async {
        try? await stream.stopCapture()
        await waitForOutput()
        removeTempFile()
    }

    /// Returns once the output has ended, or after 5 seconds if it never reports back.
    private func waitForOutput() async {
        guard outputResult == nil else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputWaiter = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.resumeOutputWaiter()
            }
        }
    }

    private func resumeOutputWaiter() {
        outputWaiter?.resume()
        outputWaiter = nil
    }

    private func outputEnded(_ result: Result<Void, Error>) {
        guard outputResult == nil else { return }
        outputResult = result
        resumeOutputWaiter()
        guard !stopping, Self.current === self else { return }
        // Ended on its own, without the user stopping it.
        switch result {
        case .success:
            saveAndClose(interrupted: true)
        case let .failure(error):
            stopping = true
            let stream = stream
            close()
            Self.finishing = Task {
                defer { Self.finishing = nil }
                try? await stream?.stopCapture()
                keepFailedRecording(error)
            }
        }
    }

    private func removeTempFile() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func close() {
        clock?.invalidate()
        HotKeyCenter.shared.setTransient(nil)
        border?.orderOut(nil)
        hud?.orderOut(nil)
        border = nil
        hud = nil
        if Self.current === self { Self.current = nil }
    }

    private func moveIntoSaveFolder() throws -> URL {
        let dir = Settings.shared.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = ImageOutput.uniqueURL(in: dir, ext: "mp4")
        try FileManager.default.moveItem(at: tempURL, to: url)
        return url
    }

    // MARK: Windows

    static func makeBorder(around rect: CGRect) -> NSPanel {
        let inset: CGFloat = 3
        let p = NSPanel(contentRect: rect.insetBy(dx: -inset, dy: -inset), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        // Just outside the recorded area, so it never shows in the video.
        let ring = CAShapeLayer()
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: p.frame.size).insetBy(dx: 1, dy: 1),
                           cornerWidth: 4, cornerHeight: 4, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 2
        view.layer?.addSublayer(ring)
        p.contentView = view
        p.orderFrontRegardless()
        return p
    }

    private func showHUD() {
        let host = NSHostingView(rootView: RecordingHUD(model: model, onCancel: { [weak self] in self?.cancel() },
                                                        onStop: { [weak self] in self?.stop() }))
        let size = host.fittingSize
        let vf = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < vf.minY + 4 { origin.y = rect.maxY + 10 }
        if origin.y + size.height > vf.maxY - 4 { origin.y = rect.minY + 12 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.orderFrontRegardless()
        hud = p
    }
}

extension ScreenRecording: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.outputEnded(.success(())) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.outputEnded(.failure(error)) }
    }

    /// The display went to sleep, was unplugged, or the permission was revoked.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard Self.current === self, !self.stopping else { return }
            guard self.stream != nil else { self.endedWhileStarting = true; return }
            self.saveAndClose(interrupted: true)
        }
    }
}

@MainActor
final class RecordingModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var stopShortcutAvailable = true
}

private struct RecordingHUD: View {
    @ObservedObject var model: RecordingModel
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isRecording ? Color.red : Color.secondary)
                .frame(width: 9, height: 9)
                .symbolEffect(.pulse, isActive: model.isRecording)
                .frame(width: 16)
            Text(model.isRecording ? RecordingModel.format(model.elapsed) : "准备中…")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 70, alignment: .leading)
            Button("取消", action: onCancel)
                .buttonStyle(.glass)
                .help("取消并丢弃录屏")
            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("停止")
                }
                .fixedSize()
            }
            .buttonStyle(HUDProminentButtonStyle(color: .red))
            .help(model.stopShortcutAvailable ? "停止并保存 (⌃⌘⎋)" : "停止并保存")
            .disabled(!model.isRecording)
        }
        .controlSize(.regular)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.6)), in: .capsule)
        .animation(.easeOut(duration: 0.15), value: Int(model.elapsed))
        // The panel never becomes key; without this the buttons draw in their inactive grey.
        .environment(\.controlActiveState, .key)
        .padding(10)
    }
}

extension RecordingModel {
    nonisolated static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Turns a recording into a looping GIF next to it.
enum GIFExport {
    static let fps = 12.0
    static let maxPixelWidth = 960

    static func make(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelWidth, height: maxPixelWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let count = max(1, Int(duration * fps))
        let url = video.deletingPathExtension().appendingPathExtension("gif")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(dest, image, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// First frame, for the preview thumbnail.
    static func poster(of video: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: .zero).image
    }
}
