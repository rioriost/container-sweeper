import Foundation
import SweeperCore

struct Localizer {
    var code: String {
        Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: Locale.preferredLanguages).first ?? "en"
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

    func schedule(_ profile: CleanupProfile) -> String {
        let time = String(format: "%02d:%02d", profile.hour, profile.minute)
        return profile.frequency == .daily
            ? "\(text("daily")) \(time)"
            : "\(text("weekly")) · \(text("weekday\(profile.weekday)")) \(time)"
    }

    func schedule(_ group: ScheduleGroup) -> String {
        let days = group.weekdays.count == 7 ? text("daily")
            : group.weekdays.map { text("weekday\($0)") }.joined(separator: ", ")
        return "\(days) \(String(format: "%02d:%02d", group.hour, group.minute))"
    }
}
