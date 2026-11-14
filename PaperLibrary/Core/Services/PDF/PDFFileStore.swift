import CryptoKit
import Foundation
import PDFKit
import PaperLibrarySupport

public actor PDFFileStore {
    public let configuration: StorageConfiguration
    private var prepared = false
    public init(configuration: StorageConfiguration) { self.configuration = configuration }

    public func prepare() throws {
        guard !prepared else { return }
        try safeDirectory(configuration.pdfDirectory)
        let staging = configuration.pdfDirectory.appendingPathComponent(".staging", isDirectory: true)
        try safeDirectory(staging)
        for file in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "part", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            try FileManager.default.removeItem(at: file)
        }
        prepared = true
    }

    public func stagingURL(jobID: UUID) throws -> URL {
        try prepare()
        let url = configuration.pdfDirectory.appendingPathComponent(".staging/\(jobID.uuidString).part")
        try validateStaged(url)
        return url
    }

    public func validateStaged(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == configuration.pdfDirectory.appendingPathComponent(".staging").standardizedFileURL,
              url.pathExtension == "part", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { throw PDFLibraryError.unsafePath }
        try safeDirectory(configuration.pdfDirectory)
        try safeDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw PDFLibraryError.unsafePath }
        }
    }

    public func checkSpace(required: Int64, reserve: Int64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: configuration.pdfDirectory.path)
        guard required >= 0, reserve >= 0, let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              free >= required, reserve <= free - required else { throw PDFLibraryError.diskSpace }
    }

    public func install(staged: URL, paperID: UUID, version: Int, limits: PDFLimits) throws -> PDFFileReference {
        try validateStaged(staged)
        try Task.checkCancellation()
        let values = try staged.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, version > 0 else { throw PDFLibraryError.unsafePath }
        guard let size = values.fileSize, size > 5 else { throw PDFLibraryError.invalidFile }
        guard Int64(size) <= limits.maximumBytes else { throw PDFLibraryError.tooLarge }
        let handle = try FileHandle(forReadingFrom: staged)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 5) == Data("%PDF-".utf8) else { throw PDFLibraryError.invalidFile }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { try Task.checkCancellation(); hasher.update(data: data) }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let document = PDFDocument(url: staged), !document.isLocked, document.pageCount > 0 else { throw PDFLibraryError.invalidFile }
        let relative = "PDFs/\(paperID.uuidString.lowercased())/v\(version)-\(checksum).pdf"
        let destination = try checkedURL(relative)
        try safeDirectory(destination.deletingLastPathComponent())
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try hashFile(destination) == checksum else { throw PDFLibraryError.checksum }
            try FileManager.default.removeItem(at: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        return PDFFileReference(relativePath: relative, size: Int64(size), checksum: checksum, pageCount: document.pageCount)
    }

    public func verifiedURL(_ reference: PDFFileReference) throws -> URL {
        let url = try existingURL(relativePath: reference.relativePath)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? -1) == reference.size, try hashFile(url) == reference.checksum else { throw PDFLibraryError.checksum }
        return url
    }

    public func existingURL(relativePath: String) throws -> URL {
        let url = try checkedURL(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PDFLibraryError.missing }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PDFLibraryError.unsafePath }
        return url
    }

    public func remove(relativePath: String) throws {
        let url = try checkedURL(relativePath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func discard(staged: URL) throws {
        try validateStaged(staged)
        let parent = configuration.pdfDirectory.appendingPathComponent(".staging").standardizedFileURL
        guard staged.deletingLastPathComponent().standardizedFileURL == parent, staged.pathExtension == "part" else { throw PDFLibraryError.unsafePath }
        if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
    }

    private func checkedURL(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "PDFs", UUID(uuidString: parts[1]) != nil,
              parts[2].range(of: #"^v[1-9][0-9]{0,5}-[a-f0-9]{64}\.pdf$"#, options: .regularExpression) != nil else { throw PDFLibraryError.unsafePath }
        var url = configuration.root
        for part in parts {
            url.appendPathComponent(part)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw PDFLibraryError.unsafePath }
            }
        }
        return url
    }

    private func safeDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw PDFLibraryError.unsafePath }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
