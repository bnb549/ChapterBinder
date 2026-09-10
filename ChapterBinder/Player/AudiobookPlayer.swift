import AVFoundation
import Foundation

@Observable
final class AudiobookPlayer {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentChapterID: Chapter.ID?
    var currentTrackID: SourceTrack.ID?
    var statusLine = "Ready"

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var project: BookProject?
    private var switching = false

    func load(_ project: BookProject) {
        self.project = project
        duration = project.totalDuration
        if currentTime > duration { currentTime = 0 }
        refreshLocation()
    }

    func unload() {
        pause()
        removeObservers()
        player = nil
        project = nil
        currentTime = 0
        duration = 0
        currentChapterID = nil
        currentTrackID = nil
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let project else { return }
        duration = project.totalDuration
        Task { await startPlayback(at: currentTime) }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        statusLine = "Paused"
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration, 0))
        currentTime = clamped
        if isPlaying {
            Task { await startPlayback(at: clamped) }
        } else {
            refreshLocation()
        }
    }

    func skip(seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func jumpToChapter(_ chapter: Chapter) {
        seek(to: chapter.start)
    }

    func jumpToTrack(_ track: SourceTrack, in project: BookProject) {
        var cursor: TimeInterval = 0
        for t in project.tracks {
            if t.id == track.id {
                seek(to: cursor)
                return
            }
            cursor += t.duration
        }
    }

    private func startPlayback(at absolute: TimeInterval) async {
        guard let project, let location = project.playbackLocation(at: absolute) else {
            statusLine = "Nothing to play"
            return
        }
        switching = true
        defer { switching = false }
        removeObservers()

        let item = AVPlayerItem(url: location.track.url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentTrackID = location.track.id
        currentChapterID = location.chapter.id

        let seekTime = CMTime(seconds: location.offset, preferredTimescale: 600)
        await player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
        statusLine = location.chapter.title
        addObservers(player: player, project: project, track: location.track, chapter: location.chapter)
    }

    private func addObservers(player: AVPlayer, project: BookProject, track: SourceTrack, chapter: Chapter) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.switching else { return }
                let offset = time.seconds
                let trackStart = self.absoluteStart(of: track, in: project)
                self.currentTime = trackStart + offset
                if let ch = project.chapter(containing: self.currentTime) {
                    self.currentChapterID = ch.id
                    if self.currentTime >= ch.end - 0.05, ch.id != project.chapters.last?.id {
                        // Chapter boundary inside a file is just a marker; keep playing.
                    }
                }
                let trackEndLimit: TimeInterval
                if chapter.trackIDs.last == track.id, let end = chapter.endOffset {
                    trackEndLimit = end
                } else {
                    trackEndLimit = track.duration
                }
                if offset >= trackEndLimit - 0.04 {
                    self.advance(from: track, project: project)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advance(from: track, project: project)
            }
        }
    }

    private func advance(from track: SourceTrack, project: BookProject) {
        guard !switching else { return }
        guard let index = project.tracks.firstIndex(where: { $0.id == track.id }) else {
            pause()
            return
        }
        let nextIndex = index + 1
        if nextIndex < project.tracks.count {
            var cursor: TimeInterval = 0
            for t in project.tracks.prefix(nextIndex) { cursor += t.duration }
            Task { await startPlayback(at: cursor) }
        } else {
            pause()
            currentTime = project.totalDuration
            statusLine = "Finished"
        }
    }

    private func absoluteStart(of track: SourceTrack, in project: BookProject) -> TimeInterval {
        var cursor: TimeInterval = 0
        for t in project.tracks {
            if t.id == track.id { return cursor }
            cursor += t.duration
        }
        return 0
    }

    private func refreshLocation() {
        guard let project else { return }
        if let location = project.playbackLocation(at: currentTime) {
            currentTrackID = location.track.id
            currentChapterID = location.chapter.id
        }
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}
