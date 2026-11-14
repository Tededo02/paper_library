import AppKit
import PDFKit
import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI


private struct NativePDFView: NSViewRepresentable {
    let model: PDFReaderSession
    func makeNSView(context: Context) -> LocalPDFView { model.view }
    func updateNSView(_ nsView: LocalPDFView, context: Context) {}
}

struct PDFReaderView: View {
    let state: ApplicationState
    let repository: LibraryRepository
    let pdfs: PDFCoordinator
    let record: PDFDocumentRecord
    @Environment(\.dismiss) private var dismiss
    @State private var model = PDFReaderSession()
    @State private var error: String?
    @State private var loading = true
    @State private var sidebarVisible = false
    @State private var tab = "notes"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(repository.paper(id: record.paperID)?.title ?? "PDF").font(.headline).lineLimit(1).frame(maxWidth: 250, alignment: .leading)
                Spacer()
                Button { model.go(to: model.page - 1) } label: { Image(systemName: "chevron.left") }
                    .help(Strings.text("pdf.previous")).accessibilityLabel(Strings.text("pdf.previous"))
                TextField(Strings.text("pdf.page"), value: $model.page, format: .number).frame(width: 40).onSubmit { model.go(to: model.page) }
                Text("/ \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
                Button { model.go(to: model.page + 1) } label: { Image(systemName: "chevron.right") }
                    .help(Strings.text("pdf.next")).accessibilityLabel(Strings.text("pdf.next"))
                Divider().frame(height: 18)
                Menu {
                    Button(Strings.text("pdf.zoomOut")) { model.view.zoomOut(nil) }
                    Button(Strings.text("pdf.zoomIn")) { model.view.zoomIn(nil) }
                    if !model.outline.isEmpty {
                        Menu(Strings.text("pdf.contents")) {
                            ForEach(model.outline.indices, id: \.self) { index in Button(model.outline[index].0) { model.go(to: model.outline[index].1) } }
                        }
                    }
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Strings.text("pdf.viewOptions")).accessibilityLabel(Strings.text("pdf.viewOptions"))
                Spacer()
                TextField(Strings.text("pdf.search"), text: $model.search).textFieldStyle(.roundedBorder).frame(width: 170).onSubmit { model.find() }
                if model.matches > 0 {
                    Button { model.nextMatch() } label: { Image(systemName: "chevron.down") }
                        .help(Strings.text("pdf.nextMatch")).accessibilityLabel(Strings.text("pdf.nextMatch"))
                    Text("\(model.matches)").font(.caption).foregroundStyle(.secondary)
                }
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help(Strings.text("paper.notes")).accessibilityLabel(Strings.text("paper.notes"))
                Button(Strings.text("action.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if let error { ContentUnavailableView(Strings.text("error.title"), systemImage: "exclamationmark.triangle", description: Text(error)) }
            else {
                HSplitView {
                    NativePDFView(model: model).frame(minWidth: 600)
                    if sidebarVisible, let paper = repository.paper(id: record.paperID) {
                        VStack(spacing: 0) {
                            Picker(Strings.text("action.details"), selection: $tab) {
                                Text(Strings.text("paper.notes")).tag("notes")
                                Text(Strings.text("ai.title")).tag("summary")
                            }.pickerStyle(.segmented).labelsHidden().padding()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if tab == "notes" { PaperNotesView(state: state, paper: paper) }
                                    else if let ai = state.ai { AIControls(state: state, coordinator: ai, paper: paper) }
                                }.padding()
                            }
                        }.frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .frame(width: 1100, height: 760)
        .task {
            do {
                let url = try await pdfs.files.verifiedURL(record.fileReference)
                try Task.checkCancellation()
                model.onPage = { page in state.perform { try repository.saveReadingPosition(recordID: record.id, page: page) } }
                try model.open(url: url, page: record.lastReadPage)
            } catch { self.error = error.localizedDescription }
            loading = false
        }
        .onDisappear { model.close() }
        .onChange(of: record.isRemoved) { if record.isRemoved { dismiss() } }
    }
}
