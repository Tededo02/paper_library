import AppKit
import Observation
import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

@MainActor
@Observable
final class ApplicationState {
    var repository: LibraryRepository?
    var startupFailure: StoreStartupFailure?
    var message: String?
    var showAddPaper = false
    var showImport = false
    var showImportHistory = false
    var imports: ImportCoordinator?
    var pdfs: PDFCoordinator?
    var ai: AnalysisCoordinator?
    var readerRecordID: UUID?
    var selectedPaperID: UUID?
    var searchRequest = 0
    var pendingNotes: [UUID: String] = [:]

    init() { openLibrary() }

    func openLibrary() {
        do {
            let configuration = try StorageConfiguration.forLaunch()
            let store = try LibraryStore.open(configuration: configuration)
            do {
                let repository = try LibraryRepository(store: store)
                self.repository = repository
                imports = ImportCoordinator(repository: repository, provider: ArxivClient.local(cooldownURL: configuration.arxivCooldownURL))
                pdfs = PDFCoordinator.local(repository: repository)
                ai = AnalysisCoordinator(repository: repository)
                let megabytes = UserDefaults.standard.object(forKey: "pdf.maximumMegabytes") as? Int ?? 100
                pdfs?.limits = PDFLimits(maximumBytes: Int64(max(10, min(500, megabytes))) * 1_048_576)
            }
            catch { throw StoreStartupFailure(storeURL: configuration.storeURL, backupURL: store.startupBackup, reason: error.localizedDescription) }
            startupFailure = nil
        } catch let failure as StoreStartupFailure {
            startupFailure = failure
        } catch {
            let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(StorageConfiguration.bundleIdentifier)/Store/Library.store")
            startupFailure = StoreStartupFailure(storeURL: fallback, backupURL: nil, reason: error.localizedDescription)
        }
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { message = error.localizedDescription }
    }

    func saveNotes(paperID: UUID, value: String) {
        pendingNotes[paperID] = value
        do {
            guard let repository else { throw LibraryError.missingRecord }
            try repository.saveNotes(paperID: paperID, notes: value)
            pendingNotes.removeValue(forKey: paperID)
        } catch { message = error.localizedDescription }
    }

    func flushPendingNotes() -> Bool {
        for (id, notes) in pendingNotes { saveNotes(paperID: id, value: notes) }
        return pendingNotes.isEmpty
    }

    func prepareForTermination() -> Bool {
        guard flushPendingNotes() else { return false }
        do { try imports?.prepareForTermination(); try pdfs?.prepareForTermination(); try ai?.prepareForTermination(); return true }
        catch { message = error.localizedDescription; return false }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: ApplicationState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.prepareForTermination() == false ? .terminateCancel : .terminateNow
    }
}

@main
struct PaperLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = ApplicationState()

    var body: some Scene {
        WindowGroup(Strings.text("app.name"), id: "library") {
            Group {
                if let repository = state.repository {
                    LibraryView(state: state, repository: repository)
                } else {
                    RecoveryView(state: state)
                }
            }
            .environment(\.locale, Strings.locale)
            .frame(minWidth: 1000, minHeight: 640)
            .onAppear { delegate.state = state }
            .alert(Strings.text("error.title"), isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
                Button(Strings.text("action.done"), role: .cancel) { state.message = nil }
            } message: { Text(state.message ?? "") }
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(Strings.text("import.title")) { state.showImportHistory = false; state.showImport = true }
                    .keyboardShortcut("n")
                    .disabled(state.imports == nil)
                Button(Strings.text("paper.new")) { state.showAddPaper = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(state.repository == nil)
            }
            CommandGroup(after: .textEditing) {
                Button(Strings.text("search.prompt")) { state.searchRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(state.repository == nil)
            }
            CommandGroup(after: .newItem) {
                Button(Strings.text("pdf.open")) {
                    if let id = state.selectedPaperID, let record = state.repository?.pdfRecords(paperID: id).first { state.readerRecordID = record.id }
                    else { state.message = Strings.text("pdf.downloadFirst") }
                }.keyboardShortcut("o").disabled(state.selectedPaperID == nil)
            }
        }

        Settings {
            Group {
                if let repository = state.repository { DiagnosticsView(repository: repository, pdfs: state.pdfs, ai: state.ai) }
                else { RecoveryView(state: state) }
            }
            .environment(\.locale, Strings.locale)
        }
    }
}
