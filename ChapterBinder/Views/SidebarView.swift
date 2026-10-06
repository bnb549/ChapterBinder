import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Bindable(model).selectedProjectID) {
                Section("Books") {
                    ForEach(model.projects) { project in
                        HStack(spacing: 8) {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayTitle)
                                    .lineLimit(1)
                                Text(subtitle(project))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(project.id as BookProject.ID?)
                        .contextMenu {
                            Button("Duplicate") {
                                var copy = project
                                copy.id = UUID()
                                copy.title = "\(project.displayTitle) copy"
                                copy.createdAt = .now
                                model.projects.insert(copy, at: 0)
                                model.selectedProjectID = copy.id
                            }
                            Button("Delete", role: .destructive) {
                                model.selectedProjectID = project.id
                                model.deleteSelectedProject()
                            }
                        }
                    }
                }

                if !model.queue.jobs.isEmpty {
                    Section("Queue") {
                        ForEach(model.queue.jobs) { job in
                            QueueRow(job: job)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.newFromFiles()
                } label: {
                    Label("New from Files", systemImage: "folder.badge.plus")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private func subtitle(_ project: BookProject) -> String {
        var parts: [String] = []
        if !project.author.isEmpty { parts.append(project.author) }
        parts.append("\(project.chapters.count) ch")
        if project.totalDuration > 0 {
            parts.append(TimeFormatting.clock(project.totalDuration))
        }
        return parts.joined(separator: " · ")
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    var job: ExportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title)
                    .lineLimit(1)
                Spacer()
                Text(job.state.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if job.state == .running || job.state == .queued {
                ProgressView(value: min(max(job.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Export progress")
                    .accessibilityValue("\(Int((job.progress * 100).rounded())) percent")
                HStack {
                    Text(job.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int((job.progress * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if job.state == .succeeded {
                Text(job.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Export result. \(job.message)")
            }
            if job.state == .failed, let error = job.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .accessibilityLabel("Export result. \(error)")
            }
            HStack {
                if job.state == .running || job.state == .queued {
                    Button("Cancel") { model.queue.cancel(job.id) }
                }
                if let url = job.outputURLs.first {
                    Button("Reveal") { model.reveal(url: url) }
                    Button("Open") { model.openFinished(url: url) }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
