import Foundation

struct SilenceBreak: Identifiable, Sendable, Hashable {
    var id: UUID
    var time: TimeInterval
    var duration: TimeInterval

    init(id: UUID = UUID(), time: TimeInterval, duration: TimeInterval) {
        self.id = id
        self.time = time
        self.duration = duration
    }
}

enum SilenceDetection {
    static func detect(
        url: URL,
        noiseDB: Double = -30,
        minDuration: Double = 1.4
    ) async throws -> [SilenceBreak] {
        let ffmpeg = try HelperBinary.ffmpeg.url()
        let args = [
            "-hide_banner",
            "-i", url.path,
            "-af", "silencedetect=noise=\(noiseDB)dB:d=\(minDuration)",
            "-f", "null",
            "-",
        ]
        let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        return parse(result.stderr + "\n" + result.stdout, minDuration: minDuration)
    }

    static func parse(_ log: String, minDuration: Double = 1.4) -> [SilenceBreak] {
        let startPattern = #"silence_start:\s*([0-9.]+)"#
        let endPattern = #"silence_end:\s*([0-9.]+)\s*\|\s*silence_duration:\s*([0-9.]+)"#
        let startRegex = try? NSRegularExpression(pattern: startPattern)
        let endRegex = try? NSRegularExpression(pattern: endPattern)
        var starts: [TimeInterval] = []
        var breaks: [SilenceBreak] = []
        let ns = log as NSString
        let range = NSRange(location: 0, length: ns.length)
        startRegex?.enumerateMatches(in: log, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: log), let v = Double(log[r]) else { return }
            starts.append(v)
        }
        endRegex?.enumerateMatches(in: log, range: range) { match, _, _ in
            guard let match,
                  let r1 = Range(match.range(at: 1), in: log),
                  let r2 = Range(match.range(at: 2), in: log),
                  let end = Double(log[r1]),
                  let dur = Double(log[r2])
            else { return }
            let start = end - dur
            breaks.append(SilenceBreak(time: start + dur / 2, duration: dur))
        }
        if breaks.isEmpty {
            breaks = starts.map { SilenceBreak(time: $0, duration: minDuration) }
        }
        return breaks
    }

    static func snap(time: TimeInterval, to breaks: [SilenceBreak], window: TimeInterval = 2.5) -> TimeInterval {
        guard let nearest = breaks.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return time }
        if abs(nearest.time - time) <= window {
            return nearest.time
        }
        return time
    }
}
