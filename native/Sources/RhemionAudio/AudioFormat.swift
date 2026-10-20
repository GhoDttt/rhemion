// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Target PCM format for recognition and the fallback WAV: 16 kHz, mono, signed 16-bit.
public enum AudioFormat {
    public static let sampleRate: UInt32 = 16000
    public static let channels: UInt16 = 1
    public static let bitsPerSample: UInt16 = 16
}
