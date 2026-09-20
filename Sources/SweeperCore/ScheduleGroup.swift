import Foundation

public struct ScheduleGroup: Identifiable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    public let weekdays: [Int]
    public let profiles: [CleanupProfile]

    private init(hour: Int, minute: Int, weekdays: [Int], profiles: [CleanupProfile]) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.profiles = profiles
    }

    public var id: String {
        String(format: "%02d%02d", hour, minute) + "-" + weekdays.map(String.init).joined()
    }

    public static let labelPrefix = "dev.containersweeper.schedule."
    public var label: String { Self.labelPrefix + id }

    public var calendarIntervals: [[String: Int]] {
        if weekdays.count == 7 { return [["Hour": hour, "Minute": minute]] }
        return weekdays.map { ["Hour": hour, "Minute": minute, "Weekday": $0] }
    }

    public var mergedProfile: CleanupProfile {
        var merged = profiles[0]
        merged.clean = profiles.contains(where: \.clean)
        merged.prune = profiles.contains(where: \.prune)
        merged.images = profiles.contains { $0.images == .all } ? .all
            : profiles.contains { $0.images == .dangling } ? .dangling : .none
        return merged
    }

    public static func compile(_ configuration: Configuration) throws -> [ScheduleGroup] {
        try configuration.validate()
        let byTime = Dictionary(grouping: configuration.profiles.filter(\.enabled)) {
            $0.hour * 60 + $0.minute
        }
        var groups: [ScheduleGroup] = []
        for time in byTime.keys.sorted() {
            let profiles = byTime[time, default: []].sorted { $0.id.uuidString < $1.id.uuidString }
            var daysByMembers: [[UUID]: [Int]] = [:]
            for day in 0...6 {
                let members = profiles.filter { $0.frequency == .daily || $0.weekday == day }.map(\.id)
                if !members.isEmpty { daysByMembers[members, default: []].append(day) }
            }
            // Partition weekdays by membership, so no two jobs can cover the same calendar slot.
            for (members, days) in daysByMembers {
                groups.append(ScheduleGroup(
                    hour: time / 60, minute: time % 60, weekdays: days,
                    profiles: profiles.filter { members.contains($0.id) }
                ))
            }
        }
        return groups.sorted { $0.id < $1.id }
    }

    public static func isValidID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4,
              let hour = Int(parts[0].prefix(2)), (0...23).contains(hour),
              let minute = Int(parts[0].suffix(2)), (0...59).contains(minute),
              String(format: "%02d%02d", hour, minute) == parts[0],
              !parts[1].isEmpty else { return false }
        let days = parts[1].compactMap { Int(String($0)) }
        return days.count == parts[1].count && days.allSatisfy { (0...6).contains($0) }
            && days == Array(Set(days)).sorted() && days.map(String.init).joined() == parts[1]
    }
}
