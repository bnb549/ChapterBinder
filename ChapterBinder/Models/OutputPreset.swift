import Foundation

enum OutputPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case spokenWord
    case spokenStereo
    case keepSource
    case high
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spokenWord: "Spoken Word (64 kbps mono)"
        case .spokenStereo: "Spoken Stereo (80 kbps)"
        case .keepSource: "Keep / match source"
        case .high: "High (128 kbps AAC)"
        case .custom: "Custom"
        }
    }

    var detail: String {
        switch self {
        case .spokenWord: "AAC 64 kbps · mono · 22.05 kHz. Default for CD speech."
        case .spokenStereo: "AAC 80 kbps · stereo · 44.1 kHz."
        case .keepSource: "Remux when every source is already AAC. No re-encode."
        case .high: "AAC 128 kbps · stereo · 44.1 kHz."
        case .custom: "Pick bitrate, channels, and sample rate."
        }
    }

    func settings(customBitrate: Int, customChannels: Int, customSampleRate: Int) -> EncodeSettings {
        switch self {
        case .spokenWord:
            EncodeSettings(keepSource: false, bitrateKbps: 64, channels: 1, sampleRate: 22050)
        case .spokenStereo:
            EncodeSettings(keepSource: false, bitrateKbps: 80, channels: 2, sampleRate: 44100)
        case .keepSource:
            EncodeSettings(keepSource: true, bitrateKbps: 0, channels: 0, sampleRate: 0)
        case .high:
            EncodeSettings(keepSource: false, bitrateKbps: 128, channels: 2, sampleRate: 44100)
        case .custom:
            EncodeSettings(
                keepSource: false,
                bitrateKbps: max(24, customBitrate),
                channels: customChannels == 1 ? 1 : 2,
                sampleRate: customSampleRate
            )
        }
    }
}
