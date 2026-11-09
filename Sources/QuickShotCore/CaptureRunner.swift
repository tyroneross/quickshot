import Foundation

/// How one run of the capture tool ended.
public enum CaptureResult: Sendable, Equatable {
    /// The tool wrote these files into a scratch folder. They are not filed yet.
    case captured([URL])
    /// The tool exited without a file and without an error message: the person
    /// pressed Escape, or the toolbar saved somewhere other than the path given.
    case cancelled
    /// The tool reported an error, or could not be started.
    case failed(String)
}

/// Runs the capture tool as a child process and reports what it produced.
///
/// The executable is injectable so the whole path can be exercised in tests
/// without Screen Recording permission.
public final class CaptureRunner: @unchecked Sendable {
    private let executable: URL
    private let scratchRoot: URL
    private let lock = NSLock()
    private var current: Process?
    private var launched = false
    private var cancelRequested = false

    public init(
        executable: URL = CaptureCommand.systemExecutable,
        scratchRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.executable = executable
        self.scratchRoot = scratchRoot
    }

    public var isRunning: Bool {
        lock.withLock { current != nil }
    }

    /// Opens the picker and waits for the tool to exit. Returns `nil` when a
    /// capture is already running, so callers cannot stack two pickers.
    ///
    /// Cancelling the calling task cancels the capture at any point: before
    /// launch nothing is started, after launch the tool is terminated.
    public func run(_ mode: CaptureMode, preset: RecordingPreset = .quick) async -> CaptureResult? {
        let id = UUID().uuidString
        let scratch = scratchRoot.appendingPathComponent("QuickShot-\(id)", isDirectory: true)
        let process = Process()
        // The tool's messages are drained while it runs, so a noisy tool can
        // neither block on a full pipe nor fill the disk. Only the start is kept.
        let errorPipe = Pipe()
        let errorText = BoundedText(limit: Self.messageLimit)

        let claimed = lock.withLock { () -> Bool in
            guard current == nil else { return false }
            current = process
            launched = false
            cancelRequested = false
            return true
        }
        guard claimed else { return nil }
        defer { lock.withLock { current = nil; launched = false } }
        if Task.isCancelled { return .cancelled }

        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create a scratch folder in \(scratchRoot.path): \(error.localizedDescription)")
        }
        let errorReader = errorPipe.fileHandleForReading
        process.standardError = errorPipe
        errorReader.readabilityHandler = { errorText.append($0.availableData) }
        defer { errorReader.readabilityHandler = nil }

        let output = scratch.appendingPathComponent(CaptureCommand.requestedFileName(for: mode))
        process.executableURL = executable
        process.arguments = CaptureCommand.arguments(for: mode, preset: preset, output: output)
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try process.run()
                        // A cancel that arrived before launch is honoured now.
                        let cancelNow = lock.withLock { () -> Bool in
                            launched = true
                            return cancelRequested
                        }
                        if cancelNow { process.terminate() }
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                self.cancel()
            }
        } catch {
            rmdir(scratch.path)
            return .failed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        let files: [URL]
        do {
            files = try Self.captures(in: scratch)
        } catch {
            // Never delete what could not be inspected.
            return .failed("Could not read the capture in \(scratch.path): \(error.localizedDescription)")
        }
        if !files.isEmpty { return .captured(files) }

        // Nothing was captured. `rmdir` removes only an empty folder, so this
        // cleanup cannot take a file with it.
        rmdir(scratch.path)
        errorReader.readabilityHandler = nil
        errorText.append(Self.remainingBytes(of: errorReader))
        let message = errorText.text
        return message.isEmpty ? .cancelled : .failed(message)
    }

    /// Ends a recording. The tool finishes the movie and exits (measured on
    /// macOS 27.0.1: a recording interrupted after 3 s was a valid 2.9 s
    /// movie). The screenshot picker ignores this signal; use `cancel()`.
    ///
    /// Returns `false` when no launched tool was there to signal, for example
    /// when Stop arrives in the instant before the recorder starts. The caller
    /// then cancels instead, since nothing has been recorded yet.
    @discardableResult
    public func finishRecording() -> Bool {
        guard let running = lock.withLock({ launched ? current : nil }) else { return false }
        running.interrupt()
        return true
    }

    /// Closes the picker by terminating the tool. The system picker ignores an
    /// interrupt while it is open (measured on macOS 27.0.1), so this sends a
    /// terminate signal. Anything the tool already wrote is still reported.
    ///
    /// Safe at any moment: a process that has not launched yet cannot be
    /// signalled, so the request is remembered and applied right after launch.
    public func cancel() {
        let running = lock.withLock { () -> Process? in
            guard let current else { return nil }
            guard launched else {
                cancelRequested = true
                return nil
            }
            return current
        }
        running?.terminate()
    }

    /// The non-empty files the tool wrote. Empty files hold nothing and are
    /// removed. Throws when the folder cannot be read, so the caller never
    /// mistakes "could not look" for "nothing there".
    static func captures(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var captures: [URL] = []
        for url in contents {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > 0 {
                captures.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return captures.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// How much of the tool's error output is kept for a notice.
    static let messageLimit = 2_000

    /// Whatever is still buffered in the pipe after the tool has exited, read
    /// without blocking so a lingering writer cannot stall the result.
    static func remainingBytes(of handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while collected.count < messageLimit {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { break }
            collected.append(contentsOf: chunk[0..<count])
        }
        return collected
    }
}

/// Keeps the first `limit` bytes appended to it and drops the rest.
final class BoundedText: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ more: Data) {
        lock.withLock {
            let room = limit - data.count
            if room > 0 { data.append(more.prefix(room)) }
        }
    }

    var text: String {
        let bytes = lock.withLock { data }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
