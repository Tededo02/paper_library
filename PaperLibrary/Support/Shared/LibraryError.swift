import Foundation

public enum LibraryError: LocalizedError {
    case invalidInput
    case missingRecord
    case duplicateRecord
    case storeAlreadyOpen
    case unsafeStorage
    case inconsistentStore
    case newerSchema

    public var errorDescription: String? {
        switch self {
        case .invalidInput: Strings.text("error.invalidInput")
        case .missingRecord: Strings.text("error.missingRecord")
        case .duplicateRecord: Strings.text("error.duplicateRecord")
        case .storeAlreadyOpen: Strings.text("error.storeAlreadyOpen")
        case .unsafeStorage: Strings.text("error.unsafeStorage")
        case .inconsistentStore: Strings.text("error.inconsistentStore")
        case .newerSchema: Strings.text("error.newerSchema")
        }
    }
}
