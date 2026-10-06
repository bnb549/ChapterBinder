import Foundation

extension BookProject {
    /// Each file starts as its own chapter. Call after import or sort.
    mutating func rebuildOneChapterPerTrack() {
        chapters = tracks.enumerated().map { index, track in
            Chapter(
                title: track.suggestedChapterTitle,
                trackIDs: [track.id],
                startOffset: 0,
                endOffset: nil
            )
        }
        recomputeTimeline()
    }

    mutating func applySortMode() {
        switch sortMode {
        case .naturalFilename:
            tracks = NaturalSort.sorted(tracks) { $0.path }
        case .embeddedTrack:
            tracks.sort { a, b in
                if a.discIndex != b.discIndex { return a.discIndex < b.discIndex }
                let an = a.embeddedTrackNumber ?? a.trackIndex
                let bn = b.embeddedTrackNumber ?? b.trackIndex
                if an != bn { return an < bn }
                return NaturalSort.compare(a.filename, b.filename) == .orderedAscending
            }
        case .duration:
            tracks.sort { $0.duration < $1.duration }
        }
        rebuildOneChapterPerTrack()
    }

    /// Merge selected chapters (contiguous or not) into one chapter at the
    /// first selected chapter's position. Tracks concatenate in timeline order.
    @discardableResult
    mutating func mergeChapters(ids: Set<Chapter.ID>) -> Chapter.ID? {
        let ordered = chapters.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
        guard ordered.count >= 2 else { return nil }

        var trackIDs: [SourceTrack.ID] = []
        for chapter in ordered {
            for tid in chapter.trackIDs {
                if trackIDs.last != tid {
                    trackIDs.append(tid)
                }
            }
        }

        let merged = Chapter(
            title: ordered.first?.title ?? "Chapter",
            trackIDs: trackIDs,
            startOffset: ordered.first?.startOffset ?? 0,
            endOffset: ordered.last?.endOffset
        )
        let firstIndex = chapters.firstIndex { $0.id == ordered[0].id } ?? 0
        chapters.removeAll { ids.contains($0.id) }
        let insertAt = min(firstIndex, chapters.count)
        chapters.insert(merged, at: insertAt)
        syncTrackOrderFromChapters()
        recomputeTimeline()
        return merged.id
    }

    /// Split a chapter back into one chapter per source file.
    @discardableResult
    mutating func splitChapter(id: Chapter.ID) -> [Chapter.ID] {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return [] }
        let original = chapters[index]
        guard original.trackIDs.count >= 2 || original.startOffset > 0 || original.endOffset != nil else {
            return [original.id]
        }

        var replacements: [Chapter] = []
        for (i, tid) in original.trackIDs.enumerated() {
            guard let track = track(id: tid) else { continue }
            let startOffset = i == 0 ? original.startOffset : 0
            let endOffset = i == original.trackIDs.count - 1 ? original.endOffset : nil
            let title: String
            if original.trackIDs.count == 1 {
                title = original.title
            } else {
                title = track.suggestedChapterTitle
            }
            replacements.append(
                Chapter(title: title, trackIDs: [tid], startOffset: startOffset, endOffset: endOffset)
            )
        }
        guard !replacements.isEmpty else { return [original.id] }
        chapters.replaceSubrange(index...index, with: replacements)
        recomputeTimeline()
        return replacements.map(\.id)
    }

    /// Split the chapter that contains `absoluteTime` into two, at the playhead.
    @discardableResult
    mutating func splitAtPlayhead(_ absoluteTime: TimeInterval, newTitle: String? = nil) -> Chapter.ID? {
        guard let chapter = chapter(containing: absoluteTime),
              let index = chapters.firstIndex(where: { $0.id == chapter.id })
        else { return nil }

        let local = absoluteTime - chapter.start
        if local <= 0.15 || local >= chapter.duration - 0.15 {
            return nil
        }

        guard let location = playbackLocation(at: absoluteTime) else { return nil }
        let splitTrackID = location.track.id
        guard let splitIndex = chapter.trackIDs.firstIndex(of: splitTrackID) else { return nil }

        let leftIDs = Array(chapter.trackIDs[...splitIndex])
        let rightIDs = Array(chapter.trackIDs[splitIndex...])

        let left = Chapter(
            title: chapter.title,
            trackIDs: leftIDs,
            startOffset: chapter.startOffset,
            endOffset: location.offset
        )
        let right = Chapter(
            title: newTitle ?? "\(chapter.title) (cont.)",
            trackIDs: rightIDs,
            startOffset: location.offset,
            endOffset: chapter.endOffset
        )
        chapters.replaceSubrange(index...index, with: [left, right])
        recomputeTimeline()
        return right.id
    }

    @discardableResult
    mutating func addMarker(at absoluteTime: TimeInterval, title: String? = nil) -> Chapter.ID? {
        splitAtPlayhead(absoluteTime, newTitle: title ?? "New Chapter")
    }

    /// Delete a chapter marker: audio stays, the chapter joins the previous one.
    mutating func deleteChapterMarker(id: Chapter.ID) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        if index == 0 {
            if chapters.count == 1 { return }
            _ = mergeChapters(ids: [chapters[0].id, chapters[1].id])
            return
        }
        _ = mergeChapters(ids: [chapters[index - 1].id, chapters[index].id])
    }

    mutating func moveChapters(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().map { chapters[$0] }
        var items = chapters
        for index in offsets.sorted(by: >) {
            items.remove(at: index)
        }
        let dest = destination - offsets.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: min(max(dest, 0), items.count))
        chapters = items
        syncTrackOrderFromChapters()
        recomputeTimeline()
    }

    mutating func moveChapter(id: Chapter.ID, by delta: Int) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + delta
        guard chapters.indices.contains(newIndex) else { return }
        chapters.swapAt(index, newIndex)
        syncTrackOrderFromChapters()
        recomputeTimeline()
    }

    mutating func renameChapter(id: Chapter.ID, to title: String) {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
        chapters[index].title = title
    }

    mutating func smartCleanupTitles() {
        for i in chapters.indices {
            chapters[i].title = NameCleanup.smart(chapters[i].title)
        }
    }

    mutating func normalizeChapterTitles() {
        for i in chapters.indices {
            chapters[i].title = NameCleanup.normalizeChapter(chapters[i].title)
        }
    }

    mutating func regexRename(pattern: String, replacement: String) throws {
        for i in chapters.indices {
            chapters[i].title = try NameCleanup.regexReplace(
                chapters[i].title,
                pattern: pattern,
                replacement: replacement
            )
        }
    }

    /// Drop a track onto a destination chapter. Reorders source files without
    /// dropping audio.
    mutating func moveTrack(_ trackID: SourceTrack.ID, toChapter chapterID: Chapter.ID, before: SourceTrack.ID?) {
        for i in chapters.indices {
            chapters[i].trackIDs.removeAll { $0 == trackID }
        }
        chapters.removeAll { $0.trackIDs.isEmpty }
        guard let dest = chapters.firstIndex(where: { $0.id == chapterID }) else { return }
        if let before, let idx = chapters[dest].trackIDs.firstIndex(of: before) {
            chapters[dest].trackIDs.insert(trackID, at: idx)
        } else {
            chapters[dest].trackIDs.append(trackID)
        }
        syncTrackOrderFromChapters()
        recomputeTimeline()
    }

    mutating func appendImportedTracks(_ newTracks: [SourceTrack], rebuildChapters: Bool = true) {
        let startIndex = tracks.count
        var prepared = newTracks
        for i in prepared.indices {
            if prepared[i].trackIndex == 0 || prepared[i].trackIndex == 1 && startIndex > 0 && prepared[i].discIndex == 1 {
                prepared[i].trackIndex = startIndex + i + 1
            }
        }
        tracks.append(contentsOf: prepared)
        if rebuildChapters {
            for track in prepared {
                chapters.append(Chapter(title: track.suggestedChapterTitle, trackIDs: [track.id]))
            }
            recomputeTimeline()
        }
    }

    /// Load chapters from an existing M4B. If none, one implicit chapter.
    mutating func applyEmbeddedChapters(_ embedded: [EmbeddedChapter]) {
        guard tracks.count == 1, let track = tracks.first else {
            rebuildOneChapterPerTrack()
            return
        }
        if embedded.isEmpty {
            let title = track.suggestedChapterTitle.isEmpty ? displayTitle : track.suggestedChapterTitle
            chapters = [Chapter(title: title, trackIDs: [track.id], startOffset: 0, endOffset: nil)]
            recomputeTimeline()
            return
        }
        chapters = embedded.map { item in
            Chapter(
                title: item.title.isEmpty ? "Chapter" : item.title,
                trackIDs: [track.id],
                startOffset: item.start,
                endOffset: item.start + item.duration
            )
        }
        recomputeTimeline()
    }
}
