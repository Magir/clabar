import Foundation

// Ported from Blimp-Labs/claude-usage-bar (BSD-2-Clause).

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

struct StoredCredentialsStore {
    private let fileManager: FileManager
    let directoryURL: URL
    let credentialsFileURL: URL

    init(directoryURL: URL = ClabarPaths.dataDir, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.credentialsFileURL = directoryURL.appendingPathComponent("credentials.json")
    }

    func save(_ credentials: StoredCredentials) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(credentials)
        try data.write(to: credentialsFileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        guard let data = try? Data(contentsOf: credentialsFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredCredentials.self, from: data)
    }

    func delete() {
        try? fileManager.removeItem(at: credentialsFileURL)
    }
}
