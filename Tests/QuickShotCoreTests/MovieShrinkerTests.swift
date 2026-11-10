import AVFoundation
import CoreVideo
import Foundation
import Testing
import TestSupport
@testable import QuickShotCore

@Suite struct MovieShrinkerTests {
    /// Writes a short movie at a Retina-like size, the way the recorder does.
    static func makeMovie(at url: URL, width: Int = 2560, height: Int = 1600, frames: Int = 12) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            // Noise-like content, so the file is not trivially small.
            let base = try #require(CVPixelBufferGetBaseAddress(pixels))
            let bytes = CVPixelBufferGetBytesPerRow(pixels) * height
            var seed = UInt32(frame + 1)
            for i in 0..<bytes {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                base.storeBytes(of: UInt8(truncatingIfNeeded: seed >> 24), toByteOffset: i, as: UInt8.self)
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
    }

    @Test func aRetinaRecordingBecomesASmaller1080pMovieAndTheSourceStays() async throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.mov")
        try Self.makeMovie(at: source)
        let before = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)

        let small = try await MovieShrinker.shrink(source)

        #expect(small.lastPathComponent == "capture.1080p.mp4")
        #expect(FileManager.default.fileExists(atPath: source.path), "the source is the caller's to keep or remove")
        let after = try #require(try FileManager.default.attributesOfItem(atPath: small.path)[.size] as? Int)
        #expect(after < before, "\(after) is not smaller than \(before)")
        let track = try #require(try await AVURLAsset(url: small).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(max(size.width, size.height) <= 1920)
        #expect(CaptureFormat.detect(small)?.kind == .video)
    }

    /// An App or Window Quick recording is made at the Quick size already;
    /// exporting it again would only cost time and a little quality.
    @Test func aMovieThatAlreadyFitsIsReturnedAsItIs() async throws {
        let folder = try TempFolder()
        let source = folder.url.appendingPathComponent("capture.mov")
        try Self.makeMovie(at: source, width: 1280, height: 800, frames: 4)
        #expect(try await MovieShrinker.shrink(source) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["capture.mov"])
    }

    @Test func fittingKeepsProportionsAndLeavesSmallSizesAlone() {
        #expect(MovieShrinker.fitted(CGSize(width: 3456, height: 2234)) == CGSize(width: 1920, height: 1241))
        #expect(MovieShrinker.fitted(CGSize(width: 1000, height: 2400)) == CGSize(width: 800, height: 1920))
        #expect(MovieShrinker.fitted(CGSize(width: 1280, height: 800)) == CGSize(width: 1280, height: 800))
    }

    @Test func aFileThatIsNotAMovieIsRefusedAndLeftAlone() async throws {
        let folder = try TempFolder()
        let text = folder.url.appendingPathComponent("notes.mov")
        try Data(Fixture.text).write(to: text)

        await #expect(throws: MovieShrinker.Failure.notAMovie) { try await MovieShrinker.shrink(text) }
        #expect(try Data(contentsOf: text) == Data(Fixture.text))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["notes.mov"])
    }
}
