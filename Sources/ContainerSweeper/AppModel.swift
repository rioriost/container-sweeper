import AppKit
import SweeperCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var selection: UUID?
    @Published var savedConfiguration: Configuration?
    @Published var busy = false
    @Published var statusKey = "ready"
    @Published var errorMessage: String?
    @Published var output: String?
    @Published var loadFailed = false
    let paths = SweeperPaths()
    private var baselineConfiguration: Configuration

    init() {
        do {
            let loaded = try ConfigurationStore().load()
            configuration = loaded
            baselineConfiguration = loaded
            savedConfiguration = FileManager.default.fileExists(atPath: paths.configuration.path) ? loaded : nil
            selection = loaded.profiles.first?.id
        } catch {
            let defaults = Configuration()
            configuration = defaults
            baselineConfiguration = defaults
            selection = defaults.profiles.first?.id
            errorMessage = error.localizedDescription
            loadFailed = true
        }
    }

    var localizer: Localizer { Localizer() }
    var dirty: Bool { configuration != savedConfiguration }
    var hasUnappliedEdits: Bool { configuration != baselineConfiguration }
    var selectedProfile: CleanupProfile? { configuration.profiles.first { $0.id == selection } }

    func addProfile() {
        let profile = CleanupProfile(frequency: .weekly, hour: 4, images: .dangling)
        configuration.profiles.append(profile)
        selection = profile.id
    }

    func removeSelectedProfile() {
        configuration.profiles.removeAll { $0.id == selection }
        selection = configuration.profiles.first?.id
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: configuration.containerPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { configuration.containerPath = url.path }
    }

    func save() {
        let snapshot = configuration
        let paths = paths
        guard let executable = Bundle.main.executableURL else {
            errorMessage = localizer.text("missingExecutable")
            return
        }
        let helper: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/container-sweeper-runner")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                errorMessage = localizer.text("missingHelper")
                return
            }
        } else {
            helper = executable
        }
        begin("saving")
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    try ScheduleManager(paths: paths).apply(snapshot, executable: helper)
                }.value
                savedConfiguration = snapshot
                baselineConfiguration = snapshot
                statusKey = "saved"
            } catch { fail(error) }
        }
    }

    func runNow() {
        guard let id = selection else { return }
        let snapshot = configuration
        let paths = paths
        begin("running")
        Task {
            defer { busy = false }
            do {
                try await Task.detached {
                    try CleanupRunner(paths: paths).runManual(configuration: snapshot, id: id)
                }.value
                statusKey = "completed"
                showLog(id: id)
            } catch { fail(error) }
        }
    }

    func checkCLI() {
        guard let profile = selectedProfile else { return }
        let path = configuration.containerPath
        begin("checking")
        Task {
            defer { busy = false }
            do {
                let version = try await Task.detached {
                    try CleanupService().check(path, profiles: [profile])
                }.value
                output = "\(version)\n\n\(localizer.text("compatible"))"
                statusKey = "checked"
            } catch { fail(error) }
        }
    }

    func showScheduleStatus() {
        guard let profile = selectedProfile else { return }
        let paths = paths
        begin("checking")
        Task {
            defer { busy = false }
            do {
                let status = try await Task.detached {
                    try ScheduleManager(paths: paths).status(profile)
                }.value
                output = localizer.text("scheduleStatusHint") + "\n\n" + status
                statusKey = "checked"
            } catch { fail(error) }
        }
    }

    func showLog(id: UUID) {
        let url = paths.log(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            output = localizer.text("noLog")
            return
        }
        do { output = try String(contentsOf: url, encoding: .utf8) }
        catch { fail(error) }
    }

    func openLogs() {
        do {
            try paths.prepare()
            guard NSWorkspace.shared.open(paths.logs) else {
                throw SweeperError(localizer.text("cannotOpenFolder"))
            }
        } catch { fail(error) }
    }

    private func begin(_ key: String) {
        busy = true
        statusKey = key
    }

    private func fail(_ error: any Error) {
        statusKey = "failed"
        errorMessage = error.localizedDescription
    }
}
