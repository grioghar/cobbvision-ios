import SwiftUI
import CVCore

struct PresetListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: Preset?
    @State private var isNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(env.presets) { preset in
                    Button {
                        isNew = false
                        editing = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preset.name).font(.headline)
                            PresetSummaryRow(preset: preset)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    var updated = env.presets
                    updated.remove(atOffsets: offsets)
                    Task { await env.savePresets(updated) }
                }
                .onMove { source, destination in
                    var updated = env.presets
                    updated.move(fromOffsets: source, toOffset: destination)
                    Task { await env.savePresets(updated) }
                }
            }
            .navigationTitle("Presets")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isNew = true
                        editing = Preset(name: "New preset")
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { preset in
                PresetEditorView(preset: preset, isNew: isNew) { saved in
                    var updated = env.presets
                    if let index = updated.firstIndex(where: { $0.id == saved.id }) {
                        updated[index] = saved
                    } else {
                        updated.append(saved)
                    }
                    Task { await env.savePresets(updated) }
                }
            }
            .overlay {
                if env.presets.isEmpty {
                    ContentUnavailableView(
                        "No presets",
                        systemImage: "slider.horizontal.3",
                        description: Text("Tap + to create one. Presets sync to your CobbVision account.")
                    )
                }
            }
        }
    }
}

struct PresetEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State var preset: Preset
    let isNew: Bool
    let onSave: (Preset) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Preset name", text: $preset.name)
                }

                Section("Cameras") {
                    Picker("Phone cameras", selection: $preset.cameras) {
                        Text("Rear").tag(CameraSelection.rear)
                        Text("Front").tag(CameraSelection.front)
                        Text("Front + Rear").tag(CameraSelection.both)
                    }
                    Picker("Quality", selection: $preset.videoQuality) {
                        Text("720p · 30").tag(VideoQuality.hd720_30)
                        Text("1080p · 30").tag(VideoQuality.hd1080_30)
                        Text("1080p · 60").tag(VideoQuality.hd1080_60)
                        Text("4K · 30").tag(VideoQuality.uhd4k_30)
                    }
                    if preset.cameras == .both, preset.videoQuality != .hd720_30 {
                        Label(
                            "Dual-camera at high quality heats up fast in a car. 720p is the sustainable choice.",
                            systemImage: "thermometer.high"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Actions") {
                    Toggle("Record locally", isOn: modeBinding(.record))
                    Toggle("Live stream", isOn: modeBinding(.stream))
                    if preset.mode.contains(.stream) {
                        Picker("Stream camera", selection: $preset.streamCamera) {
                            ForEach(preset.cameras.positions, id: \.self) { position in
                                Text(position == .front ? "Front" : "Rear").tag(position)
                            }
                        }
                        Picker("Destination", selection: $preset.streamDestinationID) {
                            Text("None").tag(Optional<UUID>.none)
                            ForEach(env.destinations.all) { destination in
                                Text(destination.name).tag(Optional(destination.id))
                            }
                        }
                        if env.destinations.all.isEmpty {
                            Text("Add a stream destination in Settings first.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Telemetry") {
                    Toggle("GPS track", isOn: $preset.gpsEnabled)
                    Toggle("G-force logging", isOn: $preset.gForceEnabled)
                }

                Section("External cameras") {
                    Toggle("Start/stop GoPros with session", isOn: externalCamsBinding)
                }
            }
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func modeBinding(_ flag: SessionMode) -> Binding<Bool> {
        Binding(
            get: { preset.mode.contains(flag) },
            set: { on in
                if on { preset.mode.insert(flag) } else { preset.mode.remove(flag) }
            }
        )
    }

    private var externalCamsBinding: Binding<Bool> {
        Binding(
            get: { !preset.externalCameraActionsOnStart.isEmpty },
            set: { on in
                preset.externalCameraActionsOnStart = on ? [.startRecording] : []
                preset.externalCameraActionsOnStop = on ? [.stopRecording] : []
            }
        )
    }
}
