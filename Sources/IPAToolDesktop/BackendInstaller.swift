import CryptoKit
import Foundation

struct BackendInstaller {
    static let executable = URL.applicationSupportDirectory
        .appending(path: "ipatool-desktop/bin/ipatool")

    var destination = Self.executable
    var session = URLSession.shared

    func install() async throws {
        let files = FileManager.default
        if files.isExecutableFile(atPath: destination.path) { return }

        let releasePage = URL(string: "https://github.com/majd/ipatool/releases/latest")!
        let (_, response) = try await session.data(for: URLRequest(url: releasePage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        try checkStatus(response)
        guard let release = response.url, release.host() == "github.com",
              release.deletingLastPathComponent().path == "/majd/ipatool/releases/tag",
              release.lastPathComponent.hasPrefix("v") else {
            throw IPATool.CommandError("GitHub did not resolve the latest ipatool release.")
        }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        let tag = release.lastPathComponent
        let binaryName = "ipatool-\(tag.dropFirst())-macos-\(architecture)"
        let assetName = binaryName + ".tar.gz"
        let asset = URL(string: "https://github.com/majd/ipatool/releases/download")!
            .appending(component: tag).appending(component: assetName)
        let checksum = asset.appendingPathExtension("sha256sum")
        let (checksumData, checksumResponse) = try await session.data(for: URLRequest(url: checksum, timeoutInterval: 30))
        try checkStatus(checksumResponse)
        let digest = String(decoding: checksumData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw IPATool.CommandError("The latest ipatool release has no valid SHA-256 checksum for this Mac.")
        }

        let directory = destination.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".install-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }

        let (download, downloadResponse) = try await session.download(for: URLRequest(url: asset, timeoutInterval: 120))
        defer { try? files.removeItem(at: download) }
        try checkStatus(downloadResponse)
        let archive = staging.appending(path: assetName)
        try files.copyItem(at: download, to: archive)

        let executable = try await Task.detached(priority: .userInitiated) {
            try Self.extractVerified(archive: archive, digest: digest, binaryName: binaryName)
        }.value
        if files.isExecutableFile(atPath: destination.path) { return }
        do {
            try files.moveItem(at: executable, to: destination)
        } catch {
            // Another window or process may have installed the same release.
            if !files.isExecutableFile(atPath: destination.path) { throw error }
        }
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw IPATool.CommandError("GitHub returned HTTP \(status) while installing ipatool.")
        }
    }

    private static func extractVerified(archive: URL, digest: String, binaryName: String) throws -> URL {
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var hash = SHA256()
        while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest.lowercased() else {
            throw IPATool.CommandError("The downloaded ipatool archive failed SHA-256 verification.")
        }

        let binary = archive.deletingLastPathComponent().appending(path: "ipatool")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // Extract just the known binary to stdout, so archive paths cannot write files.
        tar.arguments = ["-xOf", archive.path, "bin/\(binaryName)"]
        let files = FileManager.default
        guard files.createFile(atPath: binary.path, contents: nil, attributes: [.posixPermissions: 0o700]) else {
            throw IPATool.CommandError("Could not create the ipatool executable.")
        }
        let output = try FileHandle(forWritingTo: binary)
        defer { try? output.close() }
        tar.standardOutput = output
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            throw IPATool.CommandError("The verified archive did not contain the expected ipatool binary.")
        }
        return binary
    }

}
