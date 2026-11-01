import AppKit
import AVFoundation
import Carbon.HIToolbox
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Records a screen region to an MP4 in the save folder. ↩ or 停止 finishes, Esc or 取消 discards.
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
    private var finished: CheckedContinuation<Error?, Never>?
    private var border: NSPanel?
    private var hud: NSPanel?
    private var keyTap: KeyInterceptor?
    private var clock: Timer?
    private var startedAt: Date?
    private var stopping = false

    static var isActive: Bool { current != nil }

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
        keyTap = KeyInterceptor(keyCodes: [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape]) { [weak self] code in
            if code == kVK_Escape { self?.cancel() } else { self?.stop() }
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
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
            guard Self.current === self, !stopping else { return }
            try await stream.startCapture()
            self.stream = stream
            startedAt = Date()
            model.isRecording = true
            clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let startedAt = self.startedAt else { return }
                    self.model.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        } catch {
            close()
            Feedback.error(error)
        }
    }

    func stop() {
        guard Self.current === self, !stopping else { return }
        guard let stream, let startedAt else { cancel(); return }
        stopping = true
        let duration = Date().timeIntervalSince(startedAt)
        close()
        Task {
            let error = await withCheckedContinuation { cont in
                finished = cont
                Task { try? await stream.stopCapture() }
            }
            if let error {
                Feedback.error(error)
                return
            }
            do {
                completion(try moveIntoSaveFolder(), duration)
            } catch {
                Feedback.error(error)
            }
        }
    }

    func cancel() {
        guard Self.current === self else { return }
        stopping = true
        let stream = stream
        close()
        Task {
            try? await stream?.stopCapture()
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func close() {
        clock?.invalidate()
        keyTap?.stop()
        keyTap = nil
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

extension ScreenRecording: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finished?.resume(returning: nil); self.finished = nil }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            if let finished = self.finished {
                finished.resume(returning: error)
                self.finished = nil
            } else if !self.stopping {
                self.close()
                Feedback.error(error)
            }
        }
    }
}

@MainActor
final class RecordingModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
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
                .help("取消 (Esc)")
            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("停止")
                }
                .fixedSize()
            }
            .buttonStyle(HUDProminentButtonStyle(color: .red))
            .help("停止并保存 (↩)")
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
