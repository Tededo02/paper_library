import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct PaperForm: View {
    let repository: LibraryRepository
    let paper: Paper?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var authors: String
    @State private var abstract: String
    @State private var doi: String
    @State private var courses: Set<UUID>
    @State private var error: String?

    init(repository: LibraryRepository, paper: Paper?, destinationCourse: UUID?) {
        self.repository = repository
        self.paper = paper
        _title = State(initialValue: paper?.title ?? "")
        _authors = State(initialValue: paper?.authors.joined(separator: "\n") ?? "")
        _abstract = State(initialValue: paper?.abstract ?? "")
        _doi = State(initialValue: paper?.doi ?? "")
        _courses = State(initialValue: destinationCourse.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.text(paper == nil ? "paper.new" : "paper.edit")).font(.title2)
            Form {
                TextField(Strings.text("paper.title"), text: $title, axis: .vertical).lineLimit(2...3)
                LabeledContent(Strings.text("paper.authors")) {
                    TextField(Strings.text("paper.authorsHint"), text: $authors, axis: .vertical).lineLimit(3...5)
                }
                TextField(Strings.text("paper.doi"), text: $doi)
                LabeledContent(Strings.text("paper.abstract")) {
                    TextEditor(text: $abstract).font(.body).frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        .accessibilityLabel(Strings.text("paper.abstract"))
                }
                if paper == nil && !repository.courses.isEmpty {
                    Section(Strings.text("paper.courses")) {
                        ForEach(repository.courses, id: \.id) { course in
                            Toggle(course.name, isOn: Binding(get: { courses.contains(course.id) }, set: { value in
                                if value { courses.insert(course.id) } else { courses.remove(course.id) }
                            }))
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(Strings.text("action.cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.text("action.save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620)
    }

    private func save() {
        do {
            let draft = PaperDraft(title: title, authors: authors.components(separatedBy: .newlines), abstract: abstract, doi: doi)
            if let paper { try repository.updateMetadata(paperID: paper.id, draft: draft) }
            else { try repository.addPaper(draft, courseIDs: courses) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
