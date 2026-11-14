import Darwin
import Foundation
import PaperLibrarySupport

final class ArxivProcessPermit: @unchecked Sendable {
    private let descriptor: Int32

    init(stateURL: URL) throws {
        let parent = stateURL.deletingLastPathComponent()
        let manager = FileManager.default
        if manager.fileExists(atPath: parent.path) {
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryError.unsafeStorage }
        } else {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        descriptor = Darwin.open(stateURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.unsafeStorage }
    }

    func tryAcquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw LibraryError.unsafeStorage }
        return false
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
