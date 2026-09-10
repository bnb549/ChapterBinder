import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum OutlineRowID: Hashable, Sendable {
    case chapter(Chapter.ID)
    case track(Chapter.ID, SourceTrack.ID)
}

@Observable
final class AppModel {
    var projects: [BookProject] = []
    var selectedProjectID: BookProject.ID?
    var selection: Set<OutlineRowID> = []
    var editingChapterID: Chapter.ID?
    var cdIgnored = false
    var ripQuality: RipQuality = .paranoiaFull
    var statusMessage: String = "Drop a folder, open an M4B, or rip a CD."
    var errorMessage: String?
    var isImporting = false
    var isRipping = false
    var ripProgress: RipProgress?
    var catalogHits: [CatalogHit] = []
    var isLookingUp = false
    var silenceBreaks: [SilenceBreak] = []
    var showRegexSheet = false
    var showLookupSheet = false
    var showChapterImportSheet = false
    var pendingDiscNumber: Int = 2

    let store = ProjectStore()
    let queue = ExportQueue()
    let player = AudiobookPlayer()
    let driveWatcher = OpticalDriveWatcher()

    var selectedProject: BookProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedProjectIndex: Int? {
        projects.firstIndex { $0.id == selectedProjectID }
    }

    init() {
        projects = store.loadAll()
        selectedProjectID = projects.first?.id
        if let project = selectedProject {
            player.load(project)
        }
        driveWatcher.start()
        ProjectLookup.current = { [weak self] id in
            self?.projects.first { $0.id == id }
        }
        ProjectLookup.clearCacheOnSuccess = { [weak self] id in
            self?.store.clearRipCache(for: id)
        }
    }

    func binding() -> Binding<BookProject>? {
        guard let index = selectedProjectIndex else { return nil }
        return Binding(
            get: { self.projects[index] },
            set: { newValue in
                self.projects[index] = newValue
                self.projects[index].updatedAt = .now
                self.player.load(self.projects[index])
                self.persist(self.projects[index])
            }
        )
    }

    func mutate(_ body: (inout BookProject) throws -> Void) rethrows {
        guard let index = selectedProjectIndex else { return }
        try body(&projects[index])
        projects[index].updatedAt = .now
        player.load(projects[index])
        persist(projects[index])
    }

    func newBlankProject(title: String = "Untitled Book") -> BookProject {
        let project = BookProject(title: title)
        projects.insert(project, at: 0)
        selectedProjectID = project.id
        selection = []
        persist(project)
        return project
    }

    func newFromFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .mp3, .mpeg4Audio, .wav, .aiff, .audio,
            UTType(filenameExtension: "m4b") ?? .mpeg4Audio,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "caf") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
        ]
        panel.prompt = "Add"
        panel.message = "Choose audio files or a folder of already-ripped tracks."
        if panel.runModal() == .OK {
            Task { await importURLs(panel.urls, intoExisting: false) }
        }
    }

    func addFilesToCurrent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if panel.runModal() == .OK {
            Task { await importURLs(panel.urls, intoExisting: true) }
        }
    }

    func importURLs(_ urls: [URL], intoExisting: Bool) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let plan = try await ImportService.makePlan(from: urls)
            if intoExisting, selectedProject != nil {
                mutate { project in
                    project.appendImportedTracks(plan.tracks)
                    applySuggestions(plan, to: &project, overwrite: false)
                }
            } else {
                var project = BookProject(title: plan.suggestedTitle ?? "Untitled Book")
                project.author = plan.suggestedAuthor ?? ""
                project.year = plan.suggestedYear
                project.tracks = plan.tracks
                if plan.isSingleAudiobookFile {
                    project.outputPreset = .keepSource
                    project.applyEmbeddedChapters(plan.embeddedChapters)
                } else {
                    project.rebuildOneChapterPerTrack()
                    if !plan.cueChapters.isEmpty {
                        ChapterListIO.apply(plan.cueChapters, to: &project)
                    } else if !plan.textChapters.isEmpty {
                        ChapterListIO.apply(plan.textChapters, to: &project)
                    }
                }
                applyCover(plan.coverCandidate, to: &project)
                projects.insert(project, at: 0)
                selectedProjectID = project.id
                persist(project)
                player.load(project)
            }
            statusMessage = "Imported \(plan.tracks.count) track\(plan.tracks.count == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedProject() {
        guard let id = selectedProjectID else { return }
        try? store.delete(id)
        projects.removeAll { $0.id == id }
        selectedProjectID = projects.first?.id
        player.unload()
        if let project = selectedProject { player.load(project) }
    }

    func mergeSelection() {
        let ids = selectedChapterIDs()
        mutate { project in
            if let merged = project.mergeChapters(ids: ids) {
                selection = [.chapter(merged)]
            }
        }
    }

    func splitSelection() {
        let ids = selectedChapterIDs()
        guard let first = ids.first else { return }
        mutate { project in
            let newIDs = project.splitChapter(id: first)
            selection = Set(newIDs.map { .chapter($0) })
        }
    }

    func splitAtPlayhead() {
        mutate { project in
            if let id = project.splitAtPlayhead(player.currentTime) {
                selection = [.chapter(id)]
            }
        }
    }

    func addChapterAtPlayhead() {
        mutate { project in
            if let id = project.addMarker(at: player.currentTime) {
                selection = [.chapter(id)]
                editingChapterID = id
            }
        }
    }

    func deleteSelectedMarkers() {
        let ids = selectedChapterIDs()
        mutate { project in
            for id in ids { project.deleteChapterMarker(id: id) }
        }
        selection = []
    }

    func selectedChapterIDs() -> Set<Chapter.ID> {
        var ids = Set<Chapter.ID>()
        for row in selection {
            switch row {
            case .chapter(let id): ids.insert(id)
            case .track(let chapterID, _): ids.insert(chapterID)
            }
        }
        return ids
    }

    func beginRename() {
        editingChapterID = selectedChapterIDs().first
    }

    func smartCleanup() {
        mutate { $0.smartCleanupTitles() }
    }

    func normalizeChapters() {
        mutate { $0.normalizeChapterTitles() }
    }

    func chooseOutput() {
        guard var project = selectedProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: project.outputContainer.fileExtension) ?? .mpeg4Audio]
        panel.nameFieldStringValue = project.suggestedFilename
        panel.canCreateDirectories = true
        panel.title = "Export Audiobook"
        if panel.runModal() == .OK, let url = panel.url {
            project.outputPath = url.path
            mutate { $0.outputPath = url.path }
        }
    }

    func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .jpeg, .png]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first {
            setCover(from: url)
        }
    }

    func setCover(from url: URL) {
        mutate { project in
            applyCover(url, to: &project)
        }
    }

    func pasteCover() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
            errorMessage = "The clipboard does not contain an image."
            return
        }
        guard let index = selectedProjectIndex else { return }
        let dest = store.coverURL(for: projects[index].id)
        do {
            try CoverService.process(image, destination: dest)
            mutate { $0.coverPath = dest.path }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func extractCoverFromAudio() {
        guard let project = selectedProject, let track = project.tracks.first(where: \.hasEmbeddedCover) ?? project.tracks.first else { return }
        Task {
            do {
                let dest = store.coverURL(for: project.id)
                try await CoverService.extractEmbeddedCover(from: track.url, destination: dest)
                mutate { $0.coverPath = dest.path }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func enqueueExport() {
        guard var project = selectedProject else { return }
        if project.outputPath == nil {
            chooseOutput()
            project = selectedProject ?? project
        }
        guard project.outputPath != nil else { return }
        if !HelperBinary.ffmpegAvailable || !HelperBinary.ffprobeAvailable {
            errorMessage = AppError.helperMissing("ffmpeg/ffprobe").localizedDescription
            return
        }
        queue.enqueue(project)
        statusMessage = "Queued “\(project.displayTitle)”."
    }

    func lookupCatalog() {
        guard let project = selectedProject else { return }
        isLookingUp = true
        showLookupSheet = true
        Task {
            defer { isLookingUp = false }
            do {
                catalogHits = try await CatalogLookup.search(title: project.title, author: project.author)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyCatalogHit(_ hit: CatalogHit) {
        mutate { project in
            if project.title == "Untitled Book" || project.title.isEmpty { project.title = hit.title }
            else { project.title = hit.title }
            if !hit.author.isEmpty { project.author = hit.author }
            if let year = hit.year { project.year = year }
            if project.description.isEmpty { project.description = hit.description }
        }
        if let cover = hit.coverURL, let id = selectedProjectID {
            Task {
                do {
                    let dest = store.coverURL(for: id)
                    try await CatalogLookup.downloadCover(from: cover, to: dest)
                    mutate { $0.coverPath = dest.path }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        showLookupSheet = false
    }

    func detectSilence() {
        guard let project = selectedProject else { return }
        let urls: [URL]
        if project.tracks.count == 1 {
            urls = [project.tracks[0].url]
        } else {
            urls = project.tracks.map(\.url)
        }
        Task {
            do {
                var all: [SilenceBreak] = []
                var offset: TimeInterval = 0
                for (i, url) in urls.enumerated() {
                    let breaks = try await SilenceDetection.detect(url: url)
                    all.append(contentsOf: breaks.map { SilenceBreak(time: $0.time + offset, duration: $0.duration) })
                    offset += project.tracks[i].duration
                }
                silenceBreaks = all
                statusMessage = "Found \(all.count) silence break\(all.count == 1 ? "" : "s")."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applySilenceBreaks() {
        guard !silenceBreaks.isEmpty else { return }
        mutate { project in
            for brk in silenceBreaks where brk.duration >= 1.4 {
                _ = project.addMarker(at: brk.time + brk.duration / 2, title: nil)
            }
        }
    }

    func snapPlayheadToSilence() {
        let snapped = SilenceDetection.snap(time: player.currentTime, to: silenceBreaks)
        player.seek(to: snapped)
    }

    func newFromCD() {
        cdIgnored = false
        if driveWatcher.audioDisc == nil {
            driveWatcher.insertMock()
            statusMessage = "Loaded a mock 16-track audio CD so you can build the rip flow without a drive."
        }
        if selectedProject == nil {
            _ = newBlankProject(title: "Untitled Audiobook")
        }
    }

    func ignoreCD() {
        cdIgnored = true
        driveWatcher.removeMock()
    }

    func lookupDisc() {
        guard let disc = driveWatcher.audioDisc else { return }
        isLookingUp = true
        showLookupSheet = true
        Task {
            defer { isLookingUp = false }
            if let discID = disc.toc?.discID, !discID.hasPrefix("mock") {
                catalogHits = (try? await MusicBrainzService.lookupDiscID(discID)) ?? []
            }
            if catalogHits.isEmpty, let project = selectedProject {
                catalogHits = (try? await CatalogLookup.search(title: project.title, author: project.author)) ?? []
            }
        }
    }

    func ripDetectedDisc(asNewDisc: Bool) {
        guard let disc = driveWatcher.audioDisc else {
            errorMessage = AppError.noOpticalDrive.localizedDescription
            return
        }
        if selectedProject == nil {
            _ = newBlankProject(title: disc.name)
        }
        guard let project = selectedProject else { return }
        isRipping = true
        Task {
            defer { isRipping = false }
            do {
                let ripper = CDRipperFactory.make(for: disc)
                var toc = disc.toc
                if toc == nil {
                    toc = try await ripper.readTOC(from: disc)
                }
                guard let toc else { throw AppError.ripFailed("No TOC.") }
                let discIndex: Int
                if asNewDisc {
                    discIndex = (project.discs.map(\.index).max() ?? 0) + 1
                } else {
                    discIndex = project.discs.isEmpty ? 1 : pendingDiscNumber
                }
                let dest = store.ripDirectory(project: project.id, disc: discIndex)
                let urls = try await ripper.rip(
                    disc: DetectedDisc(
                        id: disc.id,
                        name: disc.name,
                        bsdName: disc.bsdName,
                        volumeURL: disc.volumeURL,
                        isAudioCD: true,
                        toc: toc,
                        isMock: disc.isMock
                    ),
                    tracks: toc.tracks.map(\.number),
                    quality: ripQuality,
                    destination: dest
                ) { progress in
                    Task { @MainActor in
                        self.ripProgress = progress
                    }
                }

                var imported: [SourceTrack] = []
                for (i, url) in urls.enumerated() {
                    let probe = try await ProbeService.probe(url: url)
                    imported.append(
                        SourceTrack(
                            path: url.path,
                            discIndex: discIndex,
                            trackIndex: i + 1,
                            duration: probe.duration,
                            originalTitle: toc.tracks[safe: i]?.title ?? url.deletingPathExtension().lastPathComponent,
                            codec: probe.codec,
                            channels: probe.channels,
                            sampleRate: probe.sampleRate,
                            bitrate: probe.bitrate,
                            isRip: true,
                            ripOK: true,
                            embeddedTrackNumber: i + 1
                        )
                    )
                }
                mutate { project in
                    if !project.discs.contains(where: { $0.index == discIndex }) {
                        project.discs.append(
                            Disc(index: discIndex, musicBrainzId: toc.discID, rawTOC: toc.raw, ripStatus: .complete)
                        )
                    }
                    project.appendImportedTracks(imported)
                    if project.title == "Untitled Book" || project.title == "Untitled Audiobook" {
                        project.title = disc.name == "Audio CD (mock)" ? "Untitled Audiobook" : disc.name
                    }
                }
                pendingDiscNumber = discIndex + 1
                statusMessage = "Ripped disc \(discIndex) (\(imported.count) tracks). Insert the next disc and choose “This is disc \(pendingDiscNumber)”."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportChapterList(_ format: ChapterListFormat) {
        guard let project = selectedProject else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.filename
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let text = ChapterListIO.export(project, format: format)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func importChapterList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.urls.first, let text = try? String(contentsOf: url, encoding: .utf8) {
            let chapters = ChapterListIO.parse(text)
            mutate { project in
                ChapterListIO.apply(chapters, to: &project)
            }
        }
    }

    func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInBooks(url: URL) {
        let books = URL(fileURLWithPath: "/System/Applications/Books.app")
        if FileManager.default.fileExists(atPath: books.path) {
            NSWorkspace.shared.open([url], withApplicationAt: books, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func applySuggestions(_ plan: ImportPlan, to project: inout BookProject, overwrite: Bool) {
        if overwrite || project.title == "Untitled Book" {
            if let title = plan.suggestedTitle { project.title = title }
        }
        if overwrite || project.author.isEmpty {
            project.author = plan.suggestedAuthor ?? project.author
        }
        if overwrite || project.year == nil {
            project.year = plan.suggestedYear
        }
        if project.coverPath == nil {
            applyCover(plan.coverCandidate, to: &project)
        }
    }

    private func applyCover(_ url: URL?, to project: inout BookProject) {
        guard let url else { return }
        let dest = store.coverURL(for: project.id)
        do {
            if AudioFileType.isAudio(url) {
                // Extract happens asynchronously; store a note.
                Task { [id = project.id] in
                    try? await CoverService.extractEmbeddedCover(from: url, destination: dest)
                    await MainActor.run {
                        if let index = self.projects.firstIndex(where: { $0.id == id }) {
                            self.projects[index].coverPath = dest.path
                            self.persist(self.projects[index])
                        }
                    }
                }
            } else {
                try CoverService.processImage(at: url, destination: dest)
                project.coverPath = dest.path
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist(_ project: BookProject) {
        do {
            try store.save(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
