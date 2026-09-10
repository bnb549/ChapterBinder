import SwiftUI

struct PlayerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skip(seconds: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Skip back 15 seconds")

                Button {
                    player.skip(seconds: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Skip back 5 seconds")

                Button {
                    player.skip(seconds: 5)
                } label: {
                    Image(systemName: "goforward.5")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Skip forward 5 seconds")

                Button {
                    player.skip(seconds: 15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Skip forward 15 seconds")

                Text(TimeFormatting.clock(player.currentTime))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityLabel("Elapsed \(TimeFormatting.clock(player.currentTime))")

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .accessibilityLabel("Playback position")

                Text(TimeFormatting.clock(player.duration))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64, alignment: .leading)

                Spacer(minLength: 8)

                Button("Marker") {
                    model.addChapterAtPlayhead()
                }
                .help("Add a chapter at the playhead")

                Button("Split here") {
                    model.splitAtPlayhead()
                }

                if !model.silenceBreaks.isEmpty {
                    Button("Snap to silence") {
                        model.snapPlayheadToSilence()
                    }
                }
            }

            HStack {
                Text(player.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let project = model.selectedProject,
                   let chapter = project.chapters.first(where: { $0.id == player.currentChapterID }) {
                    Text(chapter.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
