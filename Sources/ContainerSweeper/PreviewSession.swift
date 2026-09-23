#if DEBUG
import SweeperCore
import SwiftUI

/// Debug-only fixture launch: no settings are read, schedules registered, or cleanup run.
enum PreviewSession {
    static var arguments: [String] {
        CommandLine.arguments + (Bundle.main.object(forInfoDictionaryKey: "SweeperPreviewArguments") as? [String] ?? [])
    }

    static var isActive: Bool { arguments.contains("--preview-ui") }

    static var colorScheme: ColorScheme? {
        guard isActive else { return nil }
        return arguments.contains("--light") ? .light : .dark
    }

    @MainActor
    static func makeModel() -> AppModel {
        let args = arguments
        let language = args.contains("--english") ? "en" : "ja"
        let merged = args.contains("--merged")
        var configuration = Configuration(containerPath: "/opt/homebrew/bin/container", profiles: [
            CleanupProfile(enabled: merged, hour: 4),
            CleanupProfile(enabled: merged, frequency: .weekly, hour: 4, images: .dangling),
        ])
        if args.contains("--empty") { configuration.profiles = [] }
        if args.contains("--destructive"), !configuration.profiles.isEmpty {
            configuration.profiles[0].prune = true
            configuration.profiles[0].images = .all
        }
        let model = AppModel(previewConfiguration: configuration, languageCode: language)
        if args.contains("--load-error") {
            model.loadFailed = true
        }
        if args.contains("--busy") {
            model.busy = true
            model.statusKey = "checking"
        }
        return model
    }
}
#endif
