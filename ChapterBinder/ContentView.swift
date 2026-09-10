import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            HSplitView {
                centerPane
                    .frame(minWidth: 520)
                if let binding = model.binding() {
                    InspectorView(project: binding)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                } else {
                    EmptyStateView()
                }
            }
        }
        .navigationTitle(model.selectedProject?.displayTitle ?? "ChapterBinder")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onAppear {
            if let project = model.selectedProject {
                model.player.load(project)
            }
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
        }
        .focusable()
        .onKeyPress { press in
            handleKey(press)
        }
    }

    private var centerPane: some View {
        VStack(spacing: 0) {
            CDBannerView()
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.addFilesToCurrent()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .help("Add files to the current book (⌘I)")
            .disabled(model.selectedProject == nil)

            Button {
                model.mergeSelection()
            } label: {
                Label("Merge", systemImage: "square.stack.3d.up")
            }
            .help("Merge selection into one chapter (M)")

            Button {
                model.splitSelection()
            } label: {
                Label("Split", systemImage: "square.split.2x1")
            }

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

