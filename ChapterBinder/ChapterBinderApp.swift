import SwiftUI

@main
struct ChapterBinderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New from Files…") { model.newFromFiles() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Add Files…") { model.addFilesToCurrent() }
                    .keyboardShortcut("i", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Export…") { model.enqueueExport() }
                    .keyboardShortcut("e", modifiers: [.command])
            }
            CommandMenu("Chapter") {
                Button("Merge Selection") { model.mergeSelection() }
                    .keyboardShortcut("m", modifiers: [.command])
                Button("Split Chapter") { model.splitSelection() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Add Marker at Playhead") { model.addChapterAtPlayhead() }
                Button("Split at Playhead") { model.splitAtPlayhead() }
                Button("Delete Marker") { model.deleteSelectedMarkers() }
                Divider()
                Button("Smart Cleanup Titles") { model.smartCleanup() }
                Button("Normalize Chapter Numbers") { model.normalizeChapters() }
                Button("Regex Rename…") { model.showRegexSheet = true }
                Divider()
                Button("Detect Silence") { model.detectSilence() }
                Button("Apply Silence Breaks") { model.applySilenceBreaks() }
            }
            CommandMenu("Book") {
                Button("Catalog Lookup") { model.lookupCatalog() }
                Button("Choose Cover…") { model.chooseCover() }
                Button("Paste Cover") { model.pasteCover() }
                Button("Extract Cover from Audio") { model.extractCoverFromAudio() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
