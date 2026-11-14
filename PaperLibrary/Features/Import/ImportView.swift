import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI
import UniformTypeIdentifiers

private enum ImportSource { case arxiv, pdf }

struct ImportView: View {
    @Bindable var coordinator: ImportCoordinator
    let pdfs: PDFCoordinator
    let onImported: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var destination: UUID?
    @State private var assignExisting = true
    @State private var refreshMetadata = false
    @State private var error: String?
    @State private var batch: UUID?
    @State private var historyLimit = 100
    @State private var showingActivity: Bool
    @State private var source: ImportSource = .arxiv
    @State private var showFilePicker = false
    @State private var selectedURL: URL?
    @State private var metadata: LocalPDFMetadata?
    @State private var pdfTitle = ""
    @State private var pdfAuthors = ""
    @State private var pdfAbstract = ""
    @State private var titleEdited = false
    @State private var authorsEdited = false
    @State private var abstractEdited = false
    @State private var showAbstract = false
    @State private var recoveringMetadata = false
    @State private var metadataMessage: String?
    @State private var metadataRequest = UUID()
    @State private var inspectingPDF = false
    @State private var addingPDF = false
    @State private var dropTargeted = false
    @State private var localTask: Task<Void, Never>?

    init(coordinator: ImportCoordinator, pdfs: PDFCoordinator, destinationCourse: UUID?, showHistory: Bool = false, onImported: @escaping (UUID) -> Void) {
        self.coordinator = coordinator
        self.pdfs = pdfs
        self.onImported = onImported
        _destination = State(initialValue: destinationCourse)
        _showingActivity = State(initialValue: showHistory)
    }

    private var repository: LibraryRepository { coordinator.repository }
    private var preview: [ImportInput] { (try? ImportInput.parse(input)) ?? [] }
    private var jobs: [ImportJob] { repository.importJobs.filter { batch == nil || $0.batchID == batch } }
    private var retryIDs: Set<UUID> {
        Set(jobs.filter { ($0.state.canRetry || (!coordinator.isRunning && [.pending, .inProgress].contains($0.state))) && $0.identifier != nil }.map(\.id))
    }
    private var activeBatches: Set<UUID> { Set(jobs.filter { [.pending, .inProgress].contains($0.state) }.map(\.batchID)) }
    private var canAdd: Bool {
        if source == .arxiv { return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return metadata != nil && !pdfTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inspectingPDF && !recoveringMetadata && !addingPDF && !pdfs.isImporting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Strings.text(showingActivity ? "import.history" : "import.title")).font(.title2.weight(.semibold))
            if showingActivity { activity }
            else {
                Picker(Strings.text("import.source"), selection: $source) {
                    Text(Strings.text("import.arxivSource")).tag(ImportSource.arxiv)
                    Text(Strings.text("import.pdfSource")).tag(ImportSource.pdf)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 280).frame(maxWidth: .infinity).disabled(addingPDF)
                if source == .arxiv { arxivInput }
                else { pdfInput }
                if !repository.courses.isEmpty { destinationPicker }
                if source == .arxiv { DisclosureGroup(Strings.text("action.options")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(Strings.text("import.assignExisting"), isOn: $assignExisting).disabled(destination == nil)
                        Toggle(Strings.text("import.refresh"), isOn: $refreshMetadata)
                    }.font(.callout).padding(.top, 10)
                }.font(.callout) }
            }
            if let message = error ?? (showingActivity || source == .arxiv ? coordinator.errorMessage : nil) { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if showingActivity {
                    Button(Strings.text("import.new")) { batch = nil; input = ""; showingActivity = false }
                } else if !repository.importJobs.isEmpty && !addingPDF {
                    Button(Strings.text("import.history")) { batch = nil; showingActivity = true }.buttonStyle(.link)
                }
                Spacer()
                if addingPDF { ProgressView().controlSize(.small) }
                Button(Strings.text(showingActivity ? "action.done" : "action.cancel")) { localTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if !showingActivity {
                    Button(Strings.text(addingPDF ? "import.addingPDF" : "action.add")) {
                        if source == .arxiv { enqueue() } else { addPDF() }
                    }.keyboardShortcut(.defaultAction).disabled(!canAdd)
                }
            }
        }.padding(28).frame(width: 560)
        .interactiveDismissDisabled(addingPDF)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { selectPDF(url) }
            case .failure(let failure): if (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
            }
        }
        .task(id: metadataRequest) {
            guard let url = selectedURL else { return }
            let request = metadataRequest
            metadata = nil; error = nil; metadataMessage = nil; inspectingPDF = true
            recoveringMetadata = false; titleEdited = false; authorsEdited = false; abstractEdited = false; showAbstract = false
            defer { if metadataRequest == request { inspectingPDF = false; recoveringMetadata = false } }
            do {
                let value = try await pdfs.files.inspectLocal(url, limits: pdfs.limits)
                try Task.checkCancellation()
                metadata = value; pdfTitle = ""; pdfAuthors = value.authors.joined(separator: "\n"); pdfAbstract = value.abstract
                inspectingPDF = false
                do {
                    guard value.hasExtractableText else { pdfTitle = value.filenameTitle; metadataMessage = Strings.text("import.metadataNoText"); return }
                    recoveringMetadata = true
                    do {
                        let recovered = try await pdfs.recoverLocalMetadata(value)
                        try Task.checkCancellation()
                        guard metadataRequest == request else { return }
                        let draft = recovered.fillingMissing(in: PaperDraft(title: pdfTitle, authors: pdfAuthors.components(separatedBy: .newlines), abstract: pdfAbstract), fallbackTitle: value.filenameTitle, protectTitle: titleEdited, protectAuthors: authorsEdited, protectAbstract: abstractEdited)
                        pdfTitle = draft.title; pdfAuthors = draft.authors.joined(separator: "\n"); pdfAbstract = draft.abstract
                        if pdfAuthors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pdfAbstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            metadataMessage = Strings.text("import.metadataIncomplete")
                        } else if recovered.title.isEmpty && !titleEdited {
                            metadataMessage = Strings.text("import.titleFallback")
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard !Task.isCancelled, metadataRequest == request else { return }
                        if !titleEdited { pdfTitle = value.filenameTitle }
                        metadataMessage = Strings.text("import.metadataUnavailable")
                    }
                }
            } catch is CancellationError {} catch {
                if !Task.isCancelled && metadataRequest == request { self.error = error.localizedDescription }
            }
        }
        .onChange(of: source) { error = nil }
        .onDisappear { localTask?.cancel() }
        .onChange(of: repository.courses.map(\.id)) { _, ids in
            if let destination, !ids.contains(destination) { self.destination = nil }
        }
    }

    private var arxivInput: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.text("import.hint")).foregroundStyle(.secondary)
            TextEditor(text: $input).font(.body).frame(height: 110).padding(8)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Strings.text("import.input"))
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("\(preview.compactMap(\.identifier).count) \(Strings.text("paper.count"))")
                    let invalid = preview.filter { $0.error != nil }.count
                    if invalid > 0 { Text("· \(invalid) \(Strings.text("import.invalid"))").foregroundStyle(.orange) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pdfInput: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let metadata {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metadata.filename).fontWeight(.medium).lineLimit(1)
                        Text("\(metadata.pageCount) \(Strings.text(metadata.pageCount == 1 ? "import.page" : "import.pages")) · \(metadata.size.formatted(.byteCount(style: .file).locale(Strings.locale)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(Strings.text("import.changePDF")) { showFilePicker = true }.buttonStyle(.link)
                }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                if recoveringMetadata {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Strings.text("import.readingMetadata")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let metadataMessage {
                    Text(metadataMessage).font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text(Strings.text("paper.title")).foregroundStyle(.secondary)
                        TextField(Strings.text("paper.title"), text: Binding(get: { pdfTitle }, set: { pdfTitle = $0; titleEdited = true }), axis: .vertical).lineLimit(1...3)
                    }
                    GridRow {
                        Text(Strings.text("paper.authors")).foregroundStyle(.secondary)
                        TextField(Strings.text("import.pdfAuthorsHint"), text: Binding(get: { pdfAuthors }, set: { pdfAuthors = $0; authorsEdited = true }), axis: .vertical).lineLimit(1...3)
                    }
                }.textFieldStyle(.roundedBorder)
                DisclosureGroup(Strings.text("paper.abstract"), isExpanded: $showAbstract) {
                    TextEditor(text: Binding(get: { pdfAbstract }, set: { pdfAbstract = $0; abstractEdited = true }))
                        .font(.body).frame(height: 140).padding(6)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(Strings.text("paper.abstract"))
                }.font(.callout)
                if !showAbstract && !pdfAbstract.isEmpty {
                    Text(pdfAbstract).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Button { showFilePicker = true } label: {
                    VStack(spacing: 12) {
                        if inspectingPDF { ProgressView() }
                        else { Image(systemName: "doc.badge.plus").font(.system(size: 32)).foregroundStyle(.tint) }
                        Text(Strings.text("import.choosePDF")).font(.headline)
                        Text(Strings.text("import.pdfHint")).font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 150)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(inspectingPDF)
            }
            Text(Strings.text("import.pdfCopyHint")).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(addingPDF)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL, !addingPDF else { return false }
            selectPDF(url); return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func selectPDF(_ url: URL) {
        selectedURL = url; metadataRequest = UUID()
    }

    private func addPDF() {
        guard let url = selectedURL, metadata != nil else { return }
        addingPDF = true; error = nil
        let draft = PaperDraft(title: pdfTitle, authors: pdfAuthors.components(separatedBy: .newlines), abstract: pdfAbstract)
        let courses = Set(destination.map { [$0] } ?? [])
        localTask = Task {
            defer { addingPDF = false; localTask = nil }
            do {
                let id = try await pdfs.importLocalPDF(from: url, draft: draft, courseIDs: courses)
                onImported(id); dismiss()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private var destinationPicker: some View {
        Picker(Strings.text("import.destination"), selection: $destination) {
            Text(Strings.text("sidebar.all")).tag(Optional<UUID>.none)
            ForEach(repository.courses, id: \.id) { Text($0.name).tag(Optional($0.id)) }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !activeBatches.isEmpty {
                ProgressView(value: Double(jobs.filter { ![.pending, .inProgress].contains($0.state) }.count), total: Double(max(1, jobs.count)))
                Text(Strings.text("import.closeHint")).font(.caption).foregroundStyle(.secondary)
            }
            if jobs.isEmpty { ContentUnavailableView(Strings.text("import.empty"), systemImage: "tray") }
            else {
                List {
                    ForEach(Array(jobs.reversed().prefix(historyLimit)), id: \.id) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: job.state == .completed ? "checkmark.circle.fill" : "doc.text")
                                    .foregroundStyle(job.state == .completed ? Color.green : Color.secondary)
                                Text(job.identifier?.canonical ?? job.input).lineLimit(1).textSelection(.enabled)
                                Spacer()
                                Text(job.state.localizedName).font(.caption).foregroundStyle(.secondary)
                            }
                            if let message = job.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(.vertical, 6)
                    }
                    if jobs.count > historyLimit { Button(Strings.text("import.moreHistory")) { historyLimit += 100 } }
                }.listStyle(.inset).frame(height: 260)
            }
            HStack {
                if batch != nil { Button(Strings.text("import.showAll")) { batch = nil }.buttonStyle(.link) }
                Spacer()
                if !activeBatches.isEmpty {
                    Button(Strings.text("action.cancel")) { perform { for id in activeBatches { try coordinator.cancel(batchID: id) } } }
                }
                if !retryIDs.isEmpty {
                    Button(Strings.text("action.retry")) {
                        perform { try coordinator.resume(ids: retryIDs, destinationCourseID: destination, assignExisting: assignExisting, refreshMetadata: refreshMetadata) }
                    }.disabled(coordinator.isRunning)
                }
            }
            if !retryIDs.isEmpty {
                DisclosureGroup(Strings.text("action.options")) {
                    VStack(alignment: .leading, spacing: 10) {
                        destinationPicker
                        Toggle(Strings.text("import.assignExisting"), isOn: $assignExisting)
                        Toggle(Strings.text("import.refresh"), isOn: $refreshMetadata)
                    }.padding(.top, 10)
                }.font(.callout)
            }
        }
    }
    private func enqueue() {
        perform {
            batch = try coordinator.enqueue(text: input, destinationCourseID: destination, assignExisting: assignExisting, refreshMetadata: refreshMetadata)
            showingActivity = true
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
