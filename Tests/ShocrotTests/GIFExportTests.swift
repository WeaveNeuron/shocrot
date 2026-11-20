import AVFoundation
import ImageIO
import Testing
@testable import Shocrot

@Suite("GIF export")
struct GIFExportTests {
    /// Writes a 1-second, 30 fps H.264 clip whose colour changes every frame.
    private func makeClip(at url: URL, width: Int = 320, height: Int = 200) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = buffer!
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), Int32(i * 8), CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func makesALoopingGIFAtTwelveFPS() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("clip.mp4")
        try await makeClip(at: clip)

        let gif = try await GIFExport.make(from: clip)
        #expect(gif.pathExtension == "gif")
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 12)
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        #expect(loop == 0)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(first.width == 320 && first.height == 200)
        #expect(await GIFExport.poster(of: clip) != nil)
    }

    private func frames(of gif: URL) throws -> (count: Int, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (CGImageSourceGetCount(source), first.width, first.height)
    }

    @Test func usesTheChosenFrameRateAndWidth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("clip.mp4")
        try await makeClip(at: clip)

        var f = try frames(of: try await GIFExport.make(from: clip, fps: 10))
        #expect(f.count == 10 && f.width == 320 && f.height == 200)
        f = try frames(of: try await GIFExport.make(from: clip, fps: 15, maxWidth: 160))
        #expect(f.count == 15 && f.width == 160 && f.height == 100)
        // A cap wider than the recording leaves it as it is.
        f = try frames(of: try await GIFExport.make(from: clip, fps: 12, maxWidth: 1280))
        #expect(f.count == 12 && f.width == 320 && f.height == 200)
        #expect(await GIFExport.duration(of: clip).map { abs($0 - 1) < 0.05 } == true)
    }

    @Test func asksOnlyAboutClipsOverAMinute() {
        #expect(!GIFExport.isLong(59.9))
        #expect(!GIFExport.isLong(60))
        #expect(GIFExport.isLong(60.5))
    }

    @Test func onlyOffersKnownOptions() {
        #expect(GIFOptions.frameRates.contains(GIFOptions.defaultFrameRate) && GIFOptions.defaultFrameRate == 12)
        #expect(GIFOptions.maxWidths == [0, 1280, 800] && GIFOptions.defaultMaxWidth == 0)
        #expect(GIFOptions.widthTitle(0) == L("gif.originalSize"))
        #expect(GIFOptions.widthTitle(800) == L("gif.widthPixels", 800))
    }
}
