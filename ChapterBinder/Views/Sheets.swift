import SwiftUI

struct RegexRenameSheet: View {
    @Environment(AppModel.self) private var model
    @State private var pattern = #"^Track\s+(\d+)"#
    @State private var replacement = "Chapter $1"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regex rename")
                .font(.headline)
            Text("Applied to every chapter title. Uses NSRegularExpression replacement templates ($1, $2).")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Pattern", text: $pattern)
            TextField("Replacement", text: $replacement)
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.showRegexSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        try model.mutate { try $0.regexRename(pattern: pattern, replacement: replacement) }
                        model.showRegexSheet = false
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct CatalogLookupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Catalog lookup")
                    .font(.headline)
                Spacer()
                if model.isLookingUp {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("MusicBrainz, Cover Art Archive, Open Library, and Google Books. Audio stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.catalogHits.isEmpty && !model.isLookingUp {
                Text("No matches. Type a title and author on the book, then search again.")
                    .foregroundStyle(.secondary)
            }
            List(model.catalogHits) { hit in
                Button {
                    model.applyCatalogHit(hit)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).font(.headline)
                            Text(hit.author)
                                .foregroundStyle(.secondary)
                            Text("\(hit.source)\(hit.year.map { " · \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if hit.coverURL != nil {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            HStack {
                Button("Search again") { model.lookupCatalog() }
                Spacer()
                Button("Close") { model.showLookupSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Helpers") {
                LabeledContent("ffmpeg") {
                    Text(HelperBinary.ffmpeg.optionalURL()?.path ?? "Not found")
                        .textSelection(.enabled)
                }
                LabeledContent("ffprobe") {
                    Text(HelperBinary.ffprobe.optionalURL()?.path ?? "Not found")
                        .textSelection(.enabled)
                }
                LabeledContent("cdparanoia") {
                    Text(HelperBinary.cdparanoia.optionalURL()?.path ?? "Not found")
                        .textSelection(.enabled)
                }
                Text("Place universal binaries in Contents/Helpers or install with Homebrew. See README.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Audio never leaves this Mac. Optional internet is used only for disc/book lookup and cover art.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
        .padding()
    }
}
