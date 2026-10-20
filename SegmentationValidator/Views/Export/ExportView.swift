import SwiftUI
import UniformTypeIdentifiers

/// CSV export (share sheet: Files, AirDrop, Mail, …) and CSV import for backups.
struct ExportView: View {
    @Environment(AppModel.self) private var model

    @State private var options = CSVOptions()
    @State private var onlyRange = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var until = Date.now
    @State private var file: ExportFile?
    @State private var exportError: String?
    @State private var showingImporter = false
    @State private var importMessage: String?
    @State private var locationFile: LocationFile?
    @State private var locationError: String?

    private struct ExportFile: Equatable {
        var url: URL
        var rowCount: Int
        var preview: String
    }

    private struct ExportKey: Hashable {
        var options: CSVOptions
        var onlyRange: Bool
        var from: Date
        var until: Date
        var revision: Int
    }

    private struct LocationFile: Equatable {
        var url: URL
        var count: Int
    }

    private struct LocationExportKey: Hashable {
        var export: ExportKey
        var locationRevision: Int
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection

                Section {
                    Toggle("Only a date range", isOn: $onlyRange.animation())
                    if onlyRange {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("Until", selection: $until, in: from..., displayedComponents: .date)
                    }
                } header: {
                    Text("Range")
                }

                Section {
                    Picker("Separator", selection: $options.delimiter) {
                        Text("Comma ( , )").tag(CSVOptions.Delimiter.comma)
                        Text("Semicolon ( ; )").tag(CSVOptions.Delimiter.semicolon)
                    }
                    Toggle("Excel compatible (UTF-8 BOM)", isOn: $options.includeBOM)
                    Toggle("Include running segment", isOn: $options.includeRunning)
                } header: {
                    Text("Format")
                } footer: {
                    Text("For Excel with German or Swiss settings choose semicolon and turn on Excel compatible. Python, R and Numbers read the default.")
                }

                Section {
                    if let file {
                        ShareLink(item: file.url) {
                            Label(L10n.format("Export %lld segments as CSV", file.rowCount), systemImage: "square.and.arrow.up")
                                .font(.headline)
                        }
                        .disabled(file.rowCount == 0)
                    } else if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                } footer: {
                    Text("Save it to Files, send it by e-mail or AirDrop it to your computer.")
                }

                if model.hasLocationPoints || model.settings.locationTracking {
                    locationSection
                }

                if let file, file.rowCount > 0 {
                    Section {
                        ScrollView(.horizontal) {
                            Text(verbatim: file.preview)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Preview")
                    }
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    if let importMessage {
                        Text(importMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Backup and restore")
                } footer: {
                    Text("Imports a CSV exported by this app, e.g. to move your data to a new iPhone. Existing segments are updated, nothing is deleted.")
                }
            }
            .navigationTitle("Export")
            .task(id: exportKey) {
                regenerate()
            }
            .task(id: locationExportKey) {
                await regenerateLocationFile()
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importMessage = model.importCSV(from: url)
                    }
                case .failure(let error):
                    importMessage = error.localizedDescription
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            let segments = model.book.segments
            LabeledContent("Segments", value: "\(segments.count)")
            LabeledContent("Days", value: "\(model.daysWithData.count)")
            if let first = segments.first, let last = segments.last {
                LabeledContent("Period", value: "\(Formatting.date(first.start)) – \(Formatting.date(last.start))")
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("All data is stored only on this iPhone. Export regularly as a backup.")
        }
    }

    private var exportKey: ExportKey {
        ExportKey(options: options, onlyRange: onlyRange, from: from, until: until, revision: model.revision)
    }

    private var locationExportKey: LocationExportKey {
        LocationExportKey(export: exportKey, locationRevision: model.locationRevision)
    }

    private var locationSection: some View {
        Section {
            if let locationFile {
                ShareLink(item: locationFile.url) {
                    Label(L10n.format("Export %lld location points as CSV", locationFile.count), systemImage: "location")
                        .font(.headline)
                }
                .disabled(locationFile.count == 0)
            } else if let locationError {
                Label(locationError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                ProgressView()
            }
        } header: {
            Text("Location points")
        } footer: {
            Text("One row per point: time, coordinates, accuracy, the movement type logged at that time and your True/False answers. Uses the range and format above.")
        }
    }

    private func regenerateLocationFile() async {
        do {
            let range = onlyRange ? min(from, until)...max(from, until) : nil
            let result = try await model.exportLocationFile(options: options, range: range)
            locationFile = LocationFile(url: result.url, count: result.count)
            locationError = nil
        } catch {
            locationFile = nil
            locationError = error.localizedDescription
        }
    }

    private func regenerate() {
        do {
            let range = onlyRange ? min(from, until)...max(from, until) : nil
            let url = try model.exportFile(options: options, range: range)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            file = ExportFile(
                url: url,
                rowCount: max(0, lines.count - 1),
                preview: lines.prefix(6).joined(separator: "\n")
            )
            exportError = nil
        } catch {
            file = nil
            exportError = error.localizedDescription
        }
    }
}
