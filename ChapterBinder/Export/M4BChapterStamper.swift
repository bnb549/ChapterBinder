import Foundation

nonisolated struct StampTags: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String
    var cover: Data?
}

/// Inserts Nero `chpl`, integer `stik` = 2, and a QuickTime text chapter track
/// after the audio file is already closed. Audio samples are not remuxed.
nonisolated enum M4BChapterStamper {
    static func stamp(
        source: URL,
        destination: URL,
        chapters: [ChapterTimeline.Mark],
        tags: StampTags,
        writeNero: Bool = true,
        writeQuickTime: Bool = true
    ) throws {
        guard !chapters.isEmpty else {
            throw AppError.exportFailed("Refusing to stamp an empty chapter list.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let top = try topLevelBoxes(handle: handle, fileSize: fileSize)
        guard let moovSpan = top.first(where: { $0.type == .moov }) else {
            throw AppError.exportFailed("Cannot stamp chapters: the audio file has no moov atom.")
        }
        let moovBytes = try read(handle, offset: moovSpan.offset, count: moovSpan.size)
        guard var moov = parseBox(moovBytes), moov.type == .moov, moov.children != nil else {
            throw AppError.exportFailed("Cannot stamp chapters: the moov atom could not be patched.")
        }

        let movie = movieHeader(in: moov)
        guard movie.timescale > 0, movie.duration > 0 else {
            throw AppError.exportFailed("Cannot stamp chapters: the audio file has no duration.")
        }
        let seconds = Double(movie.duration) / Double(movie.timescale)
        for (index, chapter) in chapters.enumerated() where chapter.start > seconds + 1 {
            throw AppError.exportFailed(
                "Chapter \(index + 1) starts after the audio. Export stopped instead of writing a short chapter list."
            )
        }

        stripChpl(&moov)
        removeTextTracks(&moov)
        upsertMetadata(&moov, tags: tags, chpl: writeNero ? try neroPayload(chapters, seconds: seconds) : nil)

        var placeholder = false
        if writeQuickTime {
            let trackID = nextTrackID(in: moov)
            let chapterTrack = try chapterTrack(id: trackID, chapters: chapters, movie: movie)
            insertTrack(chapterTrack, into: &moov)
            guard pointAudioTracks(in: &moov, at: trackID) else {
                throw AppError.exportFailed("Cannot stamp chapters: no audio track to attach tref/chap.")
            }
            updateNextTrackID(&moov, next: trackID &+ 1)
            placeholder = true
        }

        var ftypReplacement: Data?
        var ftypSpan: BoxSpan?
        if let ftyp = top.first(where: { $0.type == .ftyp }) {
            let bytes = try read(handle, offset: ftyp.offset, count: ftyp.size)
            ftypReplacement = rewriteFtyp(bytes)
            ftypSpan = ftyp
        } else {
            ftypReplacement = freshFtyp()
        }

        let serialized = serialize(moov)
        let ftypDelta = Int64(ftypReplacement?.count ?? 0) - Int64(ftypSpan?.size ?? 0)
        let moovDelta = Int64(serialized.count) - Int64(moovSpan.size)
        let sampleOffset = fileSize + UInt64(clamping: max(0, ftypDelta + moovDelta)) + 8
        // fileSize + deltas can be computed with signed math when deltas are negative.
        let signedEnd = Int64(fileSize) + ftypDelta + moovDelta
        guard signedEnd >= 0 else {
            throw AppError.exportFailed("Cannot stamp chapters: the moov atom shrank past the start of the file.")
        }
        let resolvedSample = UInt64(signedEnd) + 8
        _ = sampleOffset

        let ftypEnd = ftypSpan.map { $0.offset + $0.size }
        let moovEnd = moovSpan.offset + moovSpan.size
        let patched = try patchChunkOffsets(
            in: serialized,
            placeholder: placeholder,
            sampleOffset: resolvedSample
        ) { old in
            var shifted = Int64(old)
            if let ftypEnd, old >= ftypEnd {
                shifted += ftypDelta
            }
            if old >= moovEnd {
                shifted += moovDelta
            }
            guard shifted > 0 else { return old }
            return UInt64(shifted)
        }

        let output = try outputURL(for: destination, source: source)
        try writeCopy(
            handle: handle,
            fileSize: fileSize,
            top: top,
            ftypSpan: ftypSpan,
            ftyp: ftypReplacement,
            moovSpan: moovSpan,
            moov: patched,
            chapterSamples: placeholder ? sampleBlob(chapters) : nil,
            to: output
        )
        try? handle.close()
        if output != destination {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: output)
            } else {
                try FileManager.default.moveItem(at: output, to: destination)
            }
        }
    }

    // MARK: - Chapter track

    private static func neroPayload(_ chapters: [ChapterTimeline.Mark], seconds: TimeInterval) throws -> Data {
        try NeroChapterBox.payload(
            chapters: chapters.map { ($0.start, $0.title) },
            fileDuration: seconds
        )
    }

    private static func chapterTrack(id: UInt32, chapters: [ChapterTimeline.Mark], movie: MovieHeader) throws -> MP4Box {
        let seconds = Double(movie.duration) / Double(movie.timescale)
        let scale: UInt32 = 1_000
        let mediaDuration = max(UInt64((seconds * Double(scale)).rounded()), 1)
        var starts: [UInt64] = []
        for (index, chapter) in chapters.enumerated() {
            let tick = index == 0 ? 0 : UInt64((chapter.start * Double(scale)).rounded())
            if let last = starts.last, tick <= last {
                throw AppError.exportFailed("Chapter \(index + 1) is not strictly after the previous chapter on the QuickTime clock.")
            }
            if tick >= mediaDuration {
                throw AppError.exportFailed("Chapter \(index + 1) starts at or after the end of the audio.")
            }
            starts.append(tick)
        }
        var deltas: [UInt32] = []
        for index in starts.indices {
            let next = index + 1 < starts.count ? starts[index + 1] : mediaDuration
            let delta = next - starts[index]
            guard delta >= 1, delta <= UInt64(UInt32.max) else {
                throw AppError.exportFailed("Chapter \(index + 1) is too long to store in a QuickTime text sample.")
            }
            deltas.append(UInt32(delta))
        }

        let samples = chapters.map { sample($0.title) }
        let tkhdBox = tkhd(trackID: id, movieDuration: movie.duration, movieTimescaleFits32: movie.duration <= UInt64(UInt32.max))
        let mdhdBox = mdhd(timescale: scale, duration: mediaDuration)
        let minf = container(.minf, [
            gmhdBox(),
            container(.dinf, [drefBox()]),
            container(.stbl, [
                stsdBox(),
                sttsBox(deltas),
                stscBox(sampleCount: UInt32(samples.count)),
                stszBox(samples.map { UInt32($0.count) }),
                stcoBox()
            ])
        ])
        let mdia = container(.mdia, [mdhdBox, textHandler(), minf])
        return container(.trak, [tkhdBox, mdia])
    }

    private static func sample(_ title: String) -> Data {
        let text = NeroChapterBox.truncateTitle(title)
        let utf = Data(text.utf8)
        var data = Data()
        appendUInt16(UInt16(min(utf.count, Int(UInt16.max))), to: &data)
        data.append(utf.prefix(Int(UInt16.max)))
        data.append(contentsOf: [
            0x00, 0x00, 0x00, 0x0C,
            0x65, 0x6E, 0x63, 0x64,
            0x00, 0x00, 0x01, 0x00
        ])
        return data
    }

    private static func sampleBlob(_ chapters: [ChapterTimeline.Mark]) -> Data {
        var data = Data()
        for chapter in chapters {
            data.append(sample(chapter.title))
        }
        return data
    }

    // MARK: - Metadata

    private static func upsertMetadata(_ moov: inout MP4Box, tags: StampTags, chpl: Data?) {
        var children = moov.children ?? []
        if let index = children.firstIndex(where: { $0.type == .udta }) {
            var udta = children[index]
            ensureIlst(&udta, tags: tags)
            if let chpl {
                var udtaChildren = udta.children ?? []
                udtaChildren.append(leaf(.chpl, chpl))
                udta.children = udtaChildren
            }
            children[index] = udta
        } else {
            var udta = container(.udta, [])
            ensureIlst(&udta, tags: tags)
            if let chpl {
                udta.children?.append(leaf(.chpl, chpl))
            }
            children.append(udta)
        }
        moov.children = children
    }

    private static func ensureIlst(_ udta: inout MP4Box, tags: StampTags) {
        var children = udta.children ?? []
        let metaIndex = children.firstIndex(where: { $0.type == .meta })
        var meta: MP4Box
        if let metaIndex, children[metaIndex].children != nil {
            meta = children[metaIndex]
        } else {
            meta = container(.meta, prefix: Data([0, 0, 0, 0]), [itunesHandler(), container(.ilst, [])])
        }
        var metaChildren = meta.children ?? []
        if metaChildren.contains(where: { $0.type == .hdlr }) == false {
            metaChildren.insert(itunesHandler(), at: 0)
        }
        let ilstIndex = metaChildren.firstIndex(where: { $0.type == .ilst })
        var ilst = ilstIndex.map { metaChildren[$0] } ?? container(.ilst, [])
        var items = ilst.children ?? []
        upsert(&items, ilstItem(.stik, integerData(type: 21, value: 2)))
        if !tags.title.isEmpty { upsert(&items, ilstItem(.name, utf8Data(tags.title))) }
        if !tags.artist.isEmpty {
            upsert(&items, ilstItem(.artist, utf8Data(tags.artist)))
            upsert(&items, ilstItem(.albumArtist, utf8Data(tags.artist)))
        }
        if !tags.album.isEmpty { upsert(&items, ilstItem(.album, utf8Data(tags.album))) }
        if let cover = tags.cover, !cover.isEmpty {
            upsert(&items, ilstItem(.covr, imageData(cover)))
        }
        ilst.children = items
        if let ilstIndex {
            metaChildren[ilstIndex] = ilst
        } else {
            metaChildren.append(ilst)
        }
        meta.children = metaChildren
        if let metaIndex {
            children[metaIndex] = meta
        } else {
            children.insert(meta, at: 0)
        }
        udta.children = children
    }

    private static func upsert(_ items: inout [MP4Box], _ item: MP4Box) {
        if let index = items.firstIndex(where: { $0.type == item.type }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private static func ilstItem(_ type: FourCC, _ dataPayload: Data) -> MP4Box {
        container(type, [leaf(.dataAtom, dataPayload)])
    }

    private static func integerData(type: UInt32, value: UInt32) -> Data {
        var data = Data()
        appendUInt32(type, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(value, to: &data)
        return data
    }

    private static func utf8Data(_ string: String) -> Data {
        var data = Data()
        appendUInt32(1, to: &data)
        appendUInt32(0, to: &data)
        data.append(contentsOf: Data(string.utf8))
        return data
    }

    private static func imageData(_ cover: Data) -> Data {
        let jpeg = cover.starts(with: [0xFF, 0xD8, 0xFF])
        let png = cover.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let type: UInt32 = png && !jpeg ? 14 : 13
        var data = Data()
        appendUInt32(type, to: &data)
        appendUInt32(0, to: &data)
        data.append(cover)
        return data
    }

    // MARK: - Track graph

    private static func stripChpl(_ box: inout MP4Box) {
        guard var children = box.children else { return }
        children.removeAll { $0.type == .chpl }
        for index in children.indices {
            stripChpl(&children[index])
        }
        box.children = children
    }

    private static func removeTextTracks(_ moov: inout MP4Box) {
        moov.children?.removeAll { trak in
            trak.type == .trak && handlerType(of: trak) == .text
        }
    }

    private static func insertTrack(_ trak: MP4Box, into moov: inout MP4Box) {
        var children = moov.children ?? []
        if let udta = children.lastIndex(where: { $0.type == .udta }) {
            children.insert(trak, at: udta)
        } else {
            children.append(trak)
        }
        moov.children = children
    }

    @discardableResult
    private static func pointAudioTracks(in moov: inout MP4Box, at chapterTrackID: UInt32) -> Bool {
        guard var children = moov.children else { return false }
        var found = false
        for index in children.indices where children[index].type == .trak && handlerType(of: children[index]) == .soun {
            addChapterReference(to: &children[index], chapterTrackID: chapterTrackID)
            found = true
        }
        moov.children = children
        return found
    }

    private static func addChapterReference(to trak: inout MP4Box, chapterTrackID: UInt32) {
        var children = trak.children ?? []
        let chap = leaf(.chap, {
            var data = Data()
            appendUInt32(chapterTrackID, to: &data)
            return data
        }())
        if let trefIndex = children.firstIndex(where: { $0.type == .tref }), children[trefIndex].children != nil {
            var tref = children[trefIndex]
            var refs = tref.children ?? []
            refs.removeAll { $0.type == .chap }
            refs.append(chap)
            tref.children = refs
            children[trefIndex] = tref
        } else {
            let tref = container(.tref, [chap])
            if let mdia = children.firstIndex(where: { $0.type == .mdia }) {
                children.insert(tref, at: mdia)
            } else {
                children.append(tref)
            }
        }
        trak.children = children
    }

    private static func handlerType(of trak: MP4Box) -> FourCC? {
        guard let mdia = trak.children?.first(where: { $0.type == .mdia }),
              let hdlr = mdia.children?.first(where: { $0.type == .hdlr }) else { return nil }
        let payload = hdlr.leaf
        guard payload.count >= 12 else { return nil }
        return FourCC(payload[8], payload[9], payload[10], payload[11])
    }

    private static func nextTrackID(in moov: MP4Box) -> UInt32 {
        var maxID: UInt32 = 0
        for trak in moov.children ?? [] where trak.type == .trak {
            if let id = trackID(of: trak) {
                maxID = max(maxID, id)
            }
        }
        return maxID &+ 1
    }

    private static func trackID(of trak: MP4Box) -> UInt32? {
        guard let tkhd = trak.children?.first(where: { $0.type == .tkhd }) else { return nil }
        let payload = tkhd.leaf
        guard !payload.isEmpty else { return nil }
        let offset = payload[0] == 1 ? 20 : 12
        return readUInt32(payload, offset)
    }

    private static func updateNextTrackID(_ moov: inout MP4Box, next: UInt32) {
        guard var children = moov.children,
              let index = children.firstIndex(where: { $0.type == .mvhd }) else { return }
        var mvhd = children[index]
        var payload = mvhd.leaf
        guard !payload.isEmpty else { return }
        let offset = payload[0] == 1 ? 108 : 96
        guard payload.count >= offset + 4 else { return }
        let current = readUInt32(payload, offset) ?? 0
        if next > current {
            writeUInt32(next, into: &payload, at: offset)
            mvhd.leaf = payload
            children[index] = mvhd
            moov.children = children
        }
    }

    private static func movieHeader(in moov: MP4Box) -> MovieHeader {
        guard let mvhd = moov.children?.first(where: { $0.type == .mvhd }) else {
            return MovieHeader(timescale: 0, duration: 0)
        }
        let payload = mvhd.leaf
        guard !payload.isEmpty else { return MovieHeader(timescale: 0, duration: 0) }
        if payload[0] == 1 {
            let scale = readUInt32(payload, 20) ?? 0
            let duration = readUInt64(payload, 24)
            return MovieHeader(timescale: scale, duration: duration)
        }
        let scale = readUInt32(payload, 12) ?? 0
        let duration = UInt64(readUInt32(payload, 16) ?? 0)
        return MovieHeader(timescale: scale, duration: duration)
    }

    // MARK: - QuickTime boxes

    private static func tkhd(trackID: UInt32, movieDuration: UInt64, movieTimescaleFits32: Bool) -> MP4Box {
        var payload = Data()
        if movieTimescaleFits32 && movieDuration <= UInt64(UInt32.max) {
            payload.append(0)
            payload.append(contentsOf: [0, 0, 1])
            appendUInt32(0, to: &payload)
            appendUInt32(0, to: &payload)
            appendUInt32(trackID, to: &payload)
            appendUInt32(0, to: &payload)
            appendUInt32(UInt32(movieDuration), to: &payload)
        } else {
            payload.append(1)
            payload.append(contentsOf: [0, 0, 1])
            appendUInt64(0, to: &payload)
            appendUInt64(0, to: &payload)
            appendUInt32(trackID, to: &payload)
            appendUInt32(0, to: &payload)
            appendUInt64(movieDuration, to: &payload)
        }
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        appendUInt16(0, to: &payload) // layer
        appendUInt16(0, to: &payload) // alternate group
        appendUInt16(0, to: &payload) // volume
        appendUInt16(0, to: &payload)
        appendMatrix(&payload)
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        return leaf(.tkhd, payload)
    }

    private static func mdhd(timescale: UInt32, duration: UInt64) -> MP4Box {
        var payload = Data()
        if duration <= UInt64(UInt32.max) {
            payload.append(0)
            payload.append(contentsOf: [0, 0, 0])
            appendUInt32(0, to: &payload)
            appendUInt32(0, to: &payload)
            appendUInt32(timescale, to: &payload)
            appendUInt32(UInt32(duration), to: &payload)
        } else {
            payload.append(1)
            payload.append(contentsOf: [0, 0, 0])
            appendUInt64(0, to: &payload)
            appendUInt64(0, to: &payload)
            appendUInt32(timescale, to: &payload)
            appendUInt64(duration, to: &payload)
        }
        appendUInt16(0x55C4, to: &payload)
        appendUInt16(0, to: &payload)
        return leaf(.mdhd, payload)
    }

    private static func textHandler() -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        payload.append(FourCC.text.data)
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        payload.append(contentsOf: Data("Chapter Handler".utf8))
        payload.append(0)
        return leaf(.hdlr, payload)
    }

    private static func itunesHandler() -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        payload.append(FourCC(ascii: "mdir").data)
        payload.append(FourCC(ascii: "appl").data)
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        payload.append(0)
        return leaf(.hdlr, payload)
    }

    private static func gmhdBox() -> MP4Box {
        var gmin = Data()
        appendUInt32(0, to: &gmin)
        appendUInt16(0x40, to: &gmin)
        appendUInt16(0x8000, to: &gmin)
        appendUInt16(0x8000, to: &gmin)
        appendUInt16(0x8000, to: &gmin)
        appendUInt16(0, to: &gmin)
        appendUInt16(0, to: &gmin)
        let text = Data([
            0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x40, 0x00,
            0x00, 0x00
        ])
        return container(.gmhd, [leaf(.gmin, gmin), leaf(.text, text)])
    }

    private static func drefBox() -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(1, to: &payload)
        appendUInt32(12, to: &payload)
        payload.append(FourCC(ascii: "url ").data)
        appendUInt32(1, to: &payload)
        return leaf(.dref, payload)
    }

    private static func stsdBox() -> MP4Box {
        let stub: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x0D,
            0x66, 0x74, 0x61, 0x62,
            0x00, 0x01,
            0x00, 0x01,
            0x00
        ]
        var entry = Data()
        appendUInt32(UInt32(16 + stub.count), to: &entry)
        entry.append(FourCC.text.data)
        entry.append(contentsOf: [0, 0, 0, 0, 0, 0])
        appendUInt16(1, to: &entry)
        entry.append(contentsOf: stub)
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(1, to: &payload)
        payload.append(entry)
        return leaf(.stsd, payload)
    }

    private static func sttsBox(_ deltas: [UInt32]) -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(UInt32(deltas.count), to: &payload)
        for delta in deltas {
            appendUInt32(1, to: &payload)
            appendUInt32(delta, to: &payload)
        }
        return leaf(.stts, payload)
    }

    private static func stscBox(sampleCount: UInt32) -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(1, to: &payload)
        appendUInt32(1, to: &payload)
        appendUInt32(sampleCount, to: &payload)
        appendUInt32(1, to: &payload)
        return leaf(.stsc, payload)
    }

    private static func stszBox(_ sizes: [UInt32]) -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(0, to: &payload)
        appendUInt32(UInt32(sizes.count), to: &payload)
        for size in sizes {
            appendUInt32(size, to: &payload)
        }
        return leaf(.stsz, payload)
    }

    private static func stcoBox() -> MP4Box {
        var payload = Data()
        appendUInt32(0, to: &payload)
        appendUInt32(1, to: &payload)
        appendUInt32(0, to: &payload)
        return leaf(.stco, payload)
    }

    private static func appendMatrix(_ data: inout Data) {
        let values: [UInt32] = [
            0x00010000, 0, 0,
            0, 0x00010000, 0,
            0, 0, 0x40000000
        ]
        for value in values {
            appendUInt32(value, to: &data)
        }
    }

    // MARK: - ftyp

    private static func rewriteFtyp(_ box: Data) -> Data {
        guard box.count >= 16 else { return freshFtyp() }
        let header = box.prefix(8)
        let size32 = readUInt32(Data(header), 0) ?? 0
        let payloadStart = size32 == 1 ? 16 : 8
        guard box.count >= payloadStart + 8 else { return freshFtyp() }
        let payload = box.dropFirst(payloadStart)
        let minor = payload.dropFirst(4).prefix(4)
        var compatible: [FourCC] = []
        var offset = 8
        while offset + 4 <= payload.count {
            let bytes = payload.dropFirst(offset).prefix(4)
            compatible.append(FourCC(bytes[bytes.startIndex], bytes[bytes.startIndex + 1], bytes[bytes.startIndex + 2], bytes[bytes.startIndex + 3]))
            offset += 4
        }
        for required in [FourCC.mp42, FourCC.isom, FourCC.m4b] where !compatible.contains(required) {
            compatible.insert(required, at: 0)
        }
        var body = Data()
        body.append(FourCC.m4b.data)
        body.append(minor)
        for brand in compatible {
            body.append(brand.data)
        }
        return encodeBox(.ftyp, body)
    }

    private static func freshFtyp() -> Data {
        var body = Data()
        body.append(FourCC.m4b.data)
        appendUInt32(0, to: &body)
        body.append(FourCC.m4b.data)
        body.append(FourCC.mp42.data)
        body.append(FourCC.isom.data)
        return encodeBox(.ftyp, body)
    }

    // MARK: - Offset patch

    private static func patchChunkOffsets(
        in moov: Data,
        placeholder: Bool,
        sampleOffset: UInt64,
        shift: (UInt64) -> UInt64
    ) throws -> Data {
        var copy = moov
        var entries: [(offset: Int, width: Int)] = []
        collectChunkEntries(in: &copy, boxStart: 0, boxEnd: copy.count, into: &entries, recurse: true)
        guard !entries.isEmpty || !placeholder else {
            throw AppError.exportFailed("Cannot stamp chapters: the QuickTime chapter track has no sample offset.")
        }
        let placeholderIndex = placeholder ? entries.count - 1 : nil
        for (index, entry) in entries.enumerated() {
            let old: UInt64
            if entry.width == 8 {
                old = readUInt64(copy, entry.offset)
            } else {
                old = UInt64(readUInt32(copy, entry.offset) ?? 0)
            }
            let new = index == placeholderIndex ? sampleOffset : shift(old)
            if entry.width == 8 {
                writeUInt64(new, into: &copy, at: entry.offset)
            } else if new > UInt64(UInt32.max) {
                throw AppError.exportFailed("Cannot stamp chapters: a chunk offset no longer fits in 32 bits. Split the book and export again.")
            } else {
                writeUInt32(UInt32(new), into: &copy, at: entry.offset)
            }
        }
        return copy
    }

    private static func collectChunkEntries(
        in data: inout Data,
        boxStart: Int,
        boxEnd: Int,
        into entries: inout [(offset: Int, width: Int)],
        recurse: Bool
    ) {
        guard boxEnd >= boxStart + 8, boxEnd <= data.count else { return }
        let header = headerLength(data, boxStart, boxEnd)
        guard let header else { return }
        let type = fourCC(data, boxStart + 4)
        let payload = boxStart + header
        if type == .stco || type == .co64 {
            guard payload + 8 <= boxEnd else { return }
            let count = Int(readUInt32(data, payload + 4) ?? 0)
            let width = type == .co64 ? 8 : 4
            var cursor = payload + 8
            for _ in 0..<count {
                guard cursor + width <= boxEnd else { return }
                entries.append((cursor, width))
                cursor += width
            }
            return
        }
        guard recurse, containers.contains(type) else { return }
        var cursor = payload + (type == .meta ? 4 : 0)
        while cursor + 8 <= boxEnd {
            guard headerLength(data, cursor, boxEnd) != nil,
                  let childSize = boxSize(data, cursor, limit: boxEnd) else { return }
            let childEnd = cursor + childSize
            guard childEnd > cursor, childEnd <= boxEnd else { return }
            collectChunkEntries(in: &data, boxStart: cursor, boxEnd: childEnd, into: &entries, recurse: true)
            cursor = childEnd
        }
    }

    // MARK: - File rewrite

    private static func writeCopy(
        handle: FileHandle,
        fileSize: UInt64,
        top: [BoxSpan],
        ftypSpan: BoxSpan?,
        ftyp: Data?,
        moovSpan: BoxSpan,
        moov: Data,
        chapterSamples: Data?,
        to url: URL
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }

        var pieces: [(range: Range<UInt64>?, data: Data?)] = []
        var replacements: [(BoxSpan, Data)] = [(moovSpan, moov)]
        if let ftypSpan, let ftyp {
            replacements.append((ftypSpan, ftyp))
        } else if let ftyp, ftypSpan == nil {
            pieces.append((nil, ftyp))
        }
        replacements.sort { $0.0.offset < $1.0.offset }
        var cursor: UInt64 = 0
        for (span, data) in replacements {
            if span.offset > cursor {
                pieces.append((cursor..<span.offset, nil))
            }
            pieces.append((nil, data))
            cursor = span.offset + span.size
        }
        if cursor < fileSize {
            pieces.append((cursor..<fileSize, nil))
        }
        if let chapterSamples {
            var mdat = Data()
            let total = UInt64(8 + chapterSamples.count)
            if total > UInt64(UInt32.max) {
                appendUInt32(1, to: &mdat)
                mdat.append(FourCC(ascii: "mdat").data)
                appendUInt64(16 + UInt64(chapterSamples.count), to: &mdat)
            } else {
                appendUInt32(UInt32(total), to: &mdat)
                mdat.append(FourCC(ascii: "mdat").data)
            }
            mdat.append(chapterSamples)
            pieces.append((nil, mdat))
        }
        _ = top

        for piece in pieces {
            if let data = piece.data {
                try output.write(contentsOf: data)
            } else if let range = piece.range {
                try copy(handle: handle, range: range, to: output)
            }
        }
    }

    private static func copy(handle: FileHandle, range: Range<UInt64>, to output: FileHandle) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let count = Int(min(UInt64(1_048_576), range.upperBound - cursor))
            try handle.seek(toOffset: cursor)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            cursor += UInt64(chunk.count)
        }
    }

    private static func outputURL(for destination: URL, source: URL) throws -> URL {
        if source.standardizedFileURL != destination.standardizedFileURL {
            return destination
        }
        let url = destination.deletingLastPathComponent()
            .appendingPathComponent(".__chapterbinder_stamp_\(UUID().uuidString).m4b")
        return url
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        let length = Int(min(count, UInt64(Int.max)))
        guard let data = try handle.read(upToCount: length), UInt64(data.count) == count else {
            throw AppError.exportFailed("Cannot stamp chapters: the audio file ended inside the moov atom.")
        }
        return data
    }
}

private nonisolated struct MovieHeader {
    var timescale: UInt32
    var duration: UInt64
}

private nonisolated struct BoxSpan {
    var offset: UInt64
    var size: UInt64
    var type: FourCC
}

private nonisolated struct MP4Box {
    var type: FourCC
    var headerPrefix: Data
    var children: [MP4Box]?
    var leaf: Data
    var suffix: Data
}

private nonisolated struct FourCC: Hashable, Sendable {
    var b0, b1, b2, b3: UInt8

    init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.b3 = b3
    }

    init(ascii: String) {
        let bytes = Array(ascii.utf8)
        precondition(bytes.count == 4, "FourCC must be 4 bytes")
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    var data: Data { Data([b0, b1, b2, b3]) }

    static let moov = FourCC(ascii: "moov")
    static let trak = FourCC(ascii: "trak")
    static let mdia = FourCC(ascii: "mdia")
    static let minf = FourCC(ascii: "minf")
    static let stbl = FourCC(ascii: "stbl")
    static let dinf = FourCC(ascii: "dinf")
    static let udta = FourCC(ascii: "udta")
    static let edts = FourCC(ascii: "edts")
    static let tref = FourCC(ascii: "tref")
    static let meta = FourCC(ascii: "meta")
    static let ilst = FourCC(ascii: "ilst")
    static let mvhd = FourCC(ascii: "mvhd")
    static let tkhd = FourCC(ascii: "tkhd")
    static let mdhd = FourCC(ascii: "mdhd")
    static let hdlr = FourCC(ascii: "hdlr")
    static let chpl = FourCC(ascii: "chpl")
    static let chap = FourCC(ascii: "chap")
    static let stco = FourCC(ascii: "stco")
    static let co64 = FourCC(ascii: "co64")
    static let ftyp = FourCC(ascii: "ftyp")
    static let stik = FourCC(ascii: "stik")
    static let dataAtom = FourCC(ascii: "data")
    static let covr = FourCC(ascii: "covr")
    static let stsd = FourCC(ascii: "stsd")
    static let stts = FourCC(ascii: "stts")
    static let stsc = FourCC(ascii: "stsc")
    static let stsz = FourCC(ascii: "stsz")
    static let dref = FourCC(ascii: "dref")
    static let gmhd = FourCC(ascii: "gmhd")
    static let gmin = FourCC(ascii: "gmin")
    static let text = FourCC(ascii: "text")
    static let soun = FourCC(ascii: "soun")
    static let m4b = FourCC(0x4D, 0x34, 0x42, 0x20)
    static let mp42 = FourCC(ascii: "mp42")
    static let isom = FourCC(ascii: "isom")
    static let name = FourCC(0xA9, 0x6E, 0x61, 0x6D)
    static let artist = FourCC(0xA9, 0x41, 0x52, 0x54)
    static let album = FourCC(0xA9, 0x61, 0x6C, 0x62)
    static let albumArtist = FourCC(0x61, 0x41, 0x52, 0x54)
}

private nonisolated let containers: Set<FourCC> = [
    .moov, .trak, .mdia, .minf, .stbl, .dinf, .udta, .edts, .tref, .meta, .ilst, .gmhd
]

private nonisolated func leaf(_ type: FourCC, _ payload: Data) -> MP4Box {
    MP4Box(type: type, headerPrefix: Data(), children: nil, leaf: payload, suffix: Data())
}

private nonisolated func container(_ type: FourCC, prefix: Data = Data(), _ children: [MP4Box]) -> MP4Box {
    MP4Box(type: type, headerPrefix: prefix, children: children, leaf: Data(), suffix: Data())
}

private nonisolated func encodeBox(_ type: FourCC, _ payload: Data) -> Data {
    var data = Data()
    appendUInt32(UInt32(8 + payload.count), to: &data)
    data.append(type.data)
    data.append(payload)
    return data
}

private nonisolated func serialize(_ box: MP4Box) -> Data {
    let body: Data
    if let children = box.children {
        var payload = box.headerPrefix
        for child in children {
            payload.append(serialize(child))
        }
        payload.append(box.suffix)
        body = payload
    } else {
        body = box.leaf
    }
    return encodeBox(box.type, body)
}

private nonisolated func topLevelBoxes(handle: FileHandle, fileSize: UInt64) throws -> [BoxSpan] {
    var boxes: [BoxSpan] = []
    var offset: UInt64 = 0
    while offset + 8 <= fileSize {
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
        let size32 = readUInt32(header, 0) ?? 0
        let type = FourCC(header[4], header[5], header[6], header[7])
        var size = UInt64(size32)
        var headerLength: UInt64 = 8
        if size32 == 1 {
            guard header.count >= 16 else { break }
            size = readUInt64(header, 8)
            headerLength = 16
        } else if size32 == 0 {
            size = fileSize - offset
        }
        guard size >= headerLength, offset <= UInt64.max - size else { break }
        boxes.append(BoxSpan(offset: offset, size: size, type: type))
        let next = offset + size
        if next <= offset { break }
        offset = next
    }
    return boxes
}

private nonisolated func parseBox(_ data: Data) -> MP4Box? {
    guard data.count >= 8, let size = boxSize(data, 0, limit: data.count), size == data.count else { return nil }
    let header = headerLength(data, 0, data.count) ?? 8
    let type = fourCC(data, 4)
    let payload = Data(data.dropFirst(header))
    if containers.contains(type) {
        let prefixLength = type == .meta ? 4 : 0
        if payload.count >= prefixLength {
            let prefix = Data(payload.prefix(prefixLength))
            let rest = Data(payload.dropFirst(prefixLength))
            if let children = parseChildren(rest) {
                return MP4Box(type: type, headerPrefix: prefix, children: children, leaf: Data(), suffix: Data())
            }
        }
    }
    return leaf(type, payload)
}

private nonisolated func parseChildren(_ data: Data) -> [MP4Box]? {
    var boxes: [MP4Box] = []
    var offset = 0
    while offset + 8 <= data.count {
        guard let size = boxSize(data, offset, limit: data.count), size >= 8 else { return nil }
        let end = offset + size
        guard end > offset, end <= data.count else { return nil }
        let slice = Data(data[offset..<end])
        guard let box = parseBox(slice) else { return nil }
        boxes.append(box)
        offset = end
    }
    guard offset == data.count else { return nil }
    return boxes
}

private nonisolated func headerLength(_ data: Data, _ start: Int, _ limit: Int) -> Int? {
    guard start + 8 <= limit, let size32 = readUInt32(data, start) else { return nil }
    if size32 == 1 {
        return start + 16 <= limit ? 16 : nil
    }
    return 8
}

private nonisolated func boxSize(_ data: Data, _ start: Int, limit: Int) -> Int? {
    guard start + 8 <= limit, let size32 = readUInt32(data, start) else { return nil }
    if size32 == 1 {
        guard start + 16 <= limit else { return nil }
        let size = readUInt64(data, start + 8)
        guard size <= UInt64(Int.max) else { return nil }
        return Int(size)
    }
    if size32 == 0 {
        return limit - start
    }
    return Int(size32)
}

private nonisolated func fourCC(_ data: Data, _ offset: Int) -> FourCC {
    guard offset + 4 <= data.count else { return FourCC(0, 0, 0, 0) }
    return FourCC(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

private nonisolated func appendUInt16(_ value: UInt16, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

private nonisolated func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { raw in
        data.replaceSubrange(offset..<(offset + 4), with: raw)
    }
}

private nonisolated func writeUInt64(_ value: UInt64, into data: inout Data, at offset: Int) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { raw in
        data.replaceSubrange(offset..<(offset + 8), with: raw)
    }
}
