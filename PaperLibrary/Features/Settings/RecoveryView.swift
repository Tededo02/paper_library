import AppKit
import PaperLibraryCore
import PaperLibrarySupport
import SwiftUI

struct RecoveryView: View {
    let state: ApplicationState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(Strings.text("recovery.title"), systemImage: "exclamationmark.triangle").font(.title)
            Text(Strings.text("recovery.message"))
            if let failure = state.startupFailure {
                Text(failure.reason).textSelection(.enabled).foregroundStyle(.secondary)
                LabeledContent(Strings.text("recovery.store")) { Text(failure.storeURL.path).textSelection(.enabled) }
                if let backup = failure.backupURL {
                    LabeledContent(Strings.text("recovery.backup")) { Text(backup.path).textSelection(.enabled) }
                }
                HStack {
                    Button(Strings.text("action.showFinder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([failure.storeURL.deletingLastPathComponent()])
                    }
                    Button(Strings.text("action.retry")) { state.openLibrary() }
                }
            }
        }.padding(40).frame(maxWidth: 800)
    }
}
