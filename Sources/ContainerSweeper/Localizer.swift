import Foundation
import SweeperCore

struct Localizer {
    var languageCode: String?
    var code: String {
        if let languageCode { return languageCode }
        return Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    var locale: Locale { Locale(identifier: code) }

    func text(_ key: String) -> String {
        Self.text(key, code: code)
    }

    static func text(_ key: String, code: String) -> String {
        guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            preconditionFailure("Missing \(code) localization resources.")
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func profileName(_ profile: CleanupProfile) -> String {
        profile.name.isEmpty ? text(profile.frequency == .daily ? "dailyProfile" : "weeklyProfile") : profile.name
    }

    func actions(_ profile: CleanupProfile) -> String {
        var actions: [String] = []
        if profile.clean { actions.append(text("clean")) }
        if profile.prune { actions.append(text("prune")) }
        if profile.images != .none { actions.append(text(profile.images == .all ? "imageAll" : "imageDangling")) }
        return actions.isEmpty ? text("noActions") : actions.joined(separator: " · ")
    }

    func schedule(_ profile: CleanupProfile) -> String {
        let time = time(hour: profile.hour, minute: profile.minute)
        return profile.frequency == .daily
            ? "\(text("daily")) \(time)"
            : "\(text("weekly")) · \(text("weekday\(profile.weekday)")) \(time)"
    }

    func schedule(_ group: ScheduleGroup) -> String {
        let days = group.weekdays.count == 7 ? text("daily")
            : group.weekdays.map { text("weekday\($0)") }.joined(separator: ", ")
        return "\(days) \(time(hour: group.hour, minute: group.minute))"
    }

    func time(hour: Int, minute: Int) -> String {
        ScheduleClock.date(hour: hour, minute: minute).formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                             calendar: ScheduleClock.calendar, timeZone: ScheduleClock.calendar.timeZone)
        )
    }
}
