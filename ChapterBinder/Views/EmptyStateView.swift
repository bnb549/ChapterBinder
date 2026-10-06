import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("ChapterBinder")
                    .font(.largeTitle.weight(.semibold))
                Text("Turn audio files into a single chaptered M4B.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(alignment: .top, spacing: 16) {
                PathCard(
                    icon: "folder.fill.badge.plus",
                    title: "Drop a folder",
                    detail: "Already-ripped MP3 / M4A / FLAC / WAV. Natural sort, then merge tracks into real chapters."
                ) {
                    model.newFromFiles()
                }
                PathCard(
                    icon: "bookmark.fill",
                    title: "Open an M4B",
                    detail: "Add chapter markers from the player and save with stream copy. No re-encode."
                ) {
                    model.newFromFiles()
                }
            }
            .padding(.horizontal, 24)

            Text("Drag files or folders anywhere in this window. Audio never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct PathCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 240, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
