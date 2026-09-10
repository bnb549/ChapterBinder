import Foundation

/// Writes 16-bit 44.1 kHz PCM WAV files. Used by the mock CD ripper so the rest
/// of the pipeline can run without optical hardware.
nonisolated enum WAVWriter {
    static let sampleRate: UInt32 = 44100
    static let channels: UInt16 = 2
    static let bitsPerSample: UInt16 = 16

    static func writeSilence(duration: TimeInterval, to url: URL) throws {
        let frames = max(1, Int((duration * Double(sampleRate)).rounded()))
        let dataBytes = frames * Int(channels) * Int(bitsPerSample / 8)
        var data = Data(count: 44 + dataBytes)

        func write(_ string: String, at offset: Int) {
            data.replaceSubrange(offset..<(offset + string.count), with: string.data(using: .ascii)!)
        }
        func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { raw in
                data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: raw)
            }
        }

        write("RIFF", at: 0)
        writeLE(UInt32(36 + dataBytes), at: 4)
        write("WAVE", at: 8)
        write("fmt ", at: 12)
        writeLE(UInt32(16), at: 16)
        writeLE(UInt16(1), at: 20) // PCM
        writeLE(channels, at: 22)
        writeLE(sampleRate, at: 24)
        writeLE(UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8), at: 28)
        writeLE(UInt16(channels * bitsPerSample / 8), at: 32)
        writeLE(bitsPerSample, at: 34)
        write("data", at: 36)
        writeLE(UInt32(dataBytes), at: 40)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
