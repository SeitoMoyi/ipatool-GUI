import Foundation

struct StoreApp: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let bundleID: String
    let version: String
    let artworkURL: URL?

    var displayName: String { name.isEmpty ? "App \(id)" : name }
}

enum StorePlatform: String, CaseIterable, Identifiable, Sendable {
    case iphone, ipad, appletv, watchos, visionos, macos

    var id: Self { self }

    var title: String {
        switch self {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .appletv: "Apple TV"
        case .watchos: "Apple Watch"
        case .visionos: "Apple Vision Pro"
        case .macos: "Mac"
        }
    }

    var packageExtension: String { self == .macos ? "pkg" : "ipa" }
}

struct VersionHistory: Decodable, Sendable {
    let externalVersionIdentifiers: [String]?
    let latestExternalVersionID: String?

    var previousVersions: [String] {
        Set(externalVersionIdentifiers ?? [])
            .filter { !$0.isEmpty && $0 != latestExternalVersionID }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }
}

struct VersionMetadata: Decodable, Sendable {
    let displayVersion: String
    let releaseDate: Date?

    private enum CodingKeys: String, CodingKey { case displayVersion, releaseDate }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayVersion = try container.decode(String.self, forKey: .displayVersion)
        let value = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        let date = value.flatMap { ISO8601DateFormatter().date(from: $0) }
        releaseDate = date.flatMap { $0 < Date(timeIntervalSince1970: 0) ? nil : $0 }
    }
}

struct IPATool: Sendable {
    let executable: URL

    init(executable: URL = BackendInstaller.executable) {
        self.executable = executable
    }

    func makeLoginLauncher() throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "ipatool-login-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        let launcher = directory.appending(path: "Sign in to ipatool.command")
        let executablePath = executable.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        /bin/rm -f "$0"
        /bin/rmdir "${0%/*}"
        exec '\(executablePath)' auth login

        """
        do {
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
            return launcher
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func accountEmail() async throws -> String {
        let output: AccountResponse = try await run(["auth", "info"])
        return output.email
    }

    func signOut() async throws {
        let response: SignOutResponse = try await run(["auth", "revoke"])
        guard response.success else { throw CommandError("ipatool could not sign out.") }
    }

    func versions(app: StoreApp, platform: StorePlatform) async throws -> VersionHistory {
        try await run(["list-versions", "--app-id", String(app.id), "--platform", platform.rawValue])
    }

    func metadata(app: StoreApp, platform: StorePlatform, versionID: String) async throws -> VersionMetadata {
        try await run([
            "get-version-metadata", "--app-id", String(app.id), "--platform", platform.rawValue,
            "--external-version-id", versionID
        ])
    }

    func metadata(app: StoreApp, platform: StorePlatform, versionIDs: [String]) async -> [String: VersionMetadata] {
        await withTaskGroup(of: (String, VersionMetadata?).self) { group in
            var remaining = versionIDs.makeIterator()
            let limit = platform == .macos ? 1 : 3
            for id in versionIDs.prefix(limit) {
                _ = remaining.next()
                group.addTask { (id, try? await metadata(app: app, platform: platform, versionID: id)) }
            }
            var versions: [String: VersionMetadata] = [:]
            for await (id, metadata) in group {
                versions[id] = metadata
                if let next = remaining.next() {
                    group.addTask { (next, try? await self.metadata(app: app, platform: platform, versionID: next)) }
                }
            }
            return versions
        }
    }

    func download(app: StoreApp, platform: StorePlatform, versionID: String?, destination: URL) async throws -> URL {
        // Stage next to the destination so a failed download leaves any existing file intact.
        let files = FileManager.default
        let replacing = files.fileExists(atPath: destination.path)
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".ipatool-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let stagedPackage = staging.appending(path: destination.lastPathComponent)
        var arguments = [
            "download", "--app-id", String(app.id), "--platform", platform.rawValue,
            "--output", stagedPackage.path
        ]
        if let versionID { arguments += ["--external-version-id", versionID] }
        let _: DownloadResponse = try await run(arguments)

        if replacing && files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: stagedPackage)
        } else {
            try files.moveItem(at: stagedPackage, to: destination)
        }
        return destination
    }

    private func run<Response: Decodable & Sendable>(_ arguments: [String]) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try execute(arguments) })
            }
        }
    }

    private func execute<Response: Decodable>(_ arguments: [String]) throws -> Response {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandError("The ipatool backend is missing. Restart the app to install it.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--format", "json", "--non-interactive"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A).reversed()
        if process.terminationStatus != 0 {
            for line in lines {
                if let error = try? decoder.decode(ErrorResponse.self, from: Data(line)) {
                    throw CommandError(error.error)
                }
            }
            let lastLine = lines.first.map { String(decoding: $0, as: UTF8.self) }
            throw CommandError(lastLine ?? "ipatool exited with status \(process.terminationStatus).")
        }
        for line in lines {
            if let response = try? decoder.decode(Response.self, from: Data(line)) {
                return response
            }
        }
        throw CommandError("ipatool returned an unexpected response for \(arguments[0]).")
    }

    private struct AccountResponse: Decodable { let email: String }
    private struct SignOutResponse: Decodable { let success: Bool }
    private struct DownloadResponse: Decodable { let output: String }
    private struct ErrorResponse: Decodable { let error: String }
    struct CommandError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
