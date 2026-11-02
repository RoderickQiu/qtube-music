import Foundation

/// A file only this user account can open: `~/Library/Application Support/<bundle id>/Private/<name>`, the folder
/// `0700`, the file `0600`, and the folder left out of Time Machine backups.
///
/// Holds the YouTube Music session and the integration keys. This is how Firefox keeps cookies: no Keychain, so no
/// password prompt after each update of an ad-hoc signed app (its Keychain access is tied to each build's cdhash).
/// The trade-off, stated in README › Sign-in and privacy: other users can't read it, but programs running as this
/// user can, without asking.
public struct QTPrivateFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The app's private file `name`. Dev variants (`com.roderickqiu.qtube.dev-<name>`) get their own folder.
    public static func applicationSupport(_ name: String,
                                          bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube") -> QTPrivateFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return QTPrivateFile(url: base.appending(path: bundleIdentifier).appending(path: "Private").appending(path: name))
    }

    /// nil when there is no file.
    public func read() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Writes atomically; the file is created `0600` (never readable by others, even for a moment).
    public func write(_ data: Data) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if fm.fileExists(atPath: folder.path) {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)

        let temp = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
