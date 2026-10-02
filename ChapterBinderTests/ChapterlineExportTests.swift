import AppKit
import AVFoundation
import XCTest
@testable import ChapterBinder

nonisolated final class NeroChapterBoxTests: XCTestCase {
    func testVersionOneCountAtOffsetFour() throws {
        let payload = try NeroChapterBox.payload(
            chapters: [(0, "One"), (1.5, "Ümlaut"), (3, "Three")],
            fileDuration: 5
        )
        XCTAssertEqual(payload[0], 1)
        XCTAssertEqual(payload[1], 0)
        XCTAssertEqual(payload[2], 0)
        XCTAssertEqual(payload[3], 0)
        XCTAssertEqual(readUInt32(payload, 4), 3)
        let entries = NeroChapterBox.parse(payload, fileDuration: 5)
        XCTAssertEqual(entries.map(\.title), ["One", "Ümlaut", "Three"])
        XCTAssertEqual(entries[0].start, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(entries[1].start, 1.5, accuracy: 0.000_000_1)
        let ticks = readUInt64(payload, 8)
        XCTAssertEqual(ticks, 0)
        let secondTicks = readUInt64(payload, 8 + 8 + 1 + Data("One".utf8).count)
        XCTAssertEqual(secondTicks, 15_000_000)
    }

    func testTruncatesOnUTF8Boundary() {
        let long = String(repeating: "ü", count: 200)
        let truncated = NeroChapterBox.truncateTitle(long)
        let bytes = Data(truncated.utf8)
        XCTAssertLessThanOrEqual(bytes.count, 255)
        XCTAssertEqual(bytes.count, 254)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), truncated)
    }

    func testShortGapRejected() {
        XCTAssertThrowsError(
            try NeroChapterBox.payload(chapters: [(0, "A"), (0.05, "B")], fileDuration: 2)
        )
    }
}

nonisolated final class ChapterTimelineTests: XCTestCase {
    func testEmptyChapterListFailsClosed() {
        var project = BookProject(title: "Empty")
        project.tracks = [SourceTrack(path: "/tmp/a.m4a", duration: 10, codec: "aac")]
        XCTAssertThrowsError(try ChapterTimeline.marks(for: project))
    }

    func testStartOffsetShiftsTimeline() throws {
        let track = SourceTrack(path: "/tmp/a.m4a", duration: 10, codec: "aac")
        var project = BookProject(title: "Offsets")
        project.tracks = [track]
        project.chapters = [
            Chapter(title: "A", trackIDs: [track.id], startOffset: 0, endOffset: 4),
            Chapter(title: "B", trackIDs: [track.id], startOffset: 4, endOffset: nil)
        ]
        let marks = try ChapterTimeline.marks(for: project)
        XCTAssertEqual(marks.map(\.start), [0, 4])
        XCTAssertEqual(marks[1].end, 10, accuracy: 0.001)
    }

    func testGapFailsBeforeAnyFileIsWritten() {
        let track = SourceTrack(path: "/tmp/a.m4a", duration: 10, codec: "aac")
        var project = BookProject(title: "Tight")
        project.tracks = [track]
        project.chapters = [
            Chapter(title: "A", trackIDs: [track.id], endOffset: 0.04),
            Chapter(title: "B", trackIDs: [track.id], startOffset: 0.04)
        ]
        XCTAssertThrowsError(try ChapterTimeline.marks(for: project)) { error in
            XCTAssertTrue(error.localizedDescription.contains("0.1"))
        }
    }

    func testVolumePartStartsAtZero() {
        let first = SourceTrack(path: "/tmp/a.m4a", duration: 30, codec: "aac")
        let second = SourceTrack(path: "/tmp/b.m4a", duration: 30, codec: "aac")
        var project = BookProject(title: "Split")
        project.tracks = [first, second]
        project.chapters = [
            Chapter(title: "One", trackIDs: [first.id]),
            Chapter(title: "Two", trackIDs: [second.id])
        ]
        project.recomputeTimeline()
        project.splitMaxHours = 0.001
        let volumes = ExportPlanner.volumes(for: project)
        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[1].chapters.first?.start, 0)
        XCTAssertEqual(volumes[1].tracks.map(\.id), [second.id])
    }
}

nonisolated final class ProjectCompatibilityTests: XCTestCase {
    func testOldProjectJSONOpensWithoutBookmarks() throws {
        let id = UUID()
        let trackID = UUID()
        let chapterID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Old Book",
          "sortTitle": "",
          "author": "Author",
          "narrator": "",
          "description": "",
          "series": "",
          "seriesPart": "",
          "genre": "Audiobook",
          "language": "",
          "publisher": "",
          "copyright": "",
          "comment": "",
          "outputPreset": "spokenWord",
          "customBitrate": 64,
          "customChannels": 1,
          "customSampleRate": 22050,
          "outputContainer": "m4b",
          "loudnessNormalize": false,
          "stripSilence": false,
          "discs": [],
          "tracks": [{
            "id": "\(trackID.uuidString)",
            "path": "/tmp/old.m4a",
            "discIndex": 1,
            "trackIndex": 1,
            "duration": 12,
            "originalTitle": "One",
            "codec": "aac",
            "channels": 1,
            "sampleRate": 44100,
            "isRip": false,
            "ripOK": true,
            "tags": {},
            "hasEmbeddedCover": false
          }],
          "chapters": [{
            "id": "\(chapterID.uuidString)",
            "title": "One",
            "trackIDs": ["\(trackID.uuidString)"],
            "startOffset": 0,
            "start": 0,
            "duration": 12
          }],
          "sortMode": "naturalFilename",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(BookProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.title, "Old Book")
        XCTAssertNil(project.coverBookmark)
        XCTAssertNil(project.tracks[0].bookmark)
        XCTAssertEqual(project.chapters.count, 1)
    }

    func testAudibleExtensionsAreRejectedWithoutReadingAFile() {
        XCTAssertTrue(AudioFileType.isAudibleDRM(URL(fileURLWithPath: "/tmp/book.aax")))
        XCTAssertTrue(AudioFileType.isAudibleDRM(URL(fileURLWithPath: "/tmp/book.AA")))
        XCTAssertFalse(AudioFileType.isAudio(URL(fileURLWithPath: "/tmp/book.aax")))
        XCTAssertThrowsError(try ImportService.rejectDRM(in: [URL(fileURLWithPath: "/tmp/missing.aax")])) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("Audible"))
        }
    }
}

nonisolated final class ChapterStampTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chapterbinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testThreeChaptersNeroAndAVFoundation() async throws {
        let source = try await silentM4A(seconds: 3.2)
        let destination = scratch.appendingPathComponent("fixture.m4b")
        let marks = [
            ChapterTimeline.Mark(title: "One", start: 0, end: 1),
            ChapterTimeline.Mark(title: "Ümlaut", start: 1, end: 2),
            ChapterTimeline.Mark(title: "Three", start: 2, end: 3)
        ]
        try M4BChapterStamper.stamp(
            source: source,
            destination: destination,
            chapters: marks,
            tags: StampTags(title: "Fixture", artist: "Author", album: "Fixture", cover: try await tinyJPEG())
        )
        let scan = try MP4Scan.read(url: destination)
        XCTAssertEqual(scan.majorBrand.trimmingCharacters(in: .whitespaces), "M4B")
        XCTAssertTrue(scan.compatibleBrands.contains("mp42"))
        XCTAssertTrue(scan.compatibleBrands.contains("isom"))
        XCTAssertEqual(scan.stikType, 21)
        XCTAssertEqual(scan.stikValue, 2)
        XCTAssertTrue(scan.hasCover)
        XCTAssertTrue(scan.hasChapterReference)
        let report = try await ChapterlineVerifier.verify(
            url: destination,
            marks: marks,
            expectedDuration: 3,
            hadCover: true
        )
        XCTAssertEqual(report.nero, 3)
        XCTAssertEqual(report.av, 3)
        XCTAssertEqual(report.expected, 3)
        XCTAssertEqual(report.line, "3 chapters written (AV 3, Nero 3)")
    }

    func testOneChapterWritesOneChapter() async throws {
        let source = try await silentM4A(seconds: 1.6)
        let destination = scratch.appendingPathComponent("one.m4b")
        let marks = [ChapterTimeline.Mark(title: "Only", start: 0, end: 1.5)]
        try M4BChapterStamper.stamp(
            source: source,
            destination: destination,
            chapters: marks,
            tags: StampTags(title: "One", artist: "", album: "One", cover: nil)
        )
        let report = try await ChapterlineVerifier.verify(
            url: destination,
            marks: marks,
            expectedDuration: 1.5,
            hadCover: false
        )
        XCTAssertEqual(report.av, 1)
        XCTAssertEqual(report.nero, 1)
        XCTAssertEqual(report.expected, 1)
    }

    func testMissingAtomFailsClosed() async throws {
        let source = try await silentM4A(seconds: 3.2)
        let marks = [
            ChapterTimeline.Mark(title: "One", start: 0, end: 1),
            ChapterTimeline.Mark(title: "Two", start: 1, end: 2),
            ChapterTimeline.Mark(title: "Three", start: 2, end: 3)
        ]
        let tags = StampTags(title: "Fixture", artist: "A", album: "Fixture", cover: nil)
        let noNero = scratch.appendingPathComponent("no-nero.m4b")
        try M4BChapterStamper.stamp(source: source, destination: noNero, chapters: marks, tags: tags, writeNero: false)
        do {
            _ = try await ChapterlineVerifier.verify(url: noNero, marks: marks, expectedDuration: 3, hadCover: false)
            XCTFail("Missing chpl should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("chpl"))
        }
        let noQT = scratch.appendingPathComponent("no-qt.m4b")
        try M4BChapterStamper.stamp(source: source, destination: noQT, chapters: marks, tags: tags, writeQuickTime: false)
        do {
            _ = try await ChapterlineVerifier.verify(url: noQT, marks: marks, expectedDuration: 3, hadCover: false)
            XCTFail("Missing tref/chap should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tref/chap"))
        }
    }

    private func silentM4A(seconds: Double) async throws -> URL {
        let wav = scratch.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "ChapterBinderTests", code: 1)
        }
        buffer.frameLength = frames
        do {
            let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
            try audio.write(from: buffer)
        }
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        let asset = AVURLAsset(url: wav)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "ChapterBinderTests", code: 2)
        }
        session.outputURL = m4a
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            throw session.error ?? NSError(domain: "ChapterBinderTests", code: 3)
        }
        return m4a
    }
}

@MainActor
private func tinyJPEG() throws -> Data {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
        throw NSError(domain: "ChapterBinderTests", code: 4)
    }
    return jpeg
}
