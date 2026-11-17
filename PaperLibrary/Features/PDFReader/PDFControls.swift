import AppKit
import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI
import UniformTypeIdentifiers

struct PDFControls: View {
    let state: ApplicationState
    let coordinator: PDFCoordinator
    let paper: Paper
    @State private var removing: PDFDocumentRecord?
    @State private var showAttachmentPicker = false
    private var repository: LibraryRepository { coordinator.repository }
    private var records: [PDFDocumentRecord] { repository.pdfRecords(paperID: paper.id) }
    private var jobs: [PDFProcessingJob] { repository.pdfJobs.filter { $0.paperID == paper.id } }
    private var activeJob: PDFProcessingJob? { jobs.last { [.pending, .inProgress].contains($0.state) } }
    private var latestIssue: PDFProcessingJob? { jobs.last.flatMap { $0.state.canRetry ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let latest = records.first {
                    Button { state.readerRecordID = latest.id } label: {
                        Label(Strings.text("pdf.open"), systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Menu {
                        recordActions(latest)
                        if records.count > 1 {
                            Menu(Strings.text("pdf.otherVersions")) {
                                ForEach(Array(records.dropFirst()), id: \.id) { record in
                                    Menu("v\(record.version)") {
                                        Button(Strings.text("pdf.open")) { state.readerRecordID = record.id }
                                        recordActions(record)
                                    }
                                }
                            }
                        }
                        if paper.provider == "arxiv", let version = paper.resolvedVersion, !records.contains(where: { $0.version == version }) {
                            Divider()
                            Button(Strings.text("pdf.downloadLatest")) { state.perform { try coordinator.enqueue(paperID: paper.id) } }
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(Strings.text("pdf.actions")).accessibilityLabel(Strings.text("pdf.actions"))
                } else if paper.pdfDownloadURL != nil && activeJob == nil && latestIssue == nil {
                    Button { state.perform { try coordinator.enqueue(paperID: paper.id) } } label: {
                        Label(Strings.text("pdf.download"), systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                } else if paper.provider == "doi", let url = paper.publisherPDFURL, activeJob == nil {
                    Link(destination: url) {
                        Label(Strings.text("pdf.getFromPublisher"), systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            if paper.provider == "doi" {
                if records.isEmpty && paper.pdfSourceURL == nil {
                    Text(Strings.text("pdf.publisherAccessHint")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if (paper.pdfDownloadURL != nil || !records.isEmpty), let url = paper.publisherPDFURL {
                        Link(Strings.text("pdf.getFromPublisher"), destination: url).font(.caption)
                    }
                    Button(Strings.text("pdf.attach")) { showAttachmentPicker = true }
                        .font(.caption).disabled(coordinator.isImporting)
                    if coordinator.isImporting { ProgressView().controlSize(.small) }
                }
            }
            if let job = activeJob {
                HStack(spacing: 8) {
                    if let total = job.totalBytes, total > 0 {
                        ProgressView(value: Double(job.bytesReceived), total: Double(total)).frame(maxWidth: 100)
                    } else { ProgressView().controlSize(.small) }
                    Text(Strings.text(job.operation == "download" ? "pdf.downloading" : "pdf.preparing")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.perform { try coordinator.cancel(id: job.id) } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(Strings.text("action.cancel")).accessibilityLabel(Strings.text("action.cancel"))
                }
            } else if let job = latestIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.errorMessage ?? job.state.localizedName).font(.caption).foregroundStyle(.secondary)
                    Button(Strings.text("action.retry")) { state.perform { try coordinator.retry(id: job.id) } }
                        .font(.caption)
                }
            }
            if let error = coordinator.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $showAttachmentPicker, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let draft = PaperDraft(title: paper.title, authors: paper.authors, abstract: paper.abstract, doi: paper.doi)
                        _ = try await coordinator.importLocalPDF(from: url, draft: draft, attachingTo: paper.id)
                    } catch { state.message = error.localizedDescription }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { state.message = error.localizedDescription }
            }
        }
        .confirmationDialog(Strings.text("pdf.remove"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { record in
            Button(Strings.text("action.delete"), role: .destructive) {
                state.readerRecordID = nil
                Task { do { try await coordinator.remove(recordID: record.id) } catch { state.message = error.localizedDescription } }
            }
        } message: { _ in Text(Strings.text("pdf.removeHint")) }
    }

    @ViewBuilder private func recordActions(_ record: PDFDocumentRecord) -> some View {
        Text((paper.provider == "arxiv" ? "v\(record.version) · " : "") + record.fileSize.formatted(.byteCount(style: .file).locale(Strings.locale)))
        Button(Strings.text("pdf.preview")) { external(record, preview: true) }
        Button(Strings.text("action.showFinder")) { external(record, preview: false) }
        Menu(Strings.text("action.advanced")) {
            Text(Strings.text("pdf.extraction.\(record.extractionStatus)"))
            Button(Strings.text("pdf.extract")) { state.perform { try coordinator.enqueue(paperID: paper.id, operation: "extract", version: record.version) } }
            if paper.pdfDownloadURL != nil {
                Button(Strings.text("pdf.redownload")) { state.perform { try coordinator.enqueue(paperID: paper.id, version: record.version) } }
            }
        }
        Divider()
        Button(Strings.text("pdf.remove"), role: .destructive) { removing = record }
    }

    private func external(_ record: PDFDocumentRecord, preview: Bool) {
        Task {
            do {
                let url: URL
                if preview { url = try await coordinator.files.verifiedURL(record.fileReference) }
                else { url = try await coordinator.files.existingURL(relativePath: record.relativePath) }
                if preview {
                    guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { throw PDFLibraryError.missing }
                    NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        if let error { Task { @MainActor in state.message = error.localizedDescription } }
                    }
                } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch { state.message = error.localizedDescription }
        }
    }
}
