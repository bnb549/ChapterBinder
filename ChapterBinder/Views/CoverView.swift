import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CoverView: View {
    @Environment(AppModel.self) private var model
    var project: BookProject

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                if let image = CoverService.load(path: project.coverPath) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Drop cover")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }
            .accessibilityLabel("Cover art")
            .contextMenu {
                Button("Choose…") { model.chooseCover() }
                Button("Paste") { model.pasteCover() }
                Button("Extract from audio") { model.extractCoverFromAudio() }
                Button("Search catalog") { model.lookupCatalog() }
                if project.coverPath != nil {
                    Button("Remove", role: .destructive) {
                        model.mutate { $0.coverPath = nil }
                    }
                }
            }

            HStack {
                Button("Choose…") { model.chooseCover() }
                Button("Paste") { model.pasteCover() }
                Button("Catalog") { model.lookupCatalog() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let url = item as? URL { return url }
                        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                        return nil
                    }()
                    if let url {
                        DispatchQueue.main.async { model.setCover(from: url) }
                    }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in
                        guard let id = model.selectedProjectID else { return }
                        let dest = model.store.coverURL(for: id)
                        try? CoverService.process(image, destination: dest)
                        model.mutate { $0.coverPath = dest.path }
                    }
                }
                return true
            }
        }
        return false
    }
}
