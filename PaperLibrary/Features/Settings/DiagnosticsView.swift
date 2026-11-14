import AppKit
import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct DiagnosticsView: View {
    let repository: LibraryRepository
    var pdfs: PDFCoordinator? = nil
    var ai: AnalysisCoordinator? = nil
    @AppStorage("pdf.maximumMegabytes") private var maximumMegabytes = 100

    var body: some View {
        Form {
            if let ai { AISettingsView(repository: repository, ai: ai) }
            Section(Strings.text("settings.storage")) {
                LabeledContent(Strings.text("settings.papers"), value: "\(repository.papers.count)")
                LabeledContent(Strings.text("settings.pdfSize"), value: repository.pdfRecords.filter { !$0.isRemoved }.reduce(Int64(0)) { $0 + $1.fileSize }.formatted(.byteCount(style: .file).locale(Strings.locale)))
                Button(Strings.text("settings.openLibrary")) {
                    NSWorkspace.shared.activateFileViewerSelecting([repository.store.configuration.storeURL])
                }
                DisclosureGroup(Strings.text("action.advanced")) {
                    Stepper("\(Strings.text("settings.pdfLimit")): \(maximumMegabytes) MB", value: $maximumMegabytes, in: 10...500, step: 10)
                        .onChange(of: maximumMegabytes) { pdfs?.limits = PDFLimits(maximumBytes: Int64(maximumMegabytes) * 1_048_576) }
                    LabeledContent(Strings.text("settings.mode"), value: Strings.text("settings.mode.\(repository.store.configuration.mode.rawValue)"))
                    LabeledContent(Strings.text("settings.schema"), value: LibraryMigrationPlan.currentVersion)
                    Text(repository.store.configuration.storeURL.path).font(.caption).textSelection(.enabled)
                    LabeledContent(Strings.text("settings.backup")) {
                        Text(repository.store.startupBackup?.path ?? Strings.text("settings.noBackup")).font(.caption).textSelection(.enabled)
                    }
                }
            }
            Section {
                Label(Strings.text("settings.privacyShort"), systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 580, height: 590)
    }
}
