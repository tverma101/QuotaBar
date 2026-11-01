import Foundation
import Darwin

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult

    /// Runs a child with a private stdin payload. Implementations that do not support stdin may
    /// continue to handle nil input through the default implementation.
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult
}

extension ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        guard standardInput == nil else {
            throw ProcessRunnerError.standardInputUnsupported
        }
        return try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            standardInput: nil,
            timeout: timeout
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Debug-only, basename + arg count only: arg *values* can carry paths/identifiers, so they
        // are never logged here.
        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = inputPipe

        // Drain both pipes on background queues, started BEFORE the child runs. A child that writes
        // more than the OS pipe buffer (~64KB) would otherwise block on write, never exit, and trip the
        // timeout below — reading only after exit deadlocks. (`ps -ax -o command=` alone is ~240KB.)
        let output = SubprocessOutput()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained)
        drain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained)

        // Register before `run()` so an instantly-exiting child can't race the waiter. Check task
        // cancellation while waiting: local database scans and superseded refreshes must not leave a
        // sqlite3 subprocess running for its full timeout after their owner has been cancelled.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()

        if let standardInput, let inputPipe {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                drained.wait()
                throw error
            }
        }

        let deadline = DispatchTime.now() + timeout
        while true {
            if Task<Never, Never>.isCancelled {
                terminate(
                    process,
                    pipeReaders: [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading],
                    exited: exited,
                    drained: drained
                )
                throw CancellationError()
            }
            let now = DispatchTime.now()
            guard now < deadline else {
                terminate(
                    process,
                    pipeReaders: [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading],
                    exited: exited,
                    drained: drained
                )
                throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
            }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            if exited.wait(timeout: .now() + min(remaining, 0.1)) == .success { break }
        }

        process.waitUntilExit()
        drained.wait()
        if Task<Never, Never>.isCancelled { throw CancellationError() }
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.stdoutString, stderr: output.stderrString)
    }

    /// Read a pipe to EOF on a background queue, accumulating into `output`. Started before the child
    /// runs so the pipe is continuously drained and can never fill (EOF arrives when the child exits and
    /// closes its write end).
    private func drain(_ handle: FileHandle, into output: SubprocessOutput, isStdout: Bool, group: DispatchGroup) {
        let box = FileHandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = box.handle.readDataToEndOfFile()
            if isStdout { output.setStdout(data) } else { output.setStderr(data) }
            group.leave()
        }
    }

    private func terminateProcessTree(rootPID: Int32) {
        let children = childPIDs(of: rootPID)
        for child in children {
            terminateProcessTree(rootPID: child)
        }
        kill(rootPID, SIGTERM)
        for child in children {
            kill(child, SIGKILL)
        }
    }

    private func terminate(
        _ process: Process,
        pipeReaders: [FileHandle],
        exited: DispatchGroup,
        drained: DispatchGroup
    ) {
        terminateProcessTree(rootPID: process.processIdentifier)
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        guard drained.wait(timeout: .now() + 1) == .timedOut else { return }

        // A detached descendant can inherit stdout/stderr after the process-tree snapshot. Do not
        // let its open pipe keep a cancelled refresh blocked forever.
        for reader in pipeReaders { try? reader.close() }
        if drained.wait(timeout: .now() + 1) == .timedOut {
            AppLog.warn(.subprocess, "terminated subprocess left an output pipe open after cancellation")
        }
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return []
        }

        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut(executable: String, timeout: TimeInterval)
    case standardInputUnsupported

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout))s."
        case .standardInputUnsupported:
            return "This process runner does not support standard input."
        }
    }
}

/// Passes a non-Sendable `FileHandle` into the background drain closure under Swift 6 strict
/// concurrency. The handle is read by exactly one queue, so the unchecked conformance is sound.
private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// Lock-guarded accumulator for the two concurrently-drained pipes.
private final class SubprocessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}

