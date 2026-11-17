import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct PaperDetailView: View {
    let state: ApplicationState
    let repository: LibraryRepository
    let paper: Paper
    let edit: () -> Void
    @State private var tab = "overview"

    var body: some View {
        VStack(spacing: 0) {
            Picker(Strings.text("action.details"), selection: $tab) {
                Text(Strings.text("paper.overview")).tag("overview")
                Text(Strings.text("paper.notes")).tag("notes")
                Text(Strings.text("ai.title")).tag("summary")
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == "overview" { overview }
                    else if tab == "notes" { PaperNotesView(state: state, paper: paper) }
                    else if let ai = state.ai { AIControls(state: state, coordinator: ai, paper: paper) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(paper.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(paper.authors.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if paper.provider == "arxiv", let raw = paper.providerIdentifier, let identifier = try? ArxivIdentifier(raw) {
                    HStack {
                        Link("arXiv:\(identifier.canonical)", destination: identifier.canonicalURL)
                        if let date = paper.publicationDate {
                            Text(date, format: .dateTime.year()).foregroundStyle(.secondary)
                        }
                    }.font(.caption)
                } else if let raw = paper.doi, let identifier = try? DOIIdentifier(raw) {
                    HStack {
                        Link("DOI: \(identifier.canonical)", destination: identifier.canonicalURL)
                        if let date = paper.publicationDate { Text(date, format: .dateTime.year()).foregroundStyle(.secondary) }
                    }.font(.caption)
                }
            }
            HStack(spacing: 12) {
                Picker(Strings.text("paper.status"), selection: Binding(get: { paper.readingStatus }, set: { value in
                    state.perform { try repository.setReadingStatus(value, paperIDs: [paper.id]) }
                })) {
                    ForEach(ReadingStatus.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
                Button {
                    state.perform { try repository.setFavorite(!paper.isFavorite, paperIDs: [paper.id]) }
                } label: {
                    Image(systemName: paper.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(paper.isFavorite ? Color.yellow : Color.secondary)
                }.buttonStyle(.borderless)
                    .help(Strings.text(paper.isFavorite ? "paper.favoriteRemove" : "paper.favoriteAdd"))
                    .accessibilityLabel(Strings.text(paper.isFavorite ? "paper.favoriteRemove" : "paper.favoriteAdd"))
                Menu {
                    Button(Strings.text("paper.edit"), action: edit)
                    if !repository.courses.isEmpty {
                        Menu(Strings.text("paper.courses")) {
                            ForEach(repository.courses, id: \.id) { course in
                                Toggle(course.name, isOn: Binding(get: {
                                    repository.courseIDs(paperID: paper.id).contains(course.id)
                                }, set: { selected in
                                    state.perform {
                                        if selected { try repository.assign(paperIDs: [paper.id], to: course.id) }
                                        else { try repository.remove(paperIDs: [paper.id], from: course.id) }
                                    }
                                }))
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Strings.text("paper.actions")).accessibilityLabel(Strings.text("paper.actions"))
            }
            if let pdfs = state.pdfs { PDFControls(state: state, coordinator: pdfs, paper: paper) }
            Divider()
            if !paper.abstract.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Strings.text("paper.abstract")).font(.headline)
                    Text(paper.abstract).textSelection(.enabled).lineSpacing(3)
                }
            }
            let courses = repository.courses.filter { repository.courseIDs(paperID: paper.id).contains($0.id) }
            if !courses.isEmpty {
                Label(courses.map(\.name).joined(separator: ", "), systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if paper.doi != nil || paper.journalReference != nil {
                DisclosureGroup(Strings.text("paper.publication")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let journal = paper.journalReference { Text(journal) }
                        if let doi = paper.doi, !doi.isEmpty {
                            if let identifier = try? DOIIdentifier(doi) { Link("DOI: \(doi)", destination: identifier.canonicalURL) }
                            else { Text("DOI: \(doi)") }
                        }
                        if let version = paper.resolvedVersion { Text("arXiv v\(version)") }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                }.font(.callout)
            }
        }
    }
}

struct PaperNotesView: View {
    let state: ApplicationState
    let paper: Paper
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.text("paper.notes")).font(.headline)
            TextEditor(text: Binding(get: { state.pendingNotes[paper.id] ?? paper.notes }, set: {
                state.saveNotes(paperID: paper.id, value: $0)
            }))
            .font(.body).scrollContentBackground(.hidden).frame(minHeight: 320)
            .padding(8).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(Strings.text("paper.notes"))
            if let draft = state.pendingNotes[paper.id] {
                HStack {
                    Text(Strings.text("paper.unsaved")).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(Strings.text("paper.saveNotes")) { state.saveNotes(paperID: paper.id, value: draft) }
                }
            }
        }
    }
}
