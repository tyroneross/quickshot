import Foundation
import Testing
import TestSupport
@testable import QuickShotCore

/// These tests spawn a real child process. A shell script stands in for the
/// system tool so the path runs without Screen Recording permission.
@Suite struct CaptureRunnerTests {
    @Test func reportsTheFileTheToolWrote() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("\(Fixture.pngPrintf) > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        let result = await runner.run(.screenshot)

        guard case .captured(let files)? = result else {
            Issue.record("expected a captured file, got \(String(describing: result))")
            return
        }
        #expect(files.count == 1)
        #expect(CaptureFormat.detect(files[0]) == CaptureFormat(kind: .image, fileExtension: "png"))
        #expect(!runner.isRunning)
    }

    @Test func passesTheRealCommandLineToTheTool() async throws {
        let folder = try TempFolder()
        let log = folder.url.appendingPathComponent("args.txt")
        let tool = try folder.script("echo \"$@\" > '\(log.path)'; \(Fixture.pngPrintf) > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        _ = await runner.run(.recording)

        let arguments = try String(contentsOf: log, encoding: .utf8)
        #expect(arguments.hasPrefix("-v "))
        #expect(arguments.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/capture.mov"))
    }

    @Test func aSilentExitWithoutAFileIsCancelled() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("exit 1")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        #expect(await runner.run(.screenshot) == .cancelled)
        #expect(try scratchFolders(in: folder).isEmpty)
    }

    @Test func anErrorMessageWithoutAFileIsAFailure() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("echo 'could not create image from display' >&2; exit 1")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        #expect(await runner.run(.screenshot) == .failed("could not create image from display"))
    }

    @Test func anEmptyFileDoesNotCountAsACapture() async throws {
        let folder = try TempFolder()
        let tool = try folder.script(": > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        #expect(await runner.run(.screenshot) == .cancelled)
    }

    @Test func aMissingToolIsAFailureNotACrash() async throws {
        let folder = try TempFolder()
        let runner = CaptureRunner(
            executable: folder.url.appendingPathComponent("does-not-exist"),
            scratchRoot: folder.url
        )

        guard case .failed(let message)? = await runner.run(.screenshot) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("does-not-exist"))
        #expect(!runner.isRunning)
    }

    @Test func cancelTerminatesTheToolAndKeepsWhatItWrote() async throws {
        let folder = try TempFolder()
        // Runs until terminated, then writes a movie on the way out.
        let tool = try folder.script("""
        trap 'printf "\\000\\000\\000\\024ftypqt  0000" > "$OUT"; exit 0' TERM
        : > '\(folder.url.path)/started'
        while :; do sleep 0.05; done
        """)
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        async let pending = runner.run(.recording)
        try await waitForFile(folder.url.appendingPathComponent("started"))
        #expect(runner.isRunning)
        runner.cancel()

        guard case .captured(let files)? = await pending else {
            Issue.record("expected the file written before exit to be kept")
            return
        }
        #expect(CaptureFormat.detect(files[0])?.kind == .video)
    }

    @Test func aSecondRequestWhileOneRunsIsRefused() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("""
        : > '\(folder.url.path)/started'
        while :; do sleep 0.05; done
        """)
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        async let first = runner.run(.screenshot)
        try await waitForFile(folder.url.appendingPathComponent("started"))
        #expect(await runner.run(.screenshot) == nil)
        runner.cancel()
        #expect(await first == .cancelled)
    }

    /// The system picker ignores an interrupt, so cancel must not rely on one.
    @Test func cancelClosesAToolThatIgnoresInterrupts() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("""
        trap '' INT
        : > '\(folder.url.path)/started'
        while :; do sleep 0.05; done
        """)
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        async let pending = runner.run(.screenshot)
        try await waitForFile(folder.url.appendingPathComponent("started"))
        runner.cancel()
        #expect(await pending == .cancelled)
        #expect(!runner.isRunning)
    }

    /// A tool that floods standard error must not stall the capture, and the
    /// notice keeps only the start of the message.
    @Test(.timeLimit(.minutes(1)))
    func aToolThatFloodsStandardErrorStillFinishes() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("echo 'first line of the error' >&2; head -c 400000 /dev/zero | tr '\\0' 'x' >&2; exit 1")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        guard case .failed(let message)? = await runner.run(.screenshot) else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.hasPrefix("first line of the error"))
        #expect(message.count <= CaptureRunner.messageLimit)
        #expect(try leftovers(in: folder).isEmpty, "scratch folder and error log must be cleaned up")
    }

    /// Cancelling before the tool has started must stop it from starting.
    @Test func aTaskCancelledBeforeTheToolStartsNeverRunsIt() async throws {
        let folder = try TempFolder()
        let marker = folder.url.appendingPathComponent("ran")
        let tool = try folder.script(": > '\(marker.path)'; \(Fixture.pngPrintf) > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        let task = Task { () -> CaptureResult? in
            // Cancelled before run() is entered.
            await Task.yield()
            return await runner.run(.screenshot)
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the tool was started despite the cancel")
        #expect(!runner.isRunning)
    }

    @Test func cancellingTheTaskClosesARunningTool() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("""
        : > '\(folder.url.path)/started'
        while :; do sleep 0.05; done
        """)
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        let task = Task { await runner.run(.screenshot) }
        try await waitForFile(folder.url.appendingPathComponent("started"))
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    /// An empty file holds nothing: it is removed and the scratch folder with it.
    @Test func anEmptyFileIsRemovedWithItsScratchFolder() async throws {
        let folder = try TempFolder()
        let tool = try folder.script(": > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        #expect(await runner.run(.screenshot) == .cancelled)
        #expect(try leftovers(in: folder).isEmpty)
    }

    /// Stop Recording: the tool is interrupted, finishes the movie and exits.
    @Test func finishingARecordingKeepsTheMovieTheToolWrites() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("""
        trap 'printf "\\000\\000\\000\\024ftypqt  0000" > "$OUT"; exit 0' INT
        : > '\(folder.url.path)/started'
        while :; do sleep 0.05; done
        """)
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        async let pending = runner.run(.recording)
        try await waitForFile(folder.url.appendingPathComponent("started"))
        runner.finishRecording()

        guard case .captured(let files)? = await pending else {
            Issue.record("expected the finished recording to be kept")
            return
        }
        #expect(CaptureFormat.detect(files[0]) == CaptureFormat(kind: .video, fileExtension: "mov"))
    }

    @Test func finishingWithNothingRunningDoesNothing() {
        #expect(!CaptureRunner(executable: URL(fileURLWithPath: "/usr/bin/true")).finishRecording())
    }

    @Test func cancelWithNothingRunningDoesNothing() async throws {
        let folder = try TempFolder()
        let tool = try folder.script("\(Fixture.pngPrintf) > \"$OUT\"")
        let runner = CaptureRunner(executable: tool, scratchRoot: folder.url)

        runner.cancel()

        // The stale cancel must not leak into the next capture.
        guard case .captured? = await runner.run(.screenshot) else {
            Issue.record("a cancel issued while idle cancelled the next capture")
            return
        }
    }

    private func scratchFolders(in folder: TempFolder) throws -> [String] {
        try leftovers(in: folder)
    }

    /// Scratch folders and error logs the runner left behind.
    private func leftovers(in folder: TempFolder) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasPrefix("QuickShot-") }
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "the fake tool never started")
    }
}
