import SwiftUI

struct SweeperCommands: Commands {
    @ObservedObject var model: AppModel
    private func t(_ key: String) -> String { model.localizer.text(key) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(t("addProfile"), action: model.addProfile)
                .keyboardShortcut("n")
                .disabled(!model.canEdit || model.configuration.profiles.count >= 32 || model.confirmation != nil || model.output != nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(t("save"), action: model.requestSave)
                .keyboardShortcut("s")
                .disabled(!model.canSave || model.confirmation != nil || model.output != nil)
        }
        CommandMenu(t("profileMenu")) {
            Group {
                Button(t("runNow"), action: model.requestRun)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canRun)
                Button(t("showLog")) {
                    if let id = model.selection { model.showLog(id: id) }
                }
                Button(t("scheduleStatus"), action: model.showScheduleStatus)
                Divider()
                Button(t("removeProfile")) { model.confirmation = .remove }
            }
            .disabled(!model.canEdit || model.selection == nil || model.confirmation != nil || model.output != nil)
        }
    }
}
