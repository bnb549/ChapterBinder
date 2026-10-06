import SwiftUI

struct ChapterTableView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedChapterID: Chapter.ID?

    var body: some View {
        if let project = model.selectedProject {
            VStack(spacing: 0) {
                toolbar
                Table(of: OutlineRowID.self, selection: Bindable(model).selection) {
                    TableColumn("") { id in
                        playCell(id, project)
                    }
                    .width(28)

                    TableColumn("#") { id in
                        Text(indexLabel(id, project))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(36)

                    TableColumn("Chapter") { id in
                        titleCell(id, project)
                    }
                    .width(min: 180, ideal: 280)

                    TableColumn("Source files") { id in
                        sourceCell(id, project)
                    }
                    .width(min: 100, ideal: 160)

                    TableColumn("Start") { id in
                        Text(startLabel(id, project))
                            .monospacedDigit()
                    }
                    .width(72)

                    TableColumn("Duration") { id in
                        Text(durationLabel(id, project))
                            .monospacedDigit()
                    }
                    .width(72)

                    TableColumn("Disc") { id in
                        Text(discLabel(id, project))
                            .foregroundStyle(.secondary)
                    }
                    .width(44)
                } rows: {
                    ForEach(project.chapters) { chapter in
                        if chapter.trackIDs.count > 1 {
                            DisclosureTableRow(OutlineRowID.chapter(chapter.id)) {
                                ForEach(chapter.trackIDs, id: \.self) { tid in
                                    TableRow(OutlineRowID.track(chapter.id, tid))
                                }
                            }
                        } else {
                            TableRow(OutlineRowID.chapter(chapter.id))
                        }
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: OutlineRowID.self) { rows in
                    contextMenu(rows, project: project)
                }
                .onDeleteCommand {
                    model.deleteSelectedMarkers()
                }
                .onChange(of: model.editingChapterID) { _, newID in
                    if focusedChapterID != newID {
                        focusedChapterID = newID
                    }
                }
                .onChange(of: focusedChapterID) { _, newID in
                    if model.editingChapterID != newID {
                        model.editingChapterID = newID
                    }
                }
                .accessibilityLabel("Chapters")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Merge") { model.mergeSelection() }
                .help("Merge selected tracks into one chapter (M)")
                .disabled(model.selectedChapterIDs().count < 2)
            Button("Split") { model.splitSelection() }
                .help("Split chapter into original source files (S)")
            Button("Rename") { model.beginRename() }
            Menu("Cleanup") {
                Button("Smart cleanup") { model.smartCleanup() }
                Button("Normalize Chapter N") { model.normalizeChapters() }
                Button("Regex rename…") { model.showRegexSheet = true }
            }
            Menu("Chapters") {
                Button("Import list…") { model.importChapterList() }
                Button("Export YouTube timestamps") { model.exportChapterList(.youtube) }
                Button("Export chapters.txt") { model.exportChapterList(.chaptersTxt) }
                Button("Export ffmetadata") { model.exportChapterList(.ffmetadata) }
            }
            Button("Silence") { model.detectSilence() }
                .help("Suggest breaks on long silences")
            Spacer()
            if let project = model.selectedProject {
                Text("\(project.chapters.count) chapters · \(project.tracks.count) files · \(TimeFormatting.clock(project.totalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func playCell(_ id: OutlineRowID, _ project: BookProject) -> some View {
        Button {
            play(id, project)
        } label: {
            Image(systemName: "play.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Play from here")
    }

    @ViewBuilder
    private func titleCell(_ id: OutlineRowID, _ project: BookProject) -> some View {
        switch id {
        case .chapter(let chapterID):
            if project.chapters.contains(where: { $0.id == chapterID }) {
                TextField("Chapter title", text: chapterTitleBinding(chapterID))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedChapterID, equals: chapterID)
                    .onSubmit { model.editingChapterID = nil }
                    .accessibilityLabel(chapterAccessibilityLabel(chapterID, project))
            }
        case .track(_, let trackID):
            if let track = project.track(id: trackID) {
                Text(track.originalTitle.isEmpty ? track.filename : track.originalTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sourceCell(_ id: OutlineRowID, _ project: BookProject) -> some View {
        switch id {
        case .chapter(let chapterID):
            if let chapter = project.chapters.first(where: { $0.id == chapterID }) {
                let count = chapter.trackIDs.count
                if count > 1 {
                    Text("\(count) tracks")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .accessibilityLabel("\(count) source files")
                } else if let track = project.tracks(for: chapter).first {
                    Text(track.filename)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        case .track(_, let trackID):
            if let track = project.track(id: trackID) {
                HStack(spacing: 4) {
                    Text(track.filename)
                        .lineLimit(1)
                    if !track.ripOK {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func indexLabel(_ id: OutlineRowID, _ project: BookProject) -> String {
        switch id {
        case .chapter(let chapterID):
            if let i = project.chapters.firstIndex(where: { $0.id == chapterID }) {
                return "\(i + 1)"
            }
        case .track(let chapterID, let trackID):
            if let chapter = project.chapters.first(where: { $0.id == chapterID }),
               let i = chapter.trackIDs.firstIndex(of: trackID) {
                return "\(i + 1)"
            }
        }
        return ""
    }

    private func startLabel(_ id: OutlineRowID, _ project: BookProject) -> String {
        switch id {
        case .chapter(let chapterID):
            return project.chapters.first { $0.id == chapterID }.map { TimeFormatting.clock($0.start) } ?? ""
        case .track(let chapterID, let trackID):
            guard let chapter = project.chapters.first(where: { $0.id == chapterID }) else { return "" }
            var t = chapter.start
            for tid in chapter.trackIDs {
                if tid == trackID { return TimeFormatting.clock(t) }
                t += project.track(id: tid)?.duration ?? 0
            }
            return ""
        }
    }

    private func durationLabel(_ id: OutlineRowID, _ project: BookProject) -> String {
        switch id {
        case .chapter(let chapterID):
            return project.chapters.first { $0.id == chapterID }.map { TimeFormatting.clock($0.duration) } ?? ""
        case .track(_, let trackID):
            return project.track(id: trackID).map { TimeFormatting.clock($0.duration) } ?? ""
        }
    }

    private func discLabel(_ id: OutlineRowID, _ project: BookProject) -> String {
        switch id {
        case .chapter(let chapterID):
            if let chapter = project.chapters.first(where: { $0.id == chapterID }) {
                let discs = Set(project.tracks(for: chapter).map(\.discIndex))
                if discs.count == 1, let d = discs.first { return "\(d)" }
                if discs.count > 1 { return "—" }
            }
        case .track(_, let trackID):
            if let track = project.track(id: trackID) { return "\(track.discIndex)" }
        }
        return ""
    }

    private func chapterTitleBinding(_ chapterID: Chapter.ID) -> Binding<String> {
        Binding(
            get: {
                model.selectedProject?.chapters.first { $0.id == chapterID }?.title ?? ""
            },
            set: { newValue in
                model.mutate { $0.renameChapter(id: chapterID, to: newValue) }
            }
        )
    }

    private func chapterAccessibilityLabel(_ chapterID: Chapter.ID, _ project: BookProject) -> String {
        guard let chapter = project.chapters.first(where: { $0.id == chapterID }) else {
            return "Chapter title"
        }
        let name = chapter.title.isEmpty ? "Untitled chapter" : chapter.title
        return "\(name), starts at \(TimeFormatting.clock(chapter.start))"
    }

    private func play(_ id: OutlineRowID, _ project: BookProject) {
        switch id {
        case .chapter(let chapterID):
            if let chapter = project.chapters.first(where: { $0.id == chapterID }) {
                model.player.jumpToChapter(chapter)
                model.player.play()
            }
        case .track(_, let trackID):
            if let track = project.track(id: trackID) {
                model.player.jumpToTrack(track, in: project)
                model.player.play()
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ rows: Set<OutlineRowID>, project: BookProject) -> some View {
        Button("Play from here") {
            if let first = rows.first { play(first, project) }
        }
        Button("Merge") { model.mergeSelection() }
        Button("Split into source files") { model.splitSelection() }
        Button("Split at playhead") { model.splitAtPlayhead() }
        Button("Rename") { model.beginRename() }
        Divider()
        Button("Move up") {
            if let id = model.selectedChapterIDs().first {
                model.mutate { $0.moveChapter(id: id, by: -1) }
            }
        }
        Button("Move down") {
            if let id = model.selectedChapterIDs().first {
                model.mutate { $0.moveChapter(id: id, by: 1) }
            }
        }
        Divider()
        Button("Delete marker") { model.deleteSelectedMarkers() }
    }
}

extension OutlineRowID: Identifiable {
    var id: Self { self }
}
