// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// SampleSink backed by a WAVWriter — the per-take fallback WAV.
public final class WAVFileSink: SampleSink {
    private let writer: WAVWriter
    private var failed = false

    public init(url: URL) throws {
        self.writer = try WAVWriter(url: url)
    }

    public func write(_ samples: [Int16]) {
        guard !failed else { return }
        do { try writer.append(samples) } catch { failed = true }
    }

    public func finish() {
        try? writer.finalize()
    }
}
