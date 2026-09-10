import AVFoundation
import CoreMedia
import Foundation

enum ProbeService {
    static func probe(url: URL) async throws -> ProbeResult {
        if HelperBinary.ffprobeAvailable {
            do {
                return try await probeWithFFProbe(url: url)
            } catch {
                return try await probeWithAVFoundation(url: url)
            }
        }
        return try await probeWithAVFoundation(url: url)
    }

    static func probeWithFFProbe(url: URL) async throws -> ProbeResult {
        let ffprobe = try HelperBinary.ffprobe.url()
        let result = try await ProcessRunner.run(
            executable: ffprobe,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                url.path,
            ]
        )
        guard result.exitCode == 0 else {
            throw AppError.probeFailed(result.stderr.isEmpty ? "ffprobe exit \(result.exitCode)" : result.stderr)
        }
        return try parseFFProbeJSON(result.stdout, fallbackPath: url)
    }

    static func probeWithAVFoundation(url: URL) async throws -> ProbeResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let audio = tracks.first { $0.mediaType == .audio }

        var codec = url.pathExtension.lowercased()
        var channels = 2
        var sampleRate = 44100
        var bitrate: Int?

        if let audio {
            let descriptions = (try? await audio.load(.formatDescriptions)) ?? []
            if let cm = descriptions.first {
                if let name = CMFormatDescriptionGetMediaSubType(cm).fourCC {
                    codec = name
                }
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cm)?.pointee {
                    channels = Int(asbd.mChannelsPerFrame)
                    sampleRate = Int(asbd.mSampleRate)
                }
            }
            if let rate = try? await audio.load(.estimatedDataRate) {
                bitrate = Int(rate)
            }
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        let items = await loadMetadata(metadata)

        var chapters: [EmbeddedChapter] = []
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        let languages = locales.map(\.identifier)
        let groups: [AVTimedMetadataGroup]
        if languages.isEmpty {
            groups = []
        } else {
            groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)) ?? []
        }
        for group in groups {
            let start = group.timeRange.start.seconds
            let dur = group.timeRange.duration.seconds
            let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
            let title = (try? await titleItem?.load(.stringValue)) ?? "Chapter"
            chapters.append(EmbeddedChapter(title: title, start: start, duration: dur))
        }

        let hasCover = metadata.contains { $0.commonKey == .commonKeyArtwork }

        return ProbeResult(
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            codec: codec,
            channels: channels,
            sampleRate: sampleRate,
            bitrate: bitrate,
            title: items["title"],
            artist: items["artist"],
            album: items["album"],
            albumArtist: items["albumArtist"],
            composer: items["composer"],
            narrator: items["composer"],
            trackNumber: parseTrack(items["track"]),
            discNumber: parseTrack(items["disc"]),
            year: parseYear(items["date"] ?? items["year"]),
            genre: items["genre"],
            comment: items["comment"],
            description: items["description"],
            hasCover: hasCover,
            chapters: chapters,
            tags: items
        )
    }

    private static func loadMetadata(_ metadata: [AVMetadataItem]) async -> [String: String] {
        var tags: [String: String] = [:]
        for item in metadata {
            let key: String
            if let common = item.commonKey?.rawValue {
                key = common
            } else if let ident = item.identifier?.rawValue {
                key = ident
            } else {
                continue
            }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                tags[key] = value
                let short = key.split(separator: "/").last.map(String.init) ?? key
                tags[short] = value
            }
        }
        return tags
    }

    private static func parseFFProbeJSON(_ json: String, fallbackPath: URL) throws -> ProbeResult {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AppError.probeFailed("Invalid ffprobe JSON for \(fallbackPath.lastPathComponent)")
        }

        let format = root["format"] as? [String: Any] ?? [:]
        let tags = (format["tags"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { acc, pair in
            acc[pair.key.lowercased()] = String(describing: pair.value)
        }

        let streams = root["streams"] as? [[String: Any]] ?? []
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" } ?? [:]
        let hasCover = streams.contains { ($0["codec_type"] as? String) == "video" }

        let duration = Double(format["duration"] as? String ?? "") ?? Double(audio["duration"] as? String ?? "") ?? 0
        let codec = (audio["codec_name"] as? String) ?? fallbackPath.pathExtension
        let channels = audio["channels"] as? Int ?? 2
        let sampleRate = Int(audio["sample_rate"] as? String ?? "") ?? 44100
        let bitrate = Int(audio["bit_rate"] as? String ?? format["bit_rate"] as? String ?? "")

        let chapterJSON = root["chapters"] as? [[String: Any]] ?? []
        let chapters: [EmbeddedChapter] = chapterJSON.compactMap { ch in
            let start = Double(ch["start_time"] as? String ?? "") ?? (ch["start_time"] as? Double)
            let end = Double(ch["end_time"] as? String ?? "") ?? (ch["end_time"] as? Double)
            guard let start else { return nil }
            let dur: TimeInterval
            if let end { dur = max(0, end - start) } else { dur = 0 }
            let ctags = (ch["tags"] as? [String: Any]) ?? [:]
            let title = (ctags["title"] as? String) ?? "Chapter"
            return EmbeddedChapter(title: title, start: start, duration: dur)
        }

        return ProbeResult(
            duration: duration,
            codec: codec,
            channels: channels,
            sampleRate: sampleRate,
            bitrate: bitrate.map { $0 / ($0 > 10000 ? 1000 : 1) },
            title: tags["title"],
            artist: tags["artist"],
            album: tags["album"],
            albumArtist: tags["album_artist"] ?? tags["albumartist"],
            composer: tags["composer"],
            narrator: tags["composer"] ?? tags["narrator"],
            trackNumber: parseTrack(tags["track"]),
            discNumber: parseTrack(tags["disc"]),
            year: parseYear(tags["date"] ?? tags["year"]),
            genre: tags["genre"],
            comment: tags["comment"],
            description: tags["description"] ?? tags["comment"],
            hasCover: hasCover,
            chapters: chapters,
            tags: tags
        )
    }

    private static func parseTrack(_ value: String?) -> Int? {
        guard let value else { return nil }
        let head = value.split(separator: "/").first.map(String.init) ?? value
        return Int(head.trimmingCharacters(in: .whitespaces))
    }

    private static func parseYear(_ value: String?) -> Int? {
        guard let value, value.count >= 4 else { return nil }
        return Int(value.prefix(4))
    }
}

private extension FourCharCode {
    var fourCC: String? {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
