import SwiftUI
import CVCore

struct StreamDestinationsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var destinations: [StreamDestination] = []
    @State private var editing: StreamDestination?
    @State private var isNew = false

    var body: some View {
        List {
            ForEach(destinations) { destination in
                Button {
                    isNew = false
                    editing = destination
                } label: {
                    VStack(alignment: .leading) {
                        Text(destination.name)
                        Text("\(destination.kind.rawValue.uppercased()) · \(destination.url)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    env.destinations.remove(id: destinations[index].id)
                }
                reload()
            }

            Section {
                Button {
                    isNew = true
                    editing = StreamDestination(name: "", kind: .rtmp, url: "")
                } label: {
                    Label("Add destination", systemImage: "plus")
                }
            } footer: {
                Text("""
                YouTube: rtmp://a.rtmp.youtube.com/live2 + your stream key.
                Twitch: rtmp://live.twitch.tv/app + your stream key.
                Self-hosted (SRT, best over LTE): srt://your-server:8890 with streamid publish:cobbvision:cobb:password — see infra/mediamtx in the repo.
                """)
            }
        }
        .navigationTitle("Stream Destinations")
        .onAppear { reload() }
        .sheet(item: $editing) { destination in
            DestinationEditorView(destination: destination, isNew: isNew) {
                reload()
            }
        }
    }

    private func reload() {
        destinations = env.destinations.all
    }
}

private struct DestinationEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State var destination: StreamDestination
    @State private var streamKey = ""
    let isNew: Bool
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. YouTube)", text: $destination.name)
                    Picker("Protocol", selection: $destination.kind) {
                        Text("RTMP").tag(StreamDestination.Kind.rtmp)
                        Text("SRT").tag(StreamDestination.Kind.srt)
                    }
                    TextField(
                        destination.kind == .rtmp ? "rtmp://server/app" : "srt://server:8890",
                        text: $destination.url
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                Section {
                    SecureField(
                        destination.kind == .rtmp ? "Stream key" : "Stream ID (publish:…)",
                        text: $streamKey
                    )
                } footer: {
                    Text("Stored only in this phone's Keychain — never synced to the server.")
                }
            }
            .navigationTitle(isNew ? "New Destination" : "Edit Destination")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        env.destinations.upsert(destination, streamKey: streamKey.isEmpty ? nil : streamKey)
                        onDone()
                        dismiss()
                    }
                    .disabled(destination.name.isEmpty || destination.url.isEmpty)
                }
            }
            .onAppear {
                if !isNew {
                    streamKey = env.destinations.streamKey(for: destination) ?? ""
                }
            }
        }
    }
}
