import Foundation

enum ClabarPaths {
    /// App data directory. Override with CLABAR_DATA_DIR (used by tests).
    static var dataDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLABAR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clabar", isDirectory: true)
    }

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static func ensureDataDir() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
    }
}
