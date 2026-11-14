import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

enum CoursePalette {
    static let names = ["blue", "green", "orange", "purple", "red"]
    static func color(_ name: String?) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "purple": .purple
        case "red": .red
        default: .blue
        }
    }
}

struct CourseForm: View {
    let repository: LibraryRepository
    let course: Course?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var color: String
    @State private var error: String?

    init(repository: LibraryRepository, course: Course?) {
        self.repository = repository
        self.course = course
        _name = State(initialValue: course?.name ?? "")
        _description = State(initialValue: course?.courseDescription ?? "")
        _color = State(initialValue: course?.color ?? "blue")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.text(course == nil ? "course.new" : "course.edit")).font(.title2)
            Form {
                TextField(Strings.text("course.name"), text: $name)
                TextField(Strings.text("course.description"), text: $description, axis: .vertical).lineLimit(3...6)
                Picker(Strings.text("course.color"), selection: $color) {
                    ForEach(CoursePalette.names, id: \.self) { color in
                        Text(Strings.text("color.\(color)")).tag(color)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(Strings.text("action.cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Strings.text("action.save")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }

    private func save() {
        do {
            if let course { try repository.updateCourse(id: course.id, name: name, description: description, color: color) }
            else { try repository.addCourse(name: name, description: description, color: color) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
