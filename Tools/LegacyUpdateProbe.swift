import Foundation
import CryptoKit

// Compiled with AppUpdater.swift from the published v1.9 tag, not current code.
@main enum LegacyUpdateProbe {
    static func main() throws {
        let manifest = URL(fileURLWithPath: CommandLine.arguments[1])
        let release = try AppUpdateRelease.decode(Data(contentsOf: manifest))
        guard try release.isNewer(than: "1.9", build: 10), release.downloadURL.pathExtension == "pkg" else {
            throw UpdateError.invalidRelease
        }
        let package = manifest.deletingLastPathComponent().appendingPathComponent(release.downloadURL.lastPathComponent)
        let data = try Data(contentsOf: package)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard release.size == data.count, release.sha256 == hash else { throw UpdateError.invalidRelease }
        print("SUCCESS: Actual v1.9 updater accepts the new release and downloads the compatible PKG")
    }
}
