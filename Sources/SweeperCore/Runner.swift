import Foundation

public struct CleanupRunner: Sendable {
    public let paths: SweeperPaths
    public let executor: any CommandExecuting

    public init(paths: SweeperPaths = SweeperPaths(), executor: any CommandExecuting = ProcessExecutor()) {
        self.paths = paths
        self.executor = executor
    }

    public func runScheduled(groupID: String) throws {
        var logs = [try RunLog(paths: paths, groupID: groupID)]
        try withLogs(&logs) { logs in
            let lock = try OperationLock(paths: paths)
            defer { withExtendedLifetime(lock) {} }
            guard FileManager.default.fileExists(atPath: paths.configuration.path) else {
                throw SweeperError("Saved configuration is missing; no cleanup was performed.")
            }
            let configuration = try ConfigurationStore(paths: paths).load()
            guard let group = try ScheduleGroup.compile(configuration).first(where: { $0.id == groupID }) else {
                throw SweeperError("This schedule group is missing or disabled; no cleanup was performed. Use Save & Apply to refresh jobs.")
            }
            logs += try group.profiles.map { try RunLog(paths: paths, id: $0.id) }
            let members = group.profiles.map { $0.id.uuidString.lowercased() }.joined(separator: ", ")
            try append("Scheduled cleanup started: \(group.id); merged profiles: \(members)", to: logs)
            try CleanupService(executor: executor).perform(
                group.mergedProfile, path: configuration.containerPath,
                log: { try append($0, to: logs) }
            )
        }
    }

    public func runManual(configuration: Configuration, id: UUID) throws {
        var logs = [try RunLog(paths: paths, id: id)]
        try withLogs(&logs) { logs in
            let lock = try OperationLock(paths: paths)
            defer { withExtendedLifetime(lock) {} }
            try configuration.validate()
            guard let profile = configuration.profiles.first(where: { $0.id == id }) else {
                throw SweeperError("Profile not found.")
            }
            try append("Manual cleanup started (current GUI settings): \(profile.id)", to: logs)
            try CleanupService(executor: executor).perform(
                profile, path: configuration.containerPath, log: { try append($0, to: logs) }
            )
        }
    }

    private func append(_ message: String, to logs: [RunLog]) throws {
        for log in logs { try log.append(message) }
    }

    private func withLogs(_ logs: inout [RunLog], body: (inout [RunLog]) throws -> Void) throws {
        do {
            try body(&logs)
            try append("SUCCESS: Cleanup completed.", to: logs)
        } catch {
            let original = error.localizedDescription
            do { try append("ERROR: \(original)", to: logs) }
            catch { throw SweeperError("\(original)\nCould not write cleanup log: \(error.localizedDescription)") }
            throw error
        }
    }
}
