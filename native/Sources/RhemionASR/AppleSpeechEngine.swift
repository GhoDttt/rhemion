// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import Foundation
import RhemionCore
import Speech

/// Errors raised by `AppleSpeechEngine`.
public enum AppleSpeechError: Error, CustomStringConvertible {
    case unavailable
    case unsupported(String)
    case notInstalled(String)
    case noAudioFormat

    public var description: String {
        switch self {
        case .unavailable: return "Apple Speech needs macOS 26"
        case .unsupported(let code): return "Apple Speech doesn't support \(code)"
        case .notInstalled(let code): return "Apple Speech for \(code) is not on this Mac yet"
        case .noAudioFormat: return "Apple Speech offered no audio format"
        }
    }
}

/// Apple's on-device recognition (macOS 26 SpeechAnalyzer); see `AppleSpeech` in RhemionCore for the languages
/// and their packs. Both recognizers hear one language per take, so the session takes `.only(code)`; the runtime
/// picks the code.
public struct AppleSpeechEngine: TranscriptionEngine {
    public let id = AppleSpeech.modelID

    /// The language for a take that names none (`.auto`): the bench harness passes one; the runtime always names it.
    private let fallback: String

    public init(fallback: String = "en") { self.fallback = fallback }

    public func makeSession(language: LanguagePolicy) throws -> ASRSession {
        guard #available(macOS 26, *) else { throw AppleSpeechError.unavailable }
        let code: String
        switch language {
        case .only(let c): code = c
        case .script(let codes): code = codes.first ?? fallback
        case .auto: code = fallback
        }
        return AppleSpeechSession(code: code)
    }
}

/// Buffers the take's 16 kHz mono samples, then runs one SpeechAnalyzer pass over them on `finalize`.
@available(macOS 26, *)
final class AppleSpeechSession: ASRSession, @unchecked Sendable {
    private let code: String
    private var samples: [Int16] = []
    private let lock = NSLock()

    init(code: String) { self.code = code }

    func append(_ chunk: [Int16]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }

    func finalize() async throws -> String {
        let pcm = lock.withLock { samples }
        guard !pcm.isEmpty else { return "" }
        guard let module = await AppleSpeech.module(for: code) else { throw AppleSpeechError.unsupported(code) }
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else {
            FileHandle.standardError.write(Data("[apple] \(type(of: module)) for \(code): \(status)\n".utf8))
            throw AppleSpeechError.notInstalled(code)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppleSpeechError.noAudioFormat
        }
        let buffer = try Self.buffer(pcm, as: format)

        let analyzer = SpeechAnalyzer(modules: [module])
        // SpeechTranscriber marks its results final; DictationTranscriber over a finished take may only report
        // volatile ones, each the whole text so far. Keep the finals, plus the last volatile after them.
        let collect = Task<String, Error> {
            var final = "", pending = ""
            func take(_ text: String, _ isFinal: Bool) {
                if isFinal { final += text; pending = "" } else { pending = text }
            }
            if let m = module as? SpeechTranscriber {
                for try await r in m.results { take(String(r.text.characters), r.isFinal) }
            } else if let m = module as? DictationTranscriber {
                for try await r in m.results { take(String(r.text.characters), r.isFinal) }
            }
            return final + pending
        }
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        try await analyzer.start(inputSequence: input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The take as one buffer in the analyzer's format (converted from 16 kHz mono Int16).
    static func buffer(_ pcm: [Int16], as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.count))!
        input.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { input.int16ChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
        if format == source { return input }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw AppleSpeechError.noAudioFormat }
        let ratio = format.sampleRate / source.sampleRate
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(pcm.count) * ratio) + 1024)!
        var fed = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let failure { throw failure }
        return output
    }
}
