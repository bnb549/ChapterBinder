import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            centerPane
                .navigationSplitViewColumnWidth(min: 520, ideal: 720)
                .navigationTitle(model.selectedProject?.displayTitle ?? "ChapterBinder")
                .toolbar { toolbar }
        } detail: {
            Group {
                if let binding = model.binding() {
                    InspectorView(project: binding)
                } else {
                    Text("Select or create a book to edit its metadata.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onAppear {
            if let project = model.selectedProject {
                model.player.load(project)
            }
            model.refreshFileAccess()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Bindable(model).showRegexSheet) {
            RegexRenameSheet()
        }
        .sheet(isPresented: Bindable(model).showLookupSheet) {
            CatalogLookupSheet()
        }
        .onChange(of: model.selectedProjectID) { _, _ in
            model.selection = []
            if let project = model.selectedProject {
                model.player.load(project)
            } else {
                model.player.unload()
            }
            model.refreshFileAccess()
        }
        .focusable()
        .onKeyPress { press in
            handleKey(press)
        }
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            if let job = model.queue.trackedJob {
                ExportActivityBar(job: job)
            }
            if !model.relinkPaths.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                    Text("A source file needs to be relinked before it can play or export.")
                        .font(.callout)
                    Spacer()
                    Button("Relink") { model.relinkFirst() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Relink source files")
            }
            if model.selectedProject == nil {
                EmptyStateView()
            } else if model.selectedProject?.tracks.isEmpty == true {
                EmptyStateView()
            } else {
                ChapterTableView()
            }
            if model.selectedProject != nil {
                PlayerBarView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.isImporting {
                ProgressView("Importing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(id: "add-files", placement: .primaryAction) {
            Button {
                model.addFilesToCurrent()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add files to the current book (⌘I)")
            .disabled(model.selectedProject == nil)
        }
        ToolbarItem(id: "merge", placement: .primaryAction) {
            Button {
                model.mergeSelection()
            } label: {
                Label("Merge", systemImage: "square.stack.3d.up")
            }
            .help("Merge selection into one chapter (M)")
        }
        ToolbarItem(id: "split", placement: .primaryAction) {
            Button {
                model.splitSelection()
            } label: {
                Label("Split", systemImage: "square.split.2x1")
            }
        }
        ToolbarItem(id: "export", placement: .primaryAction) {
            Button {
                model.enqueueExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export M4B (⌘E)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    collector.append(url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collector.items()
            if !urls.isEmpty {
                Task { await model.importURLs(urls, intoExisting: model.selectedProject != nil) }
            }
        }
        return true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        guard model.editingChapterID == nil else { return .ignored }
        switch press.characters.lowercased() {
        case "m":
            model.mergeSelection()
            return .handled
        case "s":
            model.splitSelection()
            return .handled
        case " ":
            model.player.toggle()
            return .handled
        default:
            if press.key == .return {
                model.beginRename()
                return .handled
            }
            return .ignored
        }
    }
}

private struct ExportActivityBar: View {
    @Environment(AppModel.self) private var model
    var job: ExportJob

    private var percent: Int { Int((job.progress * 100).rounded()) }

    var body: some View {
        if job.hideBanner {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(headline)
                            .font(.callout)
                            .lineLimit(1)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    actions
                }
                if job.state == .running || job.state == .queued {
                    ProgressView(value: min(max(job.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Export progress")
                        .accessibilityValue("\(percent) percent")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.45))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        case .running, .queued, .paused:
            if job.progress > 0.001 {
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var headline: String {
        switch job.state {
        case .queued: "Export queued"
        case .running: "Exporting \(job.title)"
        case .succeeded: "Exported \(job.title)"
        case .failed: "Export failed"
        case .cancelled: "Export cancelled"
        case .paused: "Export paused"
        }
    }

    private var detail: String {
        if job.state == .failed, let error = job.error { return error }
        var parts: [String] = []
        if !job.fileName.isEmpty { parts.append(job.fileName) }
        if !job.message.isEmpty { parts.append(job.message) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if job.state == .running || job.state == .queued {
                Button("Cancel") { model.queue.cancel(job.id) }
            } else {
                if let url = job.outputURLs.first {
                    Button("Reveal") { model.reveal(url: url) }
                    Button("Open") { model.openFinished(url: url) }
                }
                Button("Dismiss") { model.queue.dismissBanner(job.id) }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

nonisolated private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func items() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

