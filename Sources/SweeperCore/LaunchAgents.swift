import Darwin
import Foundation

public struct LaunchAgentDefinition: Encodable, Sendable {
    public let Label: String
    public let ProgramArguments: [String]
    public let StartCalendarInterval: [[String: Int]]
    public let RunAtLoad = false
    public let ProcessType = "Background"
    public let LowPriorityIO = true
    public let StandardOutPath: String
    public let StandardErrorPath: String

    public init(group: ScheduleGroup, paths: SweeperPaths) {
        Label = group.label
        ProgramArguments = [paths.helper.path, "--run-group", group.id]
        StartCalendarInterval = group.calendarIntervals
        StandardOutPath = paths.schedulerLog.path
        StandardErrorPath = paths.schedulerLog.path
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }
}

public struct ScheduleManager: Sendable {
    public let paths: SweeperPaths
    public let executor: any CommandExecuting
    public let userID: UInt32

    public init(
        paths: SweeperPaths = SweeperPaths(), executor: any CommandExecuting = ProcessExecutor(),
        userID: UInt32 = getuid()
    ) {
        self.paths = paths
        self.executor = executor
        self.userID = userID
    }

    private var domain: String { "gui/\(userID)" }

    public func apply(_ configuration: Configuration, executable: URL) throws {
        try configuration.validate()
        let lock = try OperationLock(paths: paths)
        defer { withExtendedLifetime(lock) {} }
        let groups = try ScheduleGroup.compile(configuration)
        if !groups.isEmpty {
            _ = try CleanupService(executor: executor).check(
                configuration.containerPath, profiles: groups.map(\.mergedProfile)
            )
        }

        let existing = try managedAgents()
        let planned = groups.map { paths.agent(for: $0) }
        let allAgents = Set(existing + planned)
        var loaded: Set<URL> = []
        for url in allAgents {
            if try isLoaded(url) { loaded.insert(url) }
        }
        let files = allAgents.union([paths.configuration, paths.helper])
        var snapshots: [URL: Data] = [:]
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            snapshots[url] = try Data(contentsOf: url)
        }

        do {
            for url in loaded { try bootout(url) }
            if !groups.isEmpty {
                let binary = try Data(contentsOf: executable)
                try binary.write(to: paths.helper, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.helper.path)
            }
            try ConfigurationStore(paths: paths).save(configuration)
            for url in existing { try FileManager.default.removeItem(at: url) }
            for group in groups {
                let url = paths.agent(for: group)
                try LaunchAgentDefinition(group: group, paths: paths).encoded().write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try bootstrap(url)
            }
        } catch {
            let original = error.localizedDescription
            var failures: [String] = []
            for url in allAgents {
                do {
                    if try isLoaded(url) { try bootout(url) }
                } catch { failures.append(error.localizedDescription) }
            }
            for url in files {
                do {
                    if let data = snapshots[url] {
                        try data.write(to: url, options: .atomic)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: url == paths.helper ? 0o700 : 0o600], ofItemAtPath: url.path
                        )
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch { failures.append(error.localizedDescription) }
            }
            for url in loaded {
                do { try bootstrap(url) } catch { failures.append(error.localizedDescription) }
            }
            let rollback = failures.isEmpty
                ? "Previous configuration and schedules were restored."
                : "Rollback also failed; check LaunchAgents before continuing:\n" + failures.joined(separator: "\n")
            throw SweeperError("Schedule update failed: \(original)\n\(rollback)")
        }
    }

    public func status(_ profile: CleanupProfile) throws -> String {
        let configuration = try ConfigurationStore(paths: paths).load()
        let groups = try ScheduleGroup.compile(configuration).filter {
            $0.profiles.contains { $0.id == profile.id }
        }
        var sections: [String] = []
        for group in groups {
            let output = try status(label: group.label)
            sections.append("\(group.label)\n" + (output ?? "Not registered with launchd."))
        }
        if let legacy = try status(label: profile.label) {
            sections.append("Legacy per-profile job. Use Save & Apply to merge schedules.\n" + legacy)
        }
        return sections.isEmpty ? "Not registered with launchd." : sections.joined(separator: "\n\n")
    }

    private func status(label: String) throws -> String? {
        let output = try executor.execute(
            "/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 15
        )
        if output.status == 113 { return nil }
        guard output.status == 0 else { throw SweeperError(output.text) }
        return output.text
    }

    private func managedAgents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: paths.agents, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent
                let prefix = "dev.containersweeper.job."
                guard url.pathExtension == "plist" else { return false }
                if name.hasPrefix(prefix) {
                    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                }
                return name.hasPrefix(ScheduleGroup.labelPrefix)
                    && ScheduleGroup.isValidID(String(name.dropFirst(ScheduleGroup.labelPrefix.count)))
            }
    }

    private func isLoaded(_ url: URL) throws -> Bool {
        let label = url.deletingPathExtension().lastPathComponent
        let output = try executor.execute("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 15)
        if output.status == 113 { return false }
        guard output.status == 0 else { throw SweeperError("launchctl print failed: \(output.text)") }
        return true
    }

    private func bootout(_ url: URL) throws {
        try launchctl(["bootout", "\(domain)/\(url.deletingPathExtension().lastPathComponent)"])
    }

    private func bootstrap(_ url: URL) throws {
        try launchctl(["bootstrap", domain, url.path])
    }

    private func launchctl(_ arguments: [String]) throws {
        let output = try executor.execute("/bin/launchctl", arguments, timeout: 15)
        guard output.status == 0 else {
            throw SweeperError("launchctl \(arguments.joined(separator: " ")) exited with \(output.status): \(output.text)")
        }
    }
}
