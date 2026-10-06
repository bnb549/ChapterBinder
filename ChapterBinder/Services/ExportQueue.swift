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
    var fileName: String
    var hideBanner: Bool
    var output: SecurityScope.Lease?

    init(project: BookProject) {
        id = UUID()
        projectID = project.id
        title = project.displayTitle
        state = .queued
        progress = 0
        message = "Queued"
        outputURLs = []
        error = nil
        fileName = ""
        hideBanner = false
        output = nil
    }

    func releaseOutput() {
        output?.stop()
        output = nil
    }
}

@Observable
final class ExportQueue {
    var jobs: [ExportJob] = []
    private var runTask: Task<Void, Never>?

    var isBusy: Bool { jobs.contains { $0.state == .running || $0.state == .queued } }

    /// The job the main window should track. Running work wins over the latest result.
    var trackedJob: ExportJob? {
        if let active = jobs.first(where: { job in
            !job.hideBanner && (job.state == .running || job.state == .queued)
        }) {
            return active
        }
        return jobs.first { job in
            !job.hideBanner && (job.state == .succeeded || job.state == .failed)
        }
    }

    func enqueue(_ project: BookProject, output: SecurityScope.Lease) {
        let job = ExportJob(project: project)
        job.output = output
        job.fileName = output.url.lastPathComponent
        jobs.insert(job, at: 0)
        pump()
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.state == .queued {
            job.state = .cancelled
            job.message = "Cancelled"
            job.releaseOutput()
        } else if job.state == .running {
            job.state = .cancelled
            job.message = "Cancelling…"
            runTask?.cancel()
        }
    }

    func dismissBanner(_ id: UUID) {
        jobs.first { $0.id == id }?.hideBanner = true
    }

    func remove(_ id: UUID) {
        jobs.first { $0.id == id }?.releaseOutput()
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
        defer { job.releaseOutput() }
        guard let snapshot = ProjectLookup.current?(job.projectID) else {
            job.state = .failed
            job.error = "Project is no longer open."
            job.message = "Failed"
            return
        }
        let destination: URL
        if let output = job.output {
            destination = output.url
        } else if let outputPath = snapshot.outputPath, !outputPath.isEmpty,
                  let lease = try? SecurityScope.outputLease(bookmark: snapshot.outputBookmark, path: outputPath) {
            job.output = lease
            destination = lease.url
        } else {
            job.state = .failed
            job.error = "Choose an output file before exporting."
            job.message = "Failed"
            return
        }
        job.fileName = destination.lastPathComponent
        do {
            let report = try await ExportService.export(project: snapshot, destination: destination) { progress in
                Task { @MainActor in
                    guard job.state == .running else { return }
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
