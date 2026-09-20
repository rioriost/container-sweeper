import Foundation

public enum Frequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly
}

public enum ImageCleanup: String, Codable, CaseIterable, Sendable {
    case none, dangling, all
}

public struct CleanupProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var frequency: Frequency
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    public var clean: Bool
    public var images: ImageCleanup
    public var prune: Bool

    public init(
        id: UUID = UUID(), name: String = "", enabled: Bool = false,
        frequency: Frequency = .daily, weekday: Int = 0, hour: Int = 3, minute: Int = 0,
        clean: Bool = true, images: ImageCleanup = .none, prune: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.frequency = frequency
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.clean = clean
        self.images = images
        self.prune = prune
    }

    public var hasActions: Bool { clean || images != .none || prune }
    public var isDestructive: Bool { images == .all || prune }

    public var calendarInterval: [String: Int] {
        var result = ["Hour": hour, "Minute": minute]
        if frequency == .weekly { result["Weekday"] = weekday }
        return result
    }

    public var label: String { "dev.containersweeper.job.\(id.uuidString.lowercased())" }

    public func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...6).contains(weekday) else {
            throw SweeperError("Invalid schedule: hour must be 0-23, minute 0-59, weekday 0-6.")
        }
        guard hasActions else { throw SweeperError("Select at least one cleanup action.") }
    }

    public var commandPreview: [String] {
        var commands: [String] = []
        if clean {
            commands += ["container list --quiet", "container clean <each-running-container>"]
        }
        // Remove stopped references before finding unused images.
        if prune { commands.append("container prune") }
        if images == .dangling { commands.append("container image prune") }
        if images == .all { commands.append("container image prune --all") }
        return commands
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var containerPath: String
    public var profiles: [CleanupProfile]

    public init(
        containerPath: String = Configuration.defaultContainerPath,
        profiles: [CleanupProfile] = [
            CleanupProfile(),
            CleanupProfile(frequency: .weekly, hour: 4, images: .dangling),
        ]
    ) {
        self.containerPath = containerPath
        self.profiles = profiles
    }

    public static var defaultContainerPath: String {
        ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "/usr/local/bin/container"
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw SweeperError("Unsupported configuration version: \(schemaVersion).")
        }
        guard profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count else {
            throw SweeperError("Profile IDs must be unique; at most 32 profiles are allowed.")
        }
        guard containerPath.hasPrefix("/"), !containerPath.contains("\0") else {
            throw SweeperError("Choose an absolute path to the Apple container executable.")
        }
        for profile in profiles { try profile.validate() }
    }
}

public struct SweeperError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
