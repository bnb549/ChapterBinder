import Foundation

enum ExportJobState: String, Sendable {
    case queued, running, paused, succeeded, failed, cancelled
}

@Observable
final class ExportJob: Identifiable {
    let id: UUID
    var projectID: UUID
    var title: String
    var state: ExportJobState
    var progress: Double
    var message: String
    var outputURLs: [URL]
    var error: String?

    init(project: BookProject) {
        id = UUID()
        projectID = project.id
        title = project.displayTitle
        state = .queued
        progress = 0
        message = "Queued"
        outputURLs = []
        error = nil
    }
}

@Observable
final class ExportQueue {
    var jobs: [ExportJob] = []
    private var runTask: Task<Void, Never>?

    var isBusy: Bool { jobs.contains { $0.state == .running || $0.state == .queued } }

    func enqueue(_ project: BookProject) {
        jobs.insert(ExportJob(project: project), at: 0)
        pump()
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.state == .queued {
            job.state = .cancelled
            job.message = "Cancelled"
        } else if job.state == .running {
            job.state = .cancelled
            job.message = "Cancelling…"
            runTask?.cancel()
        }
    }

    func remove(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    func pump() {
        guard runTask == nil else { return }
        runTask = Task { @MainActor in
            defer { runTask = nil }
            while let job = jobs.first(where: { $0.state == .queued }) {
                await run(job)
            }
        }
    }

    @MainActor
    private func run(_ job: ExportJob) async {
        job.state = .running
        job.message = "Starting"
        guard let snapshot = ProjectLookup.current?(job.projectID) else {
            job.state = .failed
            job.error = "Project is no longer open."
            job.message = "Failed"
            return
        }
        guard let outputPath = snapshot.outputPath, !outputPath.isEmpty else {
            job.state = .failed
            job.error = "Choose an output file before exporting."
            job.message = "Failed"
            return
        }
        let destination = URL(fileURLWithPath: outputPath)
        do {
            let report = try await ExportService.export(project: snapshot, destination: destination) { progress in
                Task { @MainActor in
                    job.progress = progress.fraction
                    job.message = progress.message
                }
            }
            if Task.isCancelled || job.state == .cancelled {
                job.state = .cancelled
                job.message = "Cancelled"
                return
            }
            job.outputURLs = report.urls
            job.progress = 1
            job.state = .succeeded
            job.message = report.message
            ProjectLookup.clearCacheOnSuccess?(snapshot.id)
        } catch is CancellationError {
            job.state = .cancelled
            job.message = "Cancelled"
        } catch {
            if job.state == .cancelled {
                job.message = "Cancelled"
                return
            }
            job.state = .failed
            job.error = error.localizedDescription
            job.message = "Failed"
        }
    }
}

enum ProjectLookup {
    static var current: ((UUID) -> BookProject?)?
    static var clearCacheOnSuccess: ((UUID) -> Void)?
}
