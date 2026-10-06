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
    var statusMessage: String = "Drop a folder or open an M4B."
    var errorMessage: String?
    var isImporting = false
    var relinkPaths: [String] = []
    var catalogHits: [CatalogHit] = []
    var isLookingUp = false
    var silenceBreaks: [SilenceBreak] = []
    var showRegexSheet = false
    var showLookupSheet = false
    var showChapterImportSheet = false

    let store = ProjectStore()
    let queue = ExportQueue()
    let player = AudiobookPlayer()
    private var fileLeases: [SecurityScope.Lease] = []

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
        refreshFileAccess()
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
                self.commit(newValue, at: index)
            }
        )
    }

    func mutate(_ body: (inout BookProject) throws -> Void) rethrows {
        guard let index = selectedProjectIndex else { return }
        var project = projects[index]
        try body(&project)
        commit(project, at: index)
    }

    /// Writes a project back only when something other than `updatedAt` changed.
    /// Text fields commit during layout, and stamping `updatedAt` on those no-ops
    /// was invalidating the toolbar mid-layout.
    private func commit(_ newValue: BookProject, at index: Int) {
        guard projects.indices.contains(index) else { return }
        var incoming = newValue
        let previous = projects[index]
        incoming.updatedAt = previous.updatedAt
        guard incoming != previous else { return }
        incoming.updatedAt = .now
        projects[index] = incoming
        player.load(incoming)
        persist(incoming)
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
            refreshFileAccess()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedProject() {
        guard let id = selectedProjectID else { return }
        stopFileAccess()
        try? store.delete(id)
        projects.removeAll { $0.id == id }
        selectedProjectID = projects.first?.id
        player.unload()
        if let project = selectedProject { player.load(project) }
        refreshFileAccess()
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
        guard let lease = makeOutputLease() else { return }
        lease.stop()
    }

    /// Save panel plus a live write grant. The caller stops the lease, or the export queue does.
    private func makeOutputLease() -> SecurityScope.Lease? {
        guard let project = selectedProject else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: project.outputContainer.fileExtension) ?? .mpeg4Audio]
        panel.canCreateDirectories = true
        panel.title = "Export Audiobook"
        if let path = project.outputPath, !path.isEmpty {
            let existing = URL(fileURLWithPath: path)
            panel.directoryURL = existing.deletingLastPathComponent()
            panel.nameFieldStringValue = existing.lastPathComponent
        } else {
            panel.nameFieldStringValue = project.suggestedFilename
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        var bookmark = SecurityScope.bookmark(for: url)
        if bookmark == nil && accessed && !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            bookmark = SecurityScope.bookmark(for: url)
        }
        mutate {
            $0.outputPath = url.path
            $0.outputBookmark = bookmark
        }
        if accessed {
            return SecurityScope.Lease(url: url, accessed: true)
        }
        if let saved = try? SecurityScope.outputLease(bookmark: bookmark, path: url.path) {
            return saved
        }
        errorMessage = "ChapterBinder could not get permission to save “\(url.lastPathComponent)”."
        return nil
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
            let bookmark = SecurityScope.bookmark(for: dest)
            mutate {
                $0.coverPath = dest.path
                $0.coverBookmark = bookmark
            }
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
                let bookmark = SecurityScope.bookmark(for: dest)
                mutate {
                    $0.coverPath = dest.path
                    $0.coverBookmark = bookmark
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func enqueueExport() {
        guard let project = selectedProject else { return }
        if project.tracks.isEmpty {
            errorMessage = "Add audio before exporting."
            return
        }
        let lease: SecurityScope.Lease
        if let path = project.outputPath, !path.isEmpty,
           let existing = try? SecurityScope.outputLease(bookmark: project.outputBookmark, path: path) {
            lease = existing
        } else if let chosen = makeOutputLease() {
            lease = chosen
        } else {
            return
        }
        let current = selectedProject ?? project
        queue.enqueue(current, output: lease)
        statusMessage = "Exporting “\(current.displayTitle)”…"
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
                    let bookmark = SecurityScope.bookmark(for: dest)
                    mutate {
                        $0.coverPath = dest.path
                        $0.coverBookmark = bookmark
                    }
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

    func openFinished(url: URL) {
        NSWorkspace.shared.open(url)
    }

    func refreshFileAccess() {
        stopFileAccess()
        guard let project = selectedProject else {
            relinkPaths = []
            return
        }
        var needs: [String] = []
        for track in project.tracks {
            do {
                fileLeases.append(try SecurityScope.lease(bookmark: track.bookmark, path: track.path))
            } catch {
                needs.append(track.path)
            }
        }
        if let cover = project.coverPath {
            do {
                fileLeases.append(try SecurityScope.lease(bookmark: project.coverBookmark, path: cover))
            } catch {
                needs.append(cover)
            }
        }
        relinkPaths = needs
    }

    func relinkFirst() {
        guard let path = relinkPaths.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Relink \(URL(fileURLWithPath: path).lastPathComponent)"
        panel.prompt = "Relink"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let bookmark = SecurityScope.bookmark(for: url)
        mutate { project in
            for index in project.tracks.indices where project.tracks[index].path == path {
                project.tracks[index].path = url.path
                project.tracks[index].bookmark = bookmark
            }
            if project.coverPath == path {
                project.coverPath = url.path
                project.coverBookmark = bookmark
            }
        }
        refreshFileAccess()
    }

    private func stopFileAccess() {
        fileLeases.forEach { $0.stop() }
        fileLeases.removeAll()
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
                            self.projects[index].coverBookmark = SecurityScope.bookmark(for: dest)
                            self.persist(self.projects[index])
                        }
                    }
                }
            } else {
                try CoverService.processImage(at: url, destination: dest)
                project.coverPath = dest.path
                project.coverBookmark = SecurityScope.bookmark(for: dest)
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
