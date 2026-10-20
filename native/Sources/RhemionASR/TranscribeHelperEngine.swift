// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import RhemionAudio

/// Whisper and Qwen3-ASR through `rhemion-transcribe`, the helper inside Rhemion.app built on transcribe.cpp.
/// Unlike `WhisperEngine`, which starts whisper-cli for every take, the helper loads
/// the model once and keeps it while this model is in use (measured on an M1 Pro, 10 s takes: Whisper
/// large-v3-turbo Q5 about 1.3 s in a known language, 2.4 s detecting it; Qwen3-ASR 1.7B Q5 about 1.0 s). It is our
/// child, spoken to over its own stdin/stdout, so nothing else on the Mac can reach it, and it runs in a sandbox
/// without network (`HelperSandbox`).
public final class TranscribeHelperEngine: TranscriptionEngine, @unchecked Sendable {
    public let id: String
    private let helper: TranscribeHelper

    /// `id` is the engine kind the runtime logs: "whisper" or "qwen".
    public init(id: String, helper: String, model: String) {
        self.id = id
        self.helper = TranscribeHelper(binary: helper, model: (model as NSString).expandingTildeInPath)
    }

    /// The helper next to this executable (`Contents/Helpers/rhemion-transcribe`), when present.
    public static func bundledHelper() -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("rhemion-transcribe").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public func makeSession(language: LanguagePolicy) throws -> ASRSession {
        TranscribeHelperSession(helper: helper, language: language.whisperFlag)
    }

    @discardableResult public func prewarm() async -> Bool { await helper.start() }

    public func unload() async { await helper.stop() }
}

/// The running helper: started on prewarm (or the first take), stopped on unload. If it dies, the next take
/// starts it again once; a second failure in a row is reported as an error, not as silence.
actor TranscribeHelper {
    private let binary: String
    private let model: String
    private var process: Process?
    private var input: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?

    /// Loading takes a few seconds; the first start after install also compiles Metal shaders (~10 s).
    static let startTimeout: Duration = .seconds(180)
    static let takeTimeout: Duration = .seconds(120)

    init(binary: String, model: String) { self.binary = binary; self.model = model }

    @discardableResult func start() async -> Bool {
        if process?.isRunning == true { return true }
        do { try await launch(); return true } catch {
            log("[transcribe] helper didn't start: \(error)")
            return false
        }
    }

    func stop() {
        input?.closeFile()
        if let p = process, p.isRunning { p.terminate() }
        process = nil; input = nil; lines = nil
    }

    /// One take: returns the text, throws when the helper fails.
    func transcribe(wav: URL, language: String) async throws -> String {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                if process?.isRunning != true { try await launch() }
                let reply = try await request("\(language)\t\(wav.path)", timeout: Self.takeTimeout)
                let parts = reply.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if parts.first == "ok", parts.count >= 2 { return Self.unescape(parts[1]) }
                throw WhisperEngineError.processLaunchFailed(parts.dropFirst().joined(separator: " "))
            } catch let error as WhisperEngineError {
                throw error                                    // the helper answered: a real error, no restart
            } catch {
                lastError = error                              // it died or hung: start it again once
                stop()
            }
        }
        throw lastError ?? WhisperEngineError.processLaunchFailed("helper failed")
    }

    private func launch() async throws {
        stop()
        try validateTrustedExecutable(binary)
        guard FileManager.default.fileExists(atPath: model) else { throw WhisperEngineError.modelNotFound(model) }
        let command = HelperSandbox.command(helper: binary, arguments: [model], model: model,
                                            takes: WhisperEngine.temporaryRoot())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.executable)
        p.arguments = command.arguments
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.standardError         // whisper's own log lands in the runtime log
        do { try p.run() } catch { throw WhisperEngineError.processLaunchFailed(error.localizedDescription) }
        process = p
        input = stdin.fileHandleForWriting
        lines = stdout.fileHandleForReading.bytes.lines.makeAsyncIterator()
        let first = try await read(timeout: Self.startTimeout)
        guard first == "ready" else {
            stop()
            throw WhisperEngineError.processLaunchFailed(first.replacingOccurrences(of: "\t", with: " "))
        }
        log("[transcribe] helper ready (\(URL(fileURLWithPath: model).lastPathComponent))")
    }

    private func request(_ line: String, timeout: Duration) async throws -> String {
        guard let input else { throw CancellationError() }
        try input.write(contentsOf: Data((line + "\n").utf8))
        return try await read(timeout: timeout)
    }

    private struct Timeout: Error {}
    private struct Closed: Error {}

    /// The next line from the helper, or an error when it closes its output or doesn't answer in time.
    private func read(timeout: Duration) async throws -> String {
        guard var iterator = lines else { throw Closed() }
        let process = self.process
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process?.terminate()                           // closes its output, which ends the read below
        }
        defer { watchdog.cancel() }
        let line = try await iterator.next()
        lines = iterator
        guard let line else { throw watchdog.isCancelled ? Closed() : Timeout() }
        return line
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaped = false
        for c in s {
            if escaped {
                out.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaped = false
            } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    private func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}

private final class TranscribeHelperSession: ASRSession {
    private let helper: TranscribeHelper
    private let language: String
    private var samples: [Int16] = []

    init(helper: TranscribeHelper, language: String) { self.helper = helper; self.language = language }

    func append(_ samples: [Int16]) { self.samples.append(contentsOf: samples) }

    func finalize() async throws -> String {
        guard !samples.isEmpty else { return "" }
        let wav = WhisperEngine.temporaryRoot().appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let writer = try WAVWriter(url: wav)
        try writer.append(samples)
        try writer.finalize()
        return try await helper.transcribe(wav: wav, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
