// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation

/// Downloads a catalogue file (a Whisper model) into place: to a hidden file in the destination folder, checked
/// against its SHA-256, then moved in, so a broken or interrupted download never looks like a model.
enum FileDownload {
    struct Mismatch: Error, CustomStringConvertible {
        var description: String { "the downloaded file is not the expected one (SHA-256 differs)" }
    }

    static func fetch(_ url: URL, sha256: String, to destination: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloaded = try await download(url, keepIn: folder, progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard try hash(of: downloaded) == sha256.lowercased() else { throw Mismatch() }
        let partial = folder.appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: downloaded, to: partial)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
    }

    private static func download(_ url: URL, keepIn folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let file, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.resume(throwing: URLError(.badServerResponse)); return
                    }
                    // URLSession deletes `file` when this returns: keep it.
                    let kept = folder.appendingPathComponent(".download-\(UUID().uuidString)")
                    do { try FileManager.default.moveItem(at: file, to: kept); continuation.resume(returning: kept) }
                    catch { continuation.resume(throwing: error) }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: { box.task?.cancel() }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }

    static func hash(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
