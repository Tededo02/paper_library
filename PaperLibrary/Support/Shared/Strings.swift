import Foundation

public enum Strings {
    public static let locale = Locale(identifier: "en")

    public static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, value: key, comment: "Paper Library interface")
    }
}
