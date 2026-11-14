import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct AISettingsView: View {
    let repository: LibraryRepository
    let ai: AnalysisCoordinator
    @AppStorage("ai.language") private var language = "en"
    @AppStorage("ai.defaultProfile") private var defaultProfile = BuiltinAnalysisProfiles.quickID.uuidString
    @State private var selectedProfile: UUID?
    @State private var name = ""
    @State private var instructions = ""
    @State private var error: String?
    var body: some View {
        Section(Strings.text("ai.title")) {
            if ai.availability != .available { Text(ai.availability.message).font(.callout).foregroundStyle(.secondary) }
            Picker(Strings.text("ai.language"), selection: $language) {
                Text(Strings.text("ai.language.en")).tag("en")
                Text(Strings.text("ai.language.it")).tag("it")
            }
            Picker(Strings.text("ai.defaultProfile"), selection: $defaultProfile) {
                ForEach(repository.profiles, id: \.id) { Text($0.displayName).tag($0.id.uuidString) }
            }
            DisclosureGroup(Strings.text("ai.configureProfiles")) {
                Button(Strings.text("ai.refreshAvailability")) { Task { await ai.refreshAvailability(language: language) } }
                Picker(Strings.text("ai.profile"), selection: $selectedProfile) {
                    Text(Strings.text("ai.newProfile")).tag(nil as UUID?)
                    ForEach(repository.profiles, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                }.onChange(of: selectedProfile) {
                    let profile = repository.profiles.first { $0.id == selectedProfile }
                    name = profile?.displayName ?? ""; instructions = profile?.instructions ?? ""
                }
                TextField(Strings.text("ai.profileName"), text: $name)
                Text(Strings.text("ai.profileHint")).font(.caption)
                TextEditor(text: $instructions).frame(minHeight: 100).accessibilityLabel(Strings.text("ai.profileInstructions"))
                if let error { Text(error).foregroundStyle(.red) }
                Button(Strings.text("action.save")) {
                    do { try repository.saveProfile(id: selectedProfile, name: name, instructions: instructions); error = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.task(id: language) { await ai.refreshAvailability(language: language) }
    }
}
