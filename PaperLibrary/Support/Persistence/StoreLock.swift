import Darwin
import Foundation

final class StoreLock: @unchecked Sendable {
    private let descriptor: Int32

    init(root: URL) throws {
        let file = root.appendingPathComponent("library.lock")
        descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LibraryError.unsafeStorage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw LibraryError.storeAlreadyOpen
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
