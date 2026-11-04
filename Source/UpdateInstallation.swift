import AppKit
import Foundation
import CryptoKit
import Darwin

struct UpdateInstallationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct UpdateRelaunchPending: LocalizedError {
    var errorDescription: String? { "macOS 尚未确认启动结果，新版和旧版恢复副本均已保留，请手动重新打开软件。" }
}

struct PreparedAppUpdate {
    let directory: URL
    var jobURL: URL { directory.appendingPathComponent("install.json") }
}

struct UpdateInstallIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw UpdateInstallationError(message: "无法确认应用文件状态，旧版未被修改。")
        }
        return Self(device: device.uint64Value, inode: inode.uint64Value)
    }
}

struct UpdateInstallJob: Codable {
    let parentPID: Int32
    let token: String
    let destination: URL
    let destinationIdentity: UpdateInstallIdentity
    let oldExecutableHash: String
    let stagedIdentity: UpdateInstallIdentity
    let stagedExecutableHash: String
    let release: AppUpdateRelease
}

struct UpdateInstallLocationPolicy {
    let roots: [URL]
    static var installedApplications: Self {
        Self(roots: [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")])
    }
    func validate(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destination.isFileURL, destination.lastPathComponent == "字体检索.app", values?.isDirectory == true,
              values?.isSymbolicLink != true,
              roots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == parent.resolvingSymlinksInPath().standardizedFileURL }),
              destination.resolvingSymlinksInPath().standardizedFileURL == parent.resolvingSymlinksInPath().appendingPathComponent("字体检索.app").standardizedFileURL else {
            throw UpdateInstallationError(message: "请先将字体检索安装到「应用程序」，再使用自动更新；也可手动安装新版。")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallationError(message: "当前账号没有替换此应用的权限。旧版会保留，请使用有权限的账号手动安装新版。")
        }
    }
}

enum AppUpdateInstallation {
    private static let bundleIdentifier = "local.fontname.mac"
    private static let directoryPrefix = ".FontFinderUpdate-"
    private static let manager = FileManager.default

    static func prepare(dmg: URL, release: AppUpdateRelease, destination: URL = Bundle.main.bundleURL) throws -> PreparedAppUpdate {
        try prepare(dmg: dmg, release: release, destination: destination, policy: .installedApplications)
    }

    // The injected location policy is used only by integration tests on their own temporary apps.
    static func prepare(dmg: URL, release: AppUpdateRelease, destination: URL, policy: UpdateInstallLocationPolicy) throws -> PreparedAppUpdate {
        try policy.validate(destination)
        try verifyPackage(dmg, release: release)
        try validateBundle(destination)
        let originalIdentity = try UpdateInstallIdentity.read(destination)
        let originalHash = try digest(executable(in: destination))
        let directory = destination.deletingLastPathComponent().appendingPathComponent(directoryPrefix + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prepared = PreparedAppUpdate(directory: directory)
        var completed = false
        var mounted = false
        defer { if !completed && !mounted { try? manager.removeItem(at: directory) } }
        let package = directory.appendingPathComponent("package.dmg")
        try manager.copyItem(at: dmg, to: package)
        try verifyPackage(package, release: release)
        let mountpoint = directory.appendingPathComponent("volume")
        try manager.createDirectory(at: mountpoint, withIntermediateDirectories: false)
        do {
            _ = try tool("/usr/bin/hdiutil", ["attach", package.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountpoint.path])
            mounted = true
            let source = mountpoint.appendingPathComponent("字体检索.app")
            try validateBundle(source, release: release)
            let stage = directory.appendingPathComponent("Next.app")
            _ = try tool("/usr/bin/ditto", [source.path, stage.path])
            try validateBundle(stage, release: release)
            guard try UpdateInstallIdentity.read(stage).device == originalIdentity.device else {
                throw UpdateInstallationError(message: "更新暂存与应用不在同一磁盘，旧版未被修改。")
            }
            _ = try tool("/usr/bin/hdiutil", ["detach", mountpoint.path])
            mounted = false
            try manager.removeItem(at: mountpoint)
            let currentApp = Bundle.main.bundleURL
            guard currentApp.pathExtension == "app" else {
                throw UpdateInstallationError(message: "无法启动独立更新助手，请手动安装新版。")
            }
            // A bundle-signed executable's signature includes its Info.plist.
            // Keep the complete signed bundle for the independent helper.
            let helper = directory.appendingPathComponent("Helper.app")
            _ = try tool("/usr/bin/ditto", [currentApp.path, helper.path])
            try validateBundle(helper)
            let job = UpdateInstallJob(parentPID: ProcessInfo.processInfo.processIdentifier, token: UUID().uuidString,
                                       destination: destination, destinationIdentity: originalIdentity, oldExecutableHash: originalHash,
                                       stagedIdentity: try UpdateInstallIdentity.read(stage), stagedExecutableHash: try digest(executable(in: stage)), release: release)
            try JSONEncoder().encode(job).write(to: prepared.jobURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.jobURL.path)
            guard try UpdateInstallIdentity.read(destination) == originalIdentity,
                  try digest(executable(in: destination)) == originalHash else {
                throw UpdateInstallationError(message: "准备更新时原应用发生变化，已取消安装，请重新检查更新。")
            }
            completed = true
            return prepared
        } catch {
            if mounted {
                if (try? tool("/usr/bin/hdiutil", ["detach", mountpoint.path])) != nil { mounted = false }
            }
            throw error
        }
    }

    static func launch(_ prepared: PreparedAppUpdate) throws {
        let job = try loadJob(prepared.jobURL, policy: .installedApplications, allowParent: true)
        let marker = prepared.directory.appendingPathComponent("handed-off")
        try Data(job.token.utf8).write(to: marker, options: .atomic)
        let process = Process()
        process.executableURL = try executable(in: prepared.directory.appendingPathComponent("Helper.app"))
        process.arguments = ["--install-update-helper", prepared.jobURL.path]
        process.standardInput = FileHandle.nullDevice
        let log = prepared.directory.appendingPathComponent("helper.log")
        manager.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        do { try process.run() }
        catch { try? manager.removeItem(at: marker); throw error }
        let ready = prepared.directory.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? String(contentsOf: ready, encoding: .utf8)) == job.token { return }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        abort(prepared)
        // The failed handoff is explicitly aborted; quitting the old app later cannot trigger this job.
        throw UpdateInstallationError(message: "更新助手未能就绪，旧版仍在运行。请重试或手动安装新版。")
    }

    static func commit(_ prepared: PreparedAppUpdate) throws {
        let job = try loadJob(prepared.jobURL, policy: .installedApplications, allowParent: true)
        let directory = prepared.directory
        guard marker("handed-off", in: directory) == job.token, marker("ready", in: directory) == job.token,
              !manager.fileExists(atPath: directory.appendingPathComponent("abort").path),
              !manager.fileExists(atPath: directory.appendingPathComponent("failure.txt").path),
              let helperPID = marker("helper-pid", in: directory).flatMap(Int32.init), helperPID > 1, processExists(helperPID) else {
            abort(prepared)
            throw UpdateInstallationError(message: "更新助手未确认安装，旧版继续运行，请重试。")
        }
        try Data(job.token.utf8).write(to: directory.appendingPathComponent("commit"), options: .atomic)
    }

    static func abort(_ prepared: PreparedAppUpdate) {
        guard prepared.directory.lastPathComponent.hasPrefix(directoryPrefix) else { return }
        try? Data("abort".utf8).write(to: prepared.directory.appendingPathComponent("abort"), options: .atomic)
    }

    static func discard(_ prepared: PreparedAppUpdate) {
        guard prepared.directory.lastPathComponent.hasPrefix(directoryPrefix) else { return }
        if manager.fileExists(atPath: prepared.directory.appendingPathComponent("handed-off").path) {
            abort(prepared)
            return
        }
        guard !manager.fileExists(atPath: prepared.directory.appendingPathComponent("installing").path) else { return }
        try? manager.removeItem(at: prepared.directory)
    }

    static func installationAuthorized(_ job: UpdateInstallJob, directory: URL) -> Bool {
        marker("handed-off", in: directory) == job.token && marker("ready", in: directory) == job.token &&
        marker("commit", in: directory) == job.token && !manager.fileExists(atPath: directory.appendingPathComponent("abort").path)
    }

    private static func marker(_ name: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    static func runHelper(jobURL: URL) -> Int32 {
        var loaded: UpdateInstallJob?
        do {
            let job = try loadJob(jobURL, policy: .installedApplications)
            loaded = job
            let directory = jobURL.deletingLastPathComponent()
            guard marker("handed-off", in: directory) == job.token, !manager.fileExists(atPath: directory.appendingPathComponent("abort").path) else {
                throw UpdateInstallationError(message: "更新任务已取消，未安装任何文件。")
            }
            try verifyPackage(directory.appendingPathComponent("package.dmg"), release: job.release)
            try verifyUnchanged(job, directory: directory, policy: .installedApplications)
            guard !manager.fileExists(atPath: directory.appendingPathComponent("abort").path) else { throw UpdateInstallationError(message: "更新任务已取消，未安装任何文件。") }
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: directory.appendingPathComponent("helper-pid"), options: .atomic)
            try Data(job.token.utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(60)
            while processExists(job.parentPID) {
                guard marker("handed-off", in: directory) == job.token, !manager.fileExists(atPath: directory.appendingPathComponent("abort").path) else {
                    throw UpdateInstallationError(message: "更新任务已取消，未安装任何文件。")
                }
                guard Date() < deadline else {
                    throw UpdateInstallationError(message: "旧版没有退出，已取消更新。请关闭旧版后重试；应用文件未被替换。")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard installationAuthorized(job, directory: directory) else {
                throw UpdateInstallationError(message: "旧版没有确认安装，已取消本次更新。")
            }
            let anotherInstance = NSWorkspace.shared.runningApplications.contains { app in
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !app.isTerminated &&
                app.bundleURL?.resolvingSymlinksInPath() == job.destination.resolvingSymlinksInPath()
            }
            guard !anotherInstance else { throw UpdateInstallationError(message: "另一个字体检索实例仍在运行，已保留旧版，请退出后重试。") }
            try install(job, directory: directory, policy: .installedApplications, requireHandoff: true) { destination in
                try openApplication(destination)
            }
            // After a successful launch, Next.app is the old version and can be removed with this private job.
            try? manager.removeItem(at: directory)
            return 0
        } catch {
            let message = "自动更新未完成：\(error.localizedDescription)\n旧版或恢复副本已保留。恢复文件位置：\(jobURL.deletingLastPathComponent().path)"
            if loaded != nil { try? Data(message.utf8).write(to: jobURL.deletingLastPathComponent().appendingPathComponent("failure.txt"), options: .atomic) }
            if let job = loaded, installationAuthorized(job, directory: jobURL.deletingLastPathComponent()),
               !processExists(job.parentPID), manager.fileExists(atPath: job.destination.path) {
                do { try openApplication(job.destination, arguments: ["--update-install-failed", message]) }
                catch { fputs("\(message)\n无法重新打开应用：\(error.localizedDescription)\n", stderr) }
            } else { fputs("\(message)\n", stderr) }
            return 1
        }
    }

    static func install(_ job: UpdateInstallJob, directory: URL, policy: UpdateInstallLocationPolicy,
                        requireHandoff: Bool = false, relaunch: (URL) throws -> Void) throws {
        try verifyUnchanged(job, directory: directory, policy: policy)
        let stage = directory.appendingPathComponent("Next.app")
        guard !requireHandoff || installationAuthorized(job, directory: directory) else {
            throw UpdateInstallationError(message: "更新任务没有得到安装确认，未替换任何文件。")
        }
        try Data(job.token.utf8).write(to: directory.appendingPathComponent("installing"), options: .atomic)
        try exchange(stage, job.destination)
        do {
            try validateBundle(job.destination, release: job.release)
            try relaunch(job.destination)
        } catch {
            // A timed-out Launch Services request can still complete later. Never replace its executable underneath it.
            if error is UpdateRelaunchPending { throw error }
            // Swap back only if the paths still refer to the two app directories we exchanged.
            guard (try? UpdateInstallIdentity.read(job.destination)) == job.stagedIdentity,
                  (try? UpdateInstallIdentity.read(stage)) == job.destinationIdentity else {
                throw UpdateInstallationError(message: "安装路径发生变化，未覆盖任何其他文件。请从恢复目录手动恢复旧版。")
            }
            do { try exchange(stage, job.destination) }
            catch { throw UpdateInstallationError(message: "新版启动失败且无法自动还原。旧版保留在 \(stage.path)，请将它移回应用程序。") }
            throw UpdateInstallationError(message: "新版未能启动，已恢复旧版：\(error.localizedDescription)")
        }
    }

    static func verifyPackage(_ url: URL, release: AppUpdateRelease) throws {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == release.size,
              try digest(url) == release.sha256 else {
            throw UpdateInstallationError(message: "安装包大小或 SHA-256 校验失败，旧版未被修改。请重新下载。")
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateBundle(_ app: URL, release: AppUpdateRelease? = nil) throws {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: app) else {
            throw UpdateInstallationError(message: "安装包中的应用身份不匹配，旧版未被修改。")
        }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard infoValues.isRegularFile == true, infoValues.isSymbolicLink != true,
              infoURL.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/"),
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleExecutable"] as? String == "FontName" else {
            throw UpdateInstallationError(message: "安装包中的应用身份不匹配，旧版未被修改。")
        }
        if let release {
            guard info["CFBundleShortVersionString"] as? String == release.version,
                  Int(info["CFBundleVersion"] as? String ?? "") == release.build else {
                throw UpdateInstallationError(message: "安装包版本与更新信息不一致，旧版未被修改。")
            }
        }
        let executable = try executable(in: app)
        let attributes = try manager.attributesOfItem(atPath: executable.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, manager.isExecutableFile(atPath: executable.path) else {
            throw UpdateInstallationError(message: "新版程序不可执行，旧版未被修改。")
        }
        #if arch(arm64)
        let architecture = 0x0100000c
        #else
        let architecture = 0x01000007
        #endif
        guard bundle.executableArchitectures?.contains(NSNumber(value: architecture)) == true else {
            throw UpdateInstallationError(message: "新版不支持这台 Mac 的处理器，旧版未被修改。")
        }
        _ = try tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    static func executable(in app: URL) throws -> URL {
        let url = app.appendingPathComponent("Contents/MacOS/FontName")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else {
            throw UpdateInstallationError(message: "应用可执行文件无效，未执行自动更新。")
        }
        return url
    }

    private static func loadJob(_ url: URL, policy: UpdateInstallLocationPolicy, allowParent: Bool = false) throws -> UpdateInstallJob {
        let directory = url.deletingLastPathComponent()
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        let jobAttributes = try manager.attributesOfItem(atPath: url.path)
        guard url.lastPathComponent == "install.json", directory.lastPathComponent.hasPrefix(directoryPrefix),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              jobAttributes[.type] as? FileAttributeType == .typeRegular,
              ((jobAttributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024 else {
            throw UpdateInstallationError(message: "更新助手任务目录不可信，旧版未被修改。")
        }
        let job = try JSONDecoder().decode(UpdateInstallJob.self, from: Data(contentsOf: url))
        _ = try AppUpdateRelease.decode(JSONEncoder().encode(job.release))
        try policy.validate(job.destination)
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath() == job.destination.deletingLastPathComponent().resolvingSymlinksInPath(),
              directory.resolvingSymlinksInPath().standardizedFileURL == job.destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent).standardizedFileURL,
              job.parentPID > 1, (allowParent || job.parentPID != ProcessInfo.processInfo.processIdentifier),
              UUID(uuidString: job.token) != nil else {
            throw UpdateInstallationError(message: "更新任务路径或进程信息不正确，旧版未被修改。")
        }
        return job
    }

    private static func verifyUnchanged(_ job: UpdateInstallJob, directory: URL, policy: UpdateInstallLocationPolicy) throws {
        try policy.validate(job.destination)
        guard try UpdateInstallIdentity.read(job.destination) == job.destinationIdentity,
              try digest(executable(in: job.destination)) == job.oldExecutableHash,
              try UpdateInstallIdentity.read(directory.appendingPathComponent("Next.app")) == job.stagedIdentity,
              try digest(executable(in: directory.appendingPathComponent("Next.app"))) == job.stagedExecutableHash else {
            throw UpdateInstallationError(message: "应用或暂存文件发生变化，已取消更新，未替换其他文件。")
        }
        try validateBundle(job.destination)
        try validateBundle(directory.appendingPathComponent("Next.app"), release: job.release)
    }

    private static func exchange(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateInstallationError(message: "无法安全替换应用（\(String(cString: strerror(errno)))），旧版已保留，请手动安装。")
        }
    }

    private static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    @discardableResult static func openApplication(_ app: URL, arguments: [String] = []) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        let lock = NSLock()
        var done = false
        var launched: NSRunningApplication?
        var failure: Error?
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, error in
            lock.lock(); launched = application; failure = error; done = true; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            lock.lock(); let finished = done; lock.unlock()
            if finished { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock(); let application = launched; let error = failure; let finished = done; lock.unlock()
        guard finished else { throw UpdateRelaunchPending() }
        guard let application, error == nil, !application.isTerminated else {
            throw UpdateInstallationError(message: error?.localizedDescription ?? "macOS 未能确认新版已启动。")
        }
        // Keep the previous bundle until Launch Services has launched the replacement successfully.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard !application.isTerminated else { throw UpdateInstallationError(message: "新版启动后立即退出。") }
        return application
    }

    @discardableResult static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let outputDirectory = manager.temporaryDirectory.appendingPathComponent("FontFinder-Tool-" + UUID().uuidString)
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("output")
        guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateInstallationError(message: "无法创建更新检查日志，旧版未被修改。")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let data = try input.read(upToCount: 64 * 1024) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !timedOut, process.terminationStatus == 0 else {
            throw UpdateInstallationError(message: "\(URL(fileURLWithPath: path).lastPathComponent) \(timedOut ? "超时，已停止本次操作" : "验证失败")：\(text.prefix(1500))")
        }
        return text
    }
}
