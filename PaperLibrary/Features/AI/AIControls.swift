import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct AIControls: View {
    let state: ApplicationState
    let coordinator: AnalysisCoordinator
    let paper: Paper
    @AppStorage("ai.language") private var language = "en"
    @AppStorage("ai.defaultProfile") private var defaultProfile = BuiltinAnalysisProfiles.quickID.uuidString
    @State private var records: [AIAnalysis] = []
    @State private var editing: AIAnalysis?
    @State private var topicsText = ""
    @State private var topicEditing = false
    @State private var showOptions = false
    @State private var confirmRegeneration = false
    private var repository: LibraryRepository { coordinator.repository }
    private var profile: AnalysisProfile? {
        repository.profiles.first { $0.id.uuidString == defaultProfile }
        ?? repository.profiles.first { $0.id == BuiltinAnalysisProfiles.quickID }
        ?? repository.profiles.first
    }
    private var stylePosition: Binding<Double> {
        Binding(get: {
            Double(repository.profiles.firstIndex { $0.id == profile?.id } ?? 0)
        }, set: { value in
            let index = max(0, min(repository.profiles.count - 1, Int(value.rounded())))
            if repository.profiles.indices.contains(index) { defaultProfile = repository.profiles[index].id.uuidString }
        })
    }
    private var jobs: [AIProcessingJob] { repository.aiJobs.filter { $0.paperID == paper.id } }
    private var activeJob: AIProcessingJob? { jobs.last { [.pending, .inProgress].contains($0.state) } }
    private var latestIssue: AIProcessingJob? { jobs.last.flatMap { $0.state.canRetry ? $0 : nil } }
    private var canGenerate: Bool {
        activeJob == nil && coordinator.availability == .available &&
        profile != nil && (!paper.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repository.pdfRecords(paperID: paper.id).contains { $0.indexStatus == "chunksReady" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(Strings.text("ai.title")).font(.headline)
                Spacer()
                Button { showOptions.toggle() } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.plain)
                    .help(Strings.text("ai.options")).accessibilityLabel(Strings.text("ai.options"))
                    .popover(isPresented: $showOptions) { options }
            }
            if let latest = records.first {
                analysis(latest)
            } else if activeJob == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Strings.text(paper.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && repository.pdfRecords(paperID: paper.id).contains { $0.indexStatus == "noText" } ? "ai.noExtractedText" : "ai.emptyHint")).foregroundStyle(.secondary)
                    if latestIssue == nil {
                        Button { generate(confirm: false) } label: {
                            Label(Strings.text("ai.generate"), systemImage: "sparkles")
                        }.buttonStyle(.borderedProminent).disabled(!canGenerate)
                    }
                }
            }
            if let job = activeJob {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Strings.text("ai.generating")).font(.callout)
                        Spacer()
                        Button { state.perform { try coordinator.cancel(id: job.id) } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(Strings.text("action.cancel")).accessibilityLabel(Strings.text("action.cancel"))
                    }
                    ProgressView(value: job.progress)
                }
            } else if let job = latestIssue {
                Text(job.errorMessage ?? job.state.localizedName).font(.caption).foregroundStyle(.secondary)
                Button(Strings.text("action.retry")) { generate(confirm: false) }
                    .disabled(!canGenerate)
            }
            if coordinator.availability != .available {
                Text(coordinator.availability.message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = coordinator.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            let topics = repository.topicNames(paperID: paper.id)
            if !topics.isEmpty {
                Divider()
                Text(topics.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if records.count > 1 {
                DisclosureGroup(Strings.text("ai.history")) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(records.dropFirst()), id: \.id) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                analysis(record)
                                Button(Strings.text("ai.edit")) { editing = record }.font(.caption)
                            }
                            Divider()
                        }
                    }.padding(.top, 12)
                }.font(.callout)
            }
        }
        .task { load() }
        .task(id: language) { await coordinator.refreshAvailability(language: language) }
        .onChange(of: repository.analysisRevision) { load() }
        .confirmationDialog(Strings.text("ai.confirmRegeneration"), isPresented: $confirmRegeneration) {
            Button(Strings.text("ai.regenerate")) { generate(confirm: true) }
        } message: { Text(Strings.text("ai.confirmHint")) }
        .sheet(item: $editing) { AnalysisEditor(repository: repository, analysis: $0) }
        .sheet(isPresented: $topicEditing) {
            VStack(alignment: .leading, spacing: 16) {
                Text(Strings.text("ai.editTopics")).font(.title2)
                Text(Strings.text("ai.topicsHint")).font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $topicsText).frame(height: 180).accessibilityLabel(Strings.text("ai.topics"))
                HStack {
                    Spacer()
                    Button(Strings.text("action.cancel")) { topicEditing = false }.keyboardShortcut(.cancelAction)
                    Button(Strings.text("action.save")) {
                        do { try repository.replaceTopics(paperID: paper.id, names: topicsText.split(separator: "\n").map(String.init)); topicEditing = false }
                        catch { state.message = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 420)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(Strings.text("ai.profile")).font(.headline)
                    Spacer()
                    Text(profile?.displayName ?? "").foregroundStyle(.secondary)
                }
                Slider(value: stylePosition, in: 0...Double(max(1, repository.profiles.count - 1)), step: 1) {
                    Text(Strings.text("ai.profile"))
                }
                .labelsHidden()
                .disabled(repository.profiles.count < 2)
                .accessibilityValue(profile?.displayName ?? "")
                HStack(alignment: .top, spacing: 8) {
                    if repository.profiles.count <= 4 {
                        ForEach(repository.profiles, id: \.id) { item in
                            Text(item.displayName).frame(maxWidth: .infinity)
                        }
                    } else {
                        Text(repository.profiles.first?.displayName ?? "")
                        Spacer()
                        Text(repository.profiles.last?.displayName ?? "")
                    }
                }.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let latest = records.first {
                    Button(Strings.text("ai.regenerate")) { showOptions = false; generate(confirm: false) }.disabled(!canGenerate)
                    Button(Strings.text("ai.edit")) { showOptions = false; editing = latest }
                }
                Button(Strings.text("ai.editTopics")) {
                    showOptions = false
                    topicsText = repository.topicNames(paperID: paper.id).joined(separator: "\n"); topicEditing = true
                }
                Button(Strings.text("ai.refreshAvailability")) {
                    showOptions = false
                    Task { await coordinator.refreshAvailability(language: language) }
                }
            }.buttonStyle(.link)
            Text(Strings.text("ai.localHint")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Strings.text("action.done")) { showOptions = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360)
    }

    private func load() { do { records = try repository.analyses(paperID: paper.id) } catch { state.message = error.localizedDescription } }
    private func generate(confirm: Bool) {
        do {
            guard let profile else { throw LibraryError.missingRecord }
            try coordinator.summarize(paperID: paper.id, profileID: profile.id, language: language, confirmEdited: confirm)
        } catch AnalysisError.edited { confirmRegeneration = true }
        catch { state.message = error.localizedDescription }
    }

    @ViewBuilder private func analysis(_ record: AIAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Strings.text("ai.source.\(record.sourceKind)"))\(paper.provider == "arxiv" ? record.sourceVersion.map { " v\($0)" } ?? "" : "") · \(record.generatedAt.formatted(.dateTime.year().month().day().locale(Strings.locale)))")
                .font(.caption).foregroundStyle(.secondary)
            if record.sourceKind == "pdf" && record.promptVersion == "paper-analysis-4" {
                Text(Strings.text("ai.pdfSectionsHint")).font(.caption).foregroundStyle(.secondary)
            }
            if record.incomplete {
                Label(Strings.text("ai.incomplete"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if record.userEdited {
                Text(record.userContent).textSelection(.enabled).lineSpacing(3)
                Text(Strings.text("ai.userEdited")).font(.caption).foregroundStyle(.secondary)
            }
            if let output = try? JSONDecoder().decode(AnalysisOutput.self, from: Data(record.contentJSON.utf8)) {
                if !record.userEdited { Text(AnalysisValidation.readableProse(output.summary.text)).textSelection(.enabled).lineSpacing(3) }
                DisclosureGroup(Strings.text(record.userEdited ? "ai.original" : "ai.result")) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(AnalysisField.allCases.filter { field in output.points.contains { $0.field == field } }, id: \.self) { field in
                            let points = output.points.filter { $0.field == field }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(field.label).font(.subheadline.bold())
                                ForEach(points.indices, id: \.self) { index in
                                    Text(AnalysisValidation.readableProse(points[index].text)).textSelection(.enabled)
                                    DisclosureGroup(Strings.text("ai.evidence")) {
                                        if let originalIndex = output.points.firstIndex(of: points[index]),
                                           let citations = try? JSONDecoder().decode([AnalysisCitation].self, from: Data(record.provenanceJSON.utf8)) {
                                            let sources = citations.filter { $0.pointIndex == originalIndex }
                                            ForEach(sources.indices, id: \.self) { sourceIndex in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(sources[sourceIndex].quote).textSelection(.enabled)
                                                    if let page = sources[sourceIndex].page {
                                                        Text("\(Strings.text("pdf.page")) \(page)").foregroundStyle(.secondary)
                                                    }
                                                }.padding(.vertical, 4)
                                            }
                                        } else {
                                            ForEach(points[index].quotes, id: \.self) { Text($0).textSelection(.enabled) }
                                        }
                                    }.font(.caption)
                                }
                            }
                        }
                        if !output.interpretation.isEmpty {
                            Text(Strings.text("ai.interpretation")).font(.subheadline.bold())
                            Text(output.interpretation).textSelection(.enabled)
                        }
                        if !output.topics.isEmpty {
                            Text("\(Strings.text("ai.suggestedTopics")): \(output.topics.joined(separator: ", "))").font(.caption)
                        }
                        Text(BuiltinAnalysisProfiles.displayName(id: record.profileID, name: record.profileName) + " · " + record.language.uppercased()).font(.caption).foregroundStyle(.secondary)
                        Text(Strings.text("ai.reviewHint")).font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }.font(.callout)
            }
        }
    }
}

private struct AnalysisEditor: View {
    let repository: LibraryRepository
    let analysis: AIAnalysis
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.text("ai.edit")).font(.title2)
            TextEditor(text: $text).frame(minHeight: 300).accessibilityLabel(Strings.text("ai.edit"))
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(Strings.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(Strings.text("action.save")) {
                    do { try repository.editAnalysis(id: analysis.id, text: text); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 650, height: 460)
        .onAppear { text = analysis.userEdited ? analysis.userContent : (try? JSONDecoder().decode(AnalysisOutput.self, from: Data(analysis.contentJSON.utf8)))?.plainText ?? "" }
    }
}
