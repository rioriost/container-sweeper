import Darwin
import Foundation

public struct SweeperPaths: Sendable {
    public let support: URL
    public let agents: URL
    public let logs: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        support = home.appendingPathComponent("Library/Application Support/ContainerSweeper")
        agents = home.appendingPathComponent("Library/LaunchAgents")
        logs = home.appendingPathComponent("Library/Logs/ContainerSweeper")
    }

    public var configuration: URL { support.appendingPathComponent("configuration.json") }
    public var helper: URL { support.appendingPathComponent("container-sweeper-runner") }
    public var lock: URL { support.appendingPathComponent("operation.lock") }
    public var schedulerLog: URL { logs.appendingPathComponent("launchd.log") }
    public func agent(for profile: CleanupProfile) -> URL {
        agents.appendingPathComponent(profile.label + ".plist")
    }
    public func agent(for group: ScheduleGroup) -> URL {
        agents.appendingPathComponent(group.label + ".plist")
    }
    public func log(for id: UUID) -> URL {
        logs.appendingPathComponent(id.uuidString.lowercased() + ".log")
    }
    public func groupLog(for id: String) throws -> URL {
        guard ScheduleGroup.isValidID(id) else { throw SweeperError("Invalid schedule group ID: \(id)") }
        return logs.appendingPathComponent("schedule-\(id).log")
    }

    public func prepare() throws {
        for directory in [support, logs, agents] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

public struct ConfigurationStore: Sendable {
    public let paths: SweeperPaths
    public init(paths: SweeperPaths = SweeperPaths()) { self.paths = paths }

    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: paths.configuration.path) else {
            return Configuration()
        }
        let configuration = try JSONDecoder().decode(
            Configuration.self, from: Data(contentsOf: paths.configuration)
        )
        try configuration.validate()
        return configuration
    }

    public func save(_ configuration: Configuration) throws {
        try configuration.validate()
        try paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: paths.configuration, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.configuration.path
        )
    }
}

public final class OperationLock {
    private let descriptor: Int32

    public init(paths: SweeperPaths) throws {
        try paths.prepare()
        descriptor = open(paths.lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SweeperError("Cannot open operation lock: \(String(cString: strerror(errno))).")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw SweeperError("Another cleanup or schedule update is running. Try again later.")
            }
            throw SweeperError("Cannot acquire operation lock: \(String(cString: strerror(code))).")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public struct RunLog {
    public let url: URL
    public init(paths: SweeperPaths, id: UUID) throws {
        try paths.prepare()
        url = paths.log(for: id)
    }

    public init(paths: SweeperPaths, groupID: String) throws {
        url = try paths.groupLog(for: groupID)
        try paths.prepare()
    }

    public func append(_ message: String) throws {
        try Self.rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try handle.write(contentsOf: Data("[\(timestamp)] \(message)\n".utf8))
    }

    public static func rotateIfNeeded(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 1_048_576 else { return }
        let previous = url.appendingPathExtension("previous")
        if FileManager.default.fileExists(atPath: previous.path) {
            try FileManager.default.removeItem(at: previous)
        }
        try FileManager.default.moveItem(at: url, to: previous)
    }
}
