// MARK: - ProcessRunner.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Runs a command line tool, merging stdout and stderr, streaming lines as they arrive.

import Foundation
import Synchronization

nonisolated struct ProcessResult: Sendable {
    var status: Int32
    var output: String
    var timedOut: Bool
    var succeeded: Bool { status == 0 && !timedOut }
}

nonisolated enum ProcessRunner {
    /// Runs `executable` and returns once it has exited and its output is drained (or it is
    /// killed after `timeout`).
    ///
    /// Completion never blocks on the pipe: tools like xcodebuild can leave helper processes
    /// running that inherit the pipe, so EOF may never come. Output is read only through the
    /// readability handler, and a short grace period after exit finishes the run regardless.
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    timeout: TimeInterval = 3600,
                    onLine: @escaping @Sendable (String) -> Void) async -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collector = LineCollector(onLine: onLine)

        return await withCheckedContinuation { continuation in
            let run = RunState { timedOut in
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.finish()
                continuation.resume(returning: ProcessResult(status: process.terminationStatus,
                                                             output: collector.text, timedOut: timedOut))
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF. Clear the handler first: at EOF it would otherwise fire continuously.
                    handle.readabilityHandler = nil
                    run.reachedEOF()
                } else {
                    collector.append(data)
                }
            }
            process.terminationHandler = { _ in
                run.exited()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { run.forceFinish() }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                onLine("Could not launch \(executable): \(error.localizedDescription)")
                continuation.resume(returning: ProcessResult(status: -1, output: "\(error)", timedOut: false))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                run.markTimedOut()
                onLine("Timed out after \(Int(timeout))s; terminating.")
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

/// Finishes exactly once: when the process has exited and output hit EOF, or when forced.
private nonisolated final class RunState: Sendable {
    private struct Flags { var hasExited = false, hasEOF = false, isDone = false, timedOut = false }
    private let flags = Mutex(Flags())
    private let onFinish: @Sendable (Bool) -> Void

    init(onFinish: @escaping @Sendable (Bool) -> Void) { self.onFinish = onFinish }

    func exited() { update { $0.hasExited = true; return $0.hasEOF } }
    func reachedEOF() { update { $0.hasEOF = true; return $0.hasExited } }
    func forceFinish() { update { $0.hasExited } }
    func markTimedOut() { flags.withLock { $0.timedOut = true } }

    private func update(_ change: (inout Flags) -> Bool) {
        let finish: Bool = flags.withLock {
            guard !$0.isDone, change(&$0) else { return false }
            $0.isDone = true
            return true
        }
        if finish { onFinish(flags.withLock { $0.timedOut }) }
    }
}

private nonisolated final class LineCollector: Sendable {
    private struct Buffers { var pending = Data(), all = Data() }
    private let buffers = Mutex(Buffers())
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    var text: String { buffers.withLock { String(decoding: $0.all, as: UTF8.self) } }

    func append(_ data: Data) {
        let lines: [String] = buffers.withLock {
            $0.all.append(data)
            $0.pending.append(data)
            var lines: [String] = []
            while let newline = $0.pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: $0.pending[$0.pending.startIndex..<newline], as: UTF8.self))
                $0.pending.removeSubrange($0.pending.startIndex...newline)
            }
            return lines
        }
        lines.forEach(onLine)
    }

    func finish() {
        let rest: String? = buffers.withLock { buffers in
            defer { buffers.pending.removeAll() }
            return buffers.pending.isEmpty ? nil : String(decoding: buffers.pending, as: UTF8.self)
        }
        if let rest { onLine(rest) }
    }
}
