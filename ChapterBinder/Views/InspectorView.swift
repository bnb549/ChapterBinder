import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    var project: Binding<BookProject>

    var body: some View {
        let book = project.wrappedValue
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverView(project: book)

                GroupBox("Book") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledField("Title", text: project.title)
                        LabeledField("Sort title", text: project.sortTitle)
                        LabeledField("Author", text: project.author)
                        LabeledField("Narrator", text: project.narrator)
                        LabeledField("Series", text: project.series)
                        LabeledField("Series part", text: project.seriesPart)
                        TextField("Year", value: project.year, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                        LabeledField("Genre", text: project.genre)
                        LabeledField("Language", text: project.language)
                        LabeledField("Publisher", text: project.publisher)
                        LabeledField("Copyright", text: project.copyright)
                        LabeledField("Comment", text: project.comment)
                        TextField("Description", text: project.description, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(6)
                }

                GroupBox("Encode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Preset", selection: project.outputPreset) {
                            ForEach(OutputPreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        Text(book.outputPreset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Container", selection: project.outputContainer) {
                            ForEach(OutputContainer.allCases) { container in
                                Text(container.label).tag(container)
                            }
                        }
                        .pickerStyle(.segmented)
                        if book.outputPreset == .custom {
                            HStack {
                                TextField("kbps", value: project.customBitrate, format: .number)
                                Picker("Channels", selection: project.customChannels) {
                                    Text("Mono").tag(1)
                                    Text("Stereo").tag(2)
                                }
                                Picker("Rate", selection: project.customSampleRate) {
                                    Text("22.05 kHz").tag(22050)
                                    Text("44.1 kHz").tag(44100)
                                    Text("48 kHz").tag(48000)
                                }
                            }
                        }
                        Toggle("Speech loudness normalize", isOn: project.loudnessNormalize)
                        Toggle("Strip leading/trailing silence", isOn: project.stripSilence)
                        Toggle("Split long books", isOn: Binding(
                            get: { book.splitMaxBytes != nil || book.splitMaxHours != nil },
                            set: { on in
                                if on {
                                    project.wrappedValue.splitMaxBytes = 1_900_000_000
                                    project.wrappedValue.splitMaxHours = 20
                                } else {
                                    project.wrappedValue.splitMaxBytes = nil
                                    project.wrappedValue.splitMaxHours = nil
                                }
                            }
                        ))
                        if book.splitMaxBytes != nil {
                            Text("Volumes stay under ~1.9 GB / 20 hours, tagged Part 1/2.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let path = book.outputPath {
                            Text(path)
                                .font(.caption)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No destination yet")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Choose…") { model.chooseOutput() }
                            Spacer()
                            Button("Export") { model.enqueueExport() }
                                .keyboardShortcut("e", modifiers: [.command])
                                .disabled(book.tracks.isEmpty)
                        }
                        Group {
                            if book.loudnessNormalize || book.stripSilence {
                                #if APP_STORE
                                Text("Loudness normalize and silence trimming are not in the App Store build. Turn them off to export. Audio stays on this Mac.")
                                #else
                                Text(HelperBinary.ffmpeg.optionalURL() == nil
                                     ? "Loudness normalize and silence trimming need the optional ffmpeg helper in Contents/Helpers. Turn them off to export with the built-in encoder. Homebrew is not required."
                                     : "Those filters use the optional ffmpeg helper. Chapters are still stamped on this Mac.")
                                #endif
                            } else if ExportPlanner.canStreamCopy(project: book, settings: book.encodeSettings) {
                                Text("AAC will be copied. Chapters, cover, and tags are stamped without re-encoding.")
                            } else {
                                Text("Exports as AAC-LC at the preset bitrate on this Mac.")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            .padding(14)
        }
        .accessibilityLabel("Book metadata")
    }
}

private struct LabeledField: View {
    let title: String
    var text: Binding<String>

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
