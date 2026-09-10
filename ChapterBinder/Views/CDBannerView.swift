import SwiftUI

struct CDBannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.cdIgnored, let disc = model.driveWatcher.audioDisc {
            HStack(spacing: 12) {
                Image(systemName: "opticaldisc.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(disc))
                        .font(.headline)
                    Text(detail(disc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRipping {
                    ProgressView(value: model.ripProgress?.fraction ?? 0)
                        .frame(width: 120)
                    Text(model.ripProgress?.message ?? "Ripping…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Quality", selection: Bindable(model).ripQuality) {
                        ForEach(RipQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Button("Lookup") { model.lookupDisc() }
                    Button("Rip") { model.ripDetectedDisc(asNewDisc: model.selectedProject?.discs.isEmpty ?? true) }
                        .keyboardShortcut("r", modifiers: [.command])
                    if let project = model.selectedProject, !project.discs.isEmpty {
                        Button("This is disc \(model.pendingDiscNumber)") {
                            model.ripDetectedDisc(asNewDisc: true)
                        }
                    }
                    Button("Ignore") { model.ignoreCD() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio CD detected")
        } else if !model.driveWatcher.hasOpticalHardware, model.selectedProject != nil {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                Text("No optical drive connected. A USB SuperDrive or generic USB DVD drive works — modern Macs have no built-in drive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use mock CD") { model.driveWatcher.insertMock() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func headline(_ disc: DetectedDisc) -> String {
        let count = disc.trackCount
        let time = TimeFormatting.clock(disc.totalDuration)
        if count > 0 {
            return "Audio CD detected — \(count) tracks, \(time)"
        }
        return "Audio CD detected — \(disc.name)"
    }

    private func detail(_ disc: DetectedDisc) -> String {
        if disc.isMock {
            return "Mock disc for development. Rip writes short silent WAVs into the project cache."
        }
        return disc.bsdName
    }
}
