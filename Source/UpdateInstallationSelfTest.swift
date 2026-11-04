import Foundation

enum UpdateInstallationSelfTest {
    @MainActor static func run() {
        var checks = 0
        func check(_ condition: Bool, _ description: String) {
            guard condition else { fputs("FAIL: \(description)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(description)")
        }
        func rejects(_ description: String, _ operation: () throws -> Void) {
            do { try operation(); check(false, description) } catch { check(true, description) }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FontFinder-Install-Test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--installation-self-test"), index + 1 < CommandLine.arguments.count else {
                throw UpdateInstallationError(message: "Provide the real DMG fixture path")
            }
            let dmg = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let current = Bundle.main.bundleURL
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: current.appendingPathComponent("Contents/Info.plist")), options: [], format: nil) as! [String: Any]
            let version = info["CFBundleShortVersionString"] as! String
            let build = Int(info["CFBundleVersion"] as! String)!
            let bytes = try manager.attributesOfItem(atPath: dmg.path)[.size] as! NSNumber
            let release = AppUpdateRelease(schemaVersion: 1, version: version, build: build, releaseNotes: [],
                                           downloadURL: AppUpdateRelease.packageURL(version: version), sha256: try AppUpdateInstallation.digest(dmg), size: bytes.intValue)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let apps = root.appendingPathComponent("Applications")
            try manager.createDirectory(at: apps, withIntermediateDirectories: false)
            let destination = apps.appendingPathComponent("字体检索.app")
            _ = try AppUpdateInstallation.tool("/usr/bin/ditto", [current.path, destination.path])
            let policy = UpdateInstallLocationPolicy(roots: [apps])
            let original = try UpdateInstallIdentity.read(destination)
            try AppUpdateInstallation.validateBundle(destination, release: release)
            check(true, "real signed Universal app validates with its exact release metadata")
            rejects("temporary apps cannot use the production installation path policy") { try UpdateInstallLocationPolicy.installedApplications.validate(destination) }
            let alias = apps.appendingPathComponent("alias.app")
            try manager.createSymbolicLink(at: alias, withDestinationURL: destination)
            rejects("installation rejects symlink and renamed destinations") { try policy.validate(alias) }
            let wrong = AppUpdateRelease(schemaVersion: 1, version: version, build: build, releaseNotes: [], downloadURL: release.downloadURL, sha256: String(repeating: "0", count: 64), size: release.size)
            rejects("package corruption is rejected before preparing an update") {
                _ = try AppUpdateInstallation.prepare(dmg: dmg, release: wrong, destination: destination, policy: policy)
            }
            check(try UpdateInstallIdentity.read(destination) == original, "a rejected package leaves the installed app untouched")

            func prepare() throws -> (PreparedAppUpdate, UpdateInstallJob) {
                let prepared = try AppUpdateInstallation.prepare(dmg: dmg, release: release, destination: destination, policy: policy)
                return (prepared, try JSONDecoder().decode(UpdateInstallJob.self, from: Data(contentsOf: prepared.jobURL)))
            }
            let (first, firstJob) = try prepare()
            check(try UpdateInstallIdentity.read(destination) == original, "mounting and staging the DMG never modifies the old app")
            check(try UpdateInstallIdentity.read(first.directory.appendingPathComponent("Next.app")).device == original.device,
                  "staged update and installed app are on the same filesystem")
            let permissions = try manager.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o700, "the update job directory is private to the current user")
            let independent = try AppUpdateInstallation.tool(first.directory.appendingPathComponent("Installer").path, ["--update-self-test"])
            check(independent.contains("update checks passed"), "the copied signed helper executable runs without the original application bundle")
            let output = try manager.contentsOfDirectory(atPath: first.directory.path)
            check(!output.contains("volume"), "the prepared DMG is detached before the old app exits")
            check(!AppUpdateInstallation.installationAuthorized(firstJob, directory: first.directory), "preparation alone never authorizes an installation")
            try Data(firstJob.token.utf8).write(to: first.directory.appendingPathComponent("handed-off"))
            try Data(firstJob.token.utf8).write(to: first.directory.appendingPathComponent("ready"))
            check(!AppUpdateInstallation.installationAuthorized(firstJob, directory: first.directory), "a ready helper without a parent commit cannot install")
            try Data(firstJob.token.utf8).write(to: first.directory.appendingPathComponent("commit"))
            check(AppUpdateInstallation.installationAuthorized(firstJob, directory: first.directory), "matching parent commit authorizes the prepared helper job")
            AppUpdateInstallation.abort(first)
            check(!AppUpdateInstallation.installationAuthorized(firstJob, directory: first.directory), "an aborted handoff cannot install even if it already has a commit")
            AppUpdateInstallation.discard(first)
            check(manager.fileExists(atPath: first.directory.path), "discarding a handed-off job aborts it without removing files in use")
            // This fixture never spawned an installer; remove the test-only marker before exercising pre-handoff discard.
            try manager.removeItem(at: first.directory.appendingPathComponent("handed-off"))
            AppUpdateInstallation.discard(first)
            let afterDiscard = try UpdateInstallIdentity.read(destination)
            check(!manager.fileExists(atPath: first.directory.path) && afterDiscard == original,
                  "canceling before helper handoff only removes update staging")

            let (successful, successJob) = try prepare()
            var relaunched: URL?
            try AppUpdateInstallation.install(successJob, directory: successful.directory, policy: policy) { url in
                relaunched = url
                try AppUpdateInstallation.validateBundle(url, release: release)
            }
            check(relaunched == destination, "installation requests a relaunch of the exact destination path")
            check(try UpdateInstallIdentity.read(destination) == successJob.stagedIdentity, "the staged app atomically becomes the installed app")
            check(try UpdateInstallIdentity.read(successful.directory.appendingPathComponent("Next.app")) == successJob.destinationIdentity,
                  "the old app is retained as the rollback copy until relaunch succeeds")
            // Restore the test-owned old version for the following failure cases.
            try manager.removeItem(at: destination)
            try manager.moveItem(at: successful.directory.appendingPathComponent("Next.app"), to: destination)
            try manager.removeItem(at: successful.directory)

            let (failed, failedJob) = try prepare()
            rejects("a failed new-app launch reports an installation failure") {
                try AppUpdateInstallation.install(failedJob, directory: failed.directory, policy: policy) { _ in
                    throw UpdateInstallationError(message: "Injected launch failure")
                }
            }
            check(try UpdateInstallIdentity.read(destination) == failedJob.destinationIdentity, "launch failure atomically restores the exact original app")
            try AppUpdateInstallation.validateBundle(destination, release: release)
            check(true, "the restored app retains a valid signature and executable")
            AppUpdateInstallation.discard(failed)
            check(manager.fileExists(atPath: failed.directory.path), "a job that reached installation is retained for recovery")

            let (changed, changedJob) = try prepare()
            let saved = apps.appendingPathComponent("Saved.app")
            try manager.moveItem(at: destination, to: saved)
            _ = try AppUpdateInstallation.tool("/usr/bin/ditto", [current.path, destination.path])
            let replacementIdentity = try UpdateInstallIdentity.read(destination)
            rejects("an application replaced after preparation is not overwritten") {
                try AppUpdateInstallation.install(changedJob, directory: changed.directory, policy: policy) { _ in }
            }
            check(try UpdateInstallIdentity.read(destination) == replacementIdentity && UpdateInstallIdentity.read(saved) == changedJob.destinationIdentity,
                  "identity mismatch preserves both the intervening app and original saved app")
            AppUpdateInstallation.discard(changed)

            let (tampered, tamperedJob) = try prepare()
            let stageExecutable = tampered.directory.appendingPathComponent("Next.app/Contents/MacOS/FontName")
            let handle = try FileHandle(forWritingTo: stageExecutable)
            try handle.seek(toOffset: 32); try handle.write(contentsOf: Data([0x99, 0x88])); try handle.close()
            rejects("a modified staged executable cannot be installed") {
                try AppUpdateInstallation.install(tamperedJob, directory: tampered.directory, policy: policy) { _ in }
            }
            check(try UpdateInstallIdentity.read(destination) == replacementIdentity, "staging tampering never changes the installed app")
            AppUpdateInstallation.discard(tampered)
            print("SUCCESS: \(checks) installation checks passed")
        } catch { fputs("FAIL: unexpected installation test error: \(error)\n", stderr); exit(1) }
    }
}
