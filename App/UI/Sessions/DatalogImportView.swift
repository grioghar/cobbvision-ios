import SwiftUI
import UniformTypeIdentifiers
import CVAPI

/// Imports AccessPort datalogs (.csv / .csv.gz) from the Files app — a USB-C
/// flash drive plugged into the phone, iCloud Drive, Dropbox, wherever the
/// AP Manager export landed — gunzips locally, and uploads each file to the
/// controlplane for synchronous analysis.
///
/// (Direct USB to the AccessPort is impossible on iPhone: the AP3 is a
/// vendor-specific bulk USB device and iOS has no user-space USB API.)
struct DatalogImportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    struct ImportItem: Identifiable {
        enum Phase {
            case waiting
            case uploading
            case done(DatalogUploadResponse)
            case failed(String)
        }

        let id = UUID()
        let fileName: String
        var phase: Phase = .waiting
    }

    @State private var showPicker = false
    @State private var items: [ImportItem] = []
    @State private var importing = false

    private static let acceptedTypes: [UTType] = [
        .commaSeparatedText,
        .plainText,
        UTType(filenameExtension: "gz") ?? .data,
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choose datalog files…", systemImage: "folder")
                    }
                    .disabled(importing)
                } footer: {
                    Text("""
                    Pick .csv or .csv.gz datalogs from a USB drive, iCloud Drive, \
                    or any Files location. Export them from the AccessPort with the \
                    AP Manager desktop app or the WebUSB page at cobbvision.grio.co/connect-ap \
                    (the AccessPort's USB port can't talk directly to an iPhone — \
                    Apple doesn't allow apps to access this kind of USB device).
                    """)
                }

                if !items.isEmpty {
                    Section("Files") {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
            .navigationTitle("Import Datalogs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(importing)
                }
            }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: Self.acceptedTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    importFiles(urls)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ImportItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).lineLimit(1)
                switch item.phase {
                case .waiting:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .uploading:
                    Text("Uploading & analyzing…").font(.caption).foregroundStyle(.secondary)
                case .done(let response):
                    Text(summary(response)).font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch item.phase {
            case .waiting:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .uploading:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        }
    }

    private func summary(_ response: DatalogUploadResponse) -> String {
        var parts: [String] = []
        if let score = response.healthScore { parts.append("health \(Int(score))") }
        if let rows = response.rowCount { parts.append("\(rows) rows") }
        if let anomalies = response.anomalyCount { parts.append("\(anomalies) anomalies") }
        return parts.isEmpty ? "Analyzed" : parts.joined(separator: " · ")
    }

    private func importFiles(_ urls: [URL]) {
        let newItems = urls.map { ImportItem(fileName: $0.lastPathComponent) }
        items.append(contentsOf: newItems)
        importing = true

        Task {
            for (url, item) in zip(urls, newItems) {
                setPhase(item.id, .uploading)
                do {
                    let response = try await uploadOne(url)
                    setPhase(item.id, .done(response))
                } catch let error as APIError {
                    setPhase(item.id, .failed(error.userMessage))
                } catch {
                    setPhase(item.id, .failed(error.localizedDescription))
                }
            }
            importing = false
        }
    }

    private func uploadOne(_ url: URL) async throws -> DatalogUploadResponse {
        // Files outside the sandbox (USB drive, iCloud) need scoped access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var data = try Data(contentsOf: url)
        var fileName = url.lastPathComponent
        if Gzip.isGzipped(data) {
            data = try Gzip.decompress(data)
            if fileName.lowercased().hasSuffix(".gz") {
                fileName = String(fileName.dropLast(3))
            }
            if !fileName.lowercased().hasSuffix(".csv") {
                fileName += ".csv"
            }
        }
        return try await env.api.uploadDatalog(
            csv: data,
            fileName: fileName,
            vehicleID: env.selectedVehicleID
        )
    }

    private func setPhase(_ id: UUID, _ phase: ImportItem.Phase) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].phase = phase
        }
    }
}
