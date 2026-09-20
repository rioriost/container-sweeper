import AppKit
import SweeperCore
import SwiftUI

@main
enum EntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            ContainerSweeperApp.main()
            return
        }
        do {
            if arguments == ["--help"] {
                print("ContainerSweeper: open without arguments for the GUI.\n--run-group <HHmm-weekdays>: execute a saved merged schedule group.")
            } else if arguments == ["--check-resources"] {
                guard Localizer.text("daily", code: "ja") == "日次",
                      Localizer.text("daily", code: "en") == "Daily" else {
                    throw SweeperError("Localization resources could not be loaded.")
                }
                print("English and Japanese resources loaded.")
            } else if arguments.count == 2, arguments[0] == "--run-group" {
                let paths = SweeperPaths()
                try RunLog.rotateIfNeeded(paths.schedulerLog)
                try CleanupRunner(paths: paths).runScheduled(groupID: arguments[1])
            } else if arguments.first == "--run-job" {
                throw SweeperError("Legacy per-profile job. Open Container Sweeper and use Save & Apply to merge schedules.")
            } else {
                throw SweeperError("Invalid arguments. Use --help for usage.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

struct ContainerSweeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Container Sweeper") {
            ContentView(model: model)
                .environment(\.locale, model.localizer.locale)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1000, height: 800)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy {
            let alert = NSAlert()
            alert.messageText = model.localizer.text("busyTitle")
            alert.informativeText = model.localizer.text("busyQuitHint")
            alert.addButton(withTitle: model.localizer.text("close"))
            alert.runModal()
            return .terminateCancel
        }
        if model.hasUnappliedEdits {
            let alert = NSAlert()
            alert.messageText = model.localizer.text("unsaved")
            alert.informativeText = model.localizer.text("unsavedQuitHint")
            alert.addButton(withTitle: model.localizer.text("cancel"))
            alert.addButton(withTitle: model.localizer.text("discardAndQuit"))
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }
}
