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
    public func run(_ mode: CaptureMode) async -> CaptureResult? {
        let scratch = scratchRoot.appendingPathComponent("QuickShot-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        let errorPipe = Pipe()

        let claimed = lock.withLock { () -> Bool in
            guard current == nil else { return false }
            current = process
            launched = false
            cancelRequested = false
            return true
        }
        guard claimed else { return nil }
        defer { lock.withLock { current = nil; launched = false } }

        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failed("Could not create a scratch folder: \(error.localizedDescription)")
        }

        let output = scratch.appendingPathComponent(CaptureCommand.requestedFileName(for: mode))
        process.executableURL = executable
        process.arguments = CaptureCommand.arguments(for: mode, output: output)
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let errorText: String
        do {
            errorText = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { _ in
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
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
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return .failed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        let files = Self.files(in: scratch)
        if !files.isEmpty { return .captured(files) }

        try? FileManager.default.removeItem(at: scratch)
        let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? .cancelled : .failed(message)
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

    static func files(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
