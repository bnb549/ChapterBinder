import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

nonisolated enum ExportNeedsHelper: Error, Sendable {
    case filters
    case unreadable(String)
}

/// Concatenates or encodes with AVFoundation, then the caller stamps chapters.
nonisolated enum NativeExportService {
    static func exportVolume(
        project: BookProject,
        destination: URL,
        workingDirectory: URL,
        cover: Data?,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ChapterlineReport {
        let marks = try ChapterTimeline.marks(for: project)
        onProgress(ExportProgress(fraction: 0.05, message: "Preparing audio"))
        let audioURL = workingDirectory.appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }
        try await writeAudio(project: project, to: audioURL, onProgress: onProgress)
        onProgress(ExportProgress(fraction: 0.86, message: "Writing moov/udta/chpl and tref/chap"))
        let tags = StampTags(
            title: project.displayTitle,
            artist: project.author,
            album: project.displayTitle,
            cover: cover
        )
        do {
            try M4BChapterStamper.stamp(source: audioURL, destination: destination, chapters: marks, tags: tags)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        onProgress(ExportProgress(fraction: 0.95, message: "Checking moov/udta/chpl and tref/chap"))
        do {
            return try await ChapterlineVerifier.verify(
                url: destination,
                marks: marks,
                expectedDuration: marks.last?.end ?? project.totalDuration,
                hadCover: cover != nil
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func writeAudio(
        project: BookProject,
        to destination: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        if project.loudnessNormalize || project.stripSilence {
            throw ExportNeedsHelper.filters
        }
        let slices = slicePlans(project)
        guard !slices.isEmpty else {
            throw AppError.exportFailed("This book has no audio to export.")
        }
        let settings = project.encodeSettings
        if ExportPlanner.canStreamCopy(project: project, settings: settings) {
            if slices.count == 1, isMP4Container(slices[0].url) {
                onProgress(ExportProgress(fraction: 0.4, message: "Copying AAC"))
                try FileManager.default.copyItem(at: slices[0].url, to: destination)
                return
            }
            do {
                try await passthrough(slices, to: destination, onProgress: onProgress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ExportNeedsHelper {
                throw error
            } catch {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try await encode(slices, project: project, to: destination, onProgress: onProgress)
    }

    private static func slicePlans(_ project: BookProject) -> [SlicePlan] {
        ExportPlanner.slices(for: project).compactMap { slice in
            guard let track = project.track(id: slice.trackID) else { return nil }
            return SlicePlan(url: track.url, start: slice.start, end: slice.end)
        }
    }

    private static func isMP4Container(_ url: URL) -> Bool {
        ["m4a", "m4b", "mp4"].contains(url.pathExtension.lowercased())
    }

    private static func passthrough(
        _ slices: [SlicePlan],
        to destination: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        onProgress(ExportProgress(fraction: 0.2, message: "Copying AAC packets"))
        let pump = PacketPump(slices: slices, destination: destination, encode: nil)
        try await pump.run()
        onProgress(ExportProgress(fraction: 0.8, message: "Audio copied"))
    }

    private static func encode(
        _ slices: [SlicePlan],
        project: BookProject,
        to destination: URL,
        onProgress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws {
        onProgress(ExportProgress(fraction: 0.15, message: "Encoding AAC-LC"))
        let settings = project.encodeSettings
        let channels = settings.channels > 0 ? settings.channels : max(project.tracks.map(\.channels).max() ?? 1, 1)
        let rate = settings.sampleRate > 0 ? Double(settings.sampleRate) : Double(project.tracks.map(\.sampleRate).max() ?? 44100)
        var bitrate = settings.bitrateKbps
        if bitrate <= 0 {
            let fromSource = project.tracks.compactMap(\.bitrate).max() ?? 128_000
            bitrate = fromSource > 1_000 ? max(fromSource / 1000, 64) : max(fromSource, 64)
        }
        let pump = PacketPump(
            slices: slices,
            destination: destination,
            encode: EncodeSpec(bitrate: bitrate, channels: channels, sampleRate: rate)
        )
        do {
            try await pump.run()
        } catch let error as ExportNeedsHelper {
            throw error
        } catch {
            let ns = error as NSError
            if ns.domain == AVFoundationErrorDomain {
                throw ExportNeedsHelper.unreadable(ns.localizedDescription)
            }
            throw error
        }
        onProgress(ExportProgress(fraction: 0.8, message: "Encoded AAC-LC"))
    }
}

private nonisolated struct SlicePlan: Sendable {
    var url: URL
    var start: TimeInterval
    var end: TimeInterval
}

private nonisolated struct EncodeSpec: Sendable {
    var bitrate: Int
    var channels: Int
    var sampleRate: Double
}

/// Pulls compressed or PCM samples on a private queue. The class is the only
/// thing the writer callback captures, so AVFoundation types stay off the actor checker.
private nonisolated final class PacketPump: @unchecked Sendable {
    let slices: [SlicePlan]
    let destination: URL
    let encode: EncodeSpec?
    private let queue = DispatchQueue(label: "com.benmonroe.ChapterBinder.export")
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var pending: CheckedContinuation<Void, Error>?
    private var resumed = false
    private var wrote = false

    init(slices: [SlicePlan], destination: URL, encode: EncodeSpec?) {
        self.slices = slices
        self.destination = destination
        self.encode = encode
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                self.pending = continuation
                self.lock.unlock()
                self.queue.async { [self] in
                    do {
                        try self.pull()
                    } catch {
                        self.finish(error)
                    }
                }
            }
        } onCancel: { [self] in
            self.lock.lock()
            self.writer?.cancelWriting()
            self.lock.unlock()
            self.finish(CancellationError())
        }
    }

    private func pull() throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        lock.lock()
        self.writer = writer
        lock.unlock()

        if let encode {
            try pullEncoded(writer: writer, spec: encode)
        } else {
            try pullPassthrough(writer: writer)
        }
    }

    private func pullPassthrough(writer: AVAssetWriter) throws {
        guard let first = slices.first else {
            finish(AppError.exportFailed("Nothing to copy."))
            return
        }
        let asset = AVURLAsset(url: first.url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let format = track.formatDescriptions.first else {
            finish(ExportNeedsHelper.unreadable("No AAC sample description."))
            return
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format as! CMFormatDescription)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            finish(ExportNeedsHelper.unreadable("Cannot copy this AAC into an M4B."))
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            finish(writer.error ?? ExportNeedsHelper.unreadable("Could not start the AAC copy."))
            return
        }
        writer.startSession(atSourceTime: .zero)

        var sliceIndex = 0
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var cursor = CMTime.zero
        var origin = CMTime.zero
        wrote = false

        func openSlice() -> Bool {
            guard sliceIndex < slices.count else { return false }
            let slice = slices[sliceIndex]
            sliceIndex += 1
            let asset = AVURLAsset(url: slice.url)
            guard let track = asset.tracks(withMediaType: .audio).first else { return false }
            let scale = track.naturalTimeScale == 0 ? CMTimeScale(44_100) : track.naturalTimeScale
            origin = CMTime(seconds: slice.start, preferredTimescale: scale)
            let end = CMTime(seconds: slice.end, preferredTimescale: scale)
            let readerBox = try? AVAssetReader(asset: asset)
            guard let readerBox else { return false }
            readerBox.timeRange = CMTimeRange(start: origin, end: end)
            let outputBox = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            outputBox.alwaysCopiesSampleData = false
            guard readerBox.canAdd(outputBox) else { return false }
            readerBox.add(outputBox)
            guard readerBox.startReading() else { return false }
            reader = readerBox
            output = outputBox
            return true
        }

        guard openSlice() else {
            finish(ExportNeedsHelper.unreadable("Could not read AAC packets."))
            return
        }

        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                if let sample = output?.copyNextSampleBuffer() {
                    guard let retimed = Self.retime(sample, origin: origin, cursor: cursor) else { continue }
                    if !input.append(retimed) {
                        self.finish(writer.error ?? ExportNeedsHelper.unreadable("AAC copy stopped."))
                        return
                    }
                    self.wrote = true
                } else {
                    if let duration = reader?.timeRange.duration {
                        cursor = CMTimeAdd(cursor, duration)
                    }
                    reader = nil
                    output = nil
                    if !openSlice() {
                        input.markAsFinished()
                        if !self.wrote {
                            writer.cancelWriting()
                            self.finish(ExportNeedsHelper.unreadable("The AAC copy produced no samples."))
                            return
                        }
                        writer.finishWriting { [self] in
                            if writer.status == .completed {
                                self.finish(nil)
                            } else {
                                self.finish(writer.error ?? ExportNeedsHelper.unreadable("AAC copy failed."))
                            }
                        }
                        return
                    }
                }
            }
        }
    }

    private func pullEncoded(writer: AVAssetWriter, spec: EncodeSpec) throws {
        let composition = AVMutableComposition()
        guard let mix = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            finish(AppError.exportFailed("Could not build the mix."))
            return
        }
        var cursor = CMTime.zero
        let scale: CMTimeScale = 44_100
        for slice in slices {
            let asset = AVURLAsset(url: slice.url)
            guard let track = asset.tracks(withMediaType: .audio).first else {
                finish(ExportNeedsHelper.unreadable("No audio track in \(slice.url.lastPathComponent)."))
                return
            }
            let start = CMTime(seconds: slice.start, preferredTimescale: scale)
            let end = CMTime(seconds: max(slice.end, slice.start + 0.01), preferredTimescale: scale)
            let range = CMTimeRange(start: start, end: end)
            do {
                try mix.insertTimeRange(range, of: track, at: cursor)
            } catch {
                finish(ExportNeedsHelper.unreadable(error.localizedDescription))
                return
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            finish(ExportNeedsHelper.unreadable(error.localizedDescription))
            return
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: spec.channels
        ]
        let output = AVAssetReaderTrackOutput(track: mix, outputSettings: pcm)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            finish(ExportNeedsHelper.unreadable("Could not decode this audio."))
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            finish(reader.error.map { ExportNeedsHelper.unreadable($0.localizedDescription) } ?? ExportNeedsHelper.unreadable("Could not decode this audio."))
            return
        }

        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: spec.sampleRate,
            AVNumberOfChannelsKey: spec.channels,
            AVEncoderBitRateKey: spec.bitrate * 1000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            finish(ExportNeedsHelper.unreadable("AAC-LC settings were rejected."))
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            finish(writer.error ?? ExportNeedsHelper.unreadable("Could not start AAC encoding."))
            return
        }
        writer.startSession(atSourceTime: .zero)
        wrote = false
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    if !input.append(sample) {
                        self.finish(writer.error ?? AppError.exportFailed("AAC encoding stopped."))
                        return
                    }
                    self.wrote = true
                } else {
                    input.markAsFinished()
                    if reader.status == .failed {
                        writer.cancelWriting()
                        self.finish(ExportNeedsHelper.unreadable(reader.error?.localizedDescription ?? "Decode failed."))
                        return
                    }
                    if !self.wrote {
                        writer.cancelWriting()
                        self.finish(AppError.exportFailed("Encoding produced no audio."))
                        return
                    }
                    writer.finishWriting { [self] in
                        if writer.status == .completed {
                            self.finish(nil)
                        } else {
                            self.finish(writer.error ?? AppError.exportFailed("AAC encoding failed."))
                        }
                    }
                    return
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let already = resumed
        resumed = true
        let continuation = pending
        pending = nil
        lock.unlock()
        guard !already, let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private static func retime(_ sample: CMSampleBuffer, origin: CMTime, cursor: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        var shifted = CMTimeAdd(cursor, CMTimeSubtract(pts, origin))
        if shifted.isValid, cursor.isValid, CMTimeCompare(shifted, cursor) < 0 {
            shifted = cursor
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: shifted, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr else { return nil }
        return copy
    }
}
