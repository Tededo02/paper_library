import Foundation
import PaperLibrarySupport
import SwiftData

@MainActor
public final class LibraryStore {
    public let configuration: StorageConfiguration
    public let startupBackup: URL?
    private var modelContainer: ModelContainer?
    private let fileAccess: StoreFileAccess

    public var container: ModelContainer { modelContainer! }

    private init(configuration: StorageConfiguration, fileAccess: StoreFileAccess, container: ModelContainer) {
        self.configuration = configuration
        self.fileAccess = fileAccess
        self.modelContainer = container
        self.startupBackup = fileAccess.startupBackup
    }

    deinit { modelContainer = nil }

    public static func open(configuration: StorageConfiguration) throws -> LibraryStore {
        var backup: URL?
        do {
            let access = try StoreFileAccess(configuration: configuration, applicationSchema: LibraryMigrationPlan.currentVersion)
            backup = access.startupBackup
            let schema = Schema(versionedSchema: LibrarySchemaV5.self)
            let settings = ModelConfiguration("PaperLibrary", schema: schema, url: configuration.storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, migrationPlan: LibraryMigrationPlan.self, configurations: [settings])
            container.mainContext.autosaveEnabled = false
            return LibraryStore(configuration: configuration, fileAccess: access, container: container)
        } catch {
            throw StoreStartupFailure(storeURL: configuration.storeURL, backupURL: backup, reason: error.localizedDescription)
        }
    }
}
