import Foundation
import Testing
import SweeperCore
@testable import ContainerSweeper

struct EditorTests {
    @Test func everyWallClockMinuteRoundTrips() {
        for hour in 0..<24 {
            for minute in 0..<60 {
                let result = ScheduleClock.components(ScheduleClock.date(hour: hour, minute: minute))
                #expect(result.hour == hour)
                #expect(result.minute == minute)
            }
        }
    }

    @Test @MainActor func invalidActionsCannotRunOrApply() {
        let model = AppModel(previewConfiguration: Configuration(profiles: [CleanupProfile(clean: false)]))
        #expect(!model.canRun)
        #expect(!model.canSave)
        model.requestRun()
        model.requestSave()
        #expect(model.confirmation == nil)
        #expect(model.errorMessage == nil)
        model.configuration.profiles[0].images = .dangling
        #expect(model.canRun)
        #expect(model.canSave)
        model.configuration.containerPath = "relative/path"
        #expect(!model.canSave)
    }

    @Test @MainActor func manualRunAndDestructiveSaveRequireConfirmation() {
        let model = AppModel(previewConfiguration: Configuration(profiles: [CleanupProfile(prune: true)]))
        model.requestRun()
        #expect(model.confirmation == .run)
        model.confirmation = nil
        model.configuration.profiles[0].enabled = true
        model.requestSave()
        #expect(model.confirmation == .save)
        #expect(model.errorMessage == nil)
    }

    @Test @MainActor func emptyAndBusyStatesKeepActionsSafe() {
        let model = AppModel(previewConfiguration: Configuration(profiles: []))
        #expect(!model.canRun)
        #expect(model.canSave) // Applying zero profiles is how all schedules are removed.
        model.addProfile()
        #expect(model.selection == model.configuration.profiles.first?.id)
        model.busy = true
        #expect(!model.canRun)
        #expect(!model.canSave)
        model.addProfile()
        #expect(model.configuration.profiles.count == 1)
        model.busy = false
        model.loadFailed = true
        #expect(!model.canEdit)
        #expect(!model.canSave)
    }

    @Test @MainActor func previewNeverExecutesExternalOperations() {
        let model = AppModel(previewConfiguration: Configuration())
        let original = model.savedConfiguration
        model.configuration.profiles[0].hour = 23
        model.save()
        #expect(model.savedConfiguration == original)
        #expect(model.errorMessage == model.localizer.text("previewOnly"))
        model.errorMessage = nil
        model.runNow()
        #expect(model.errorMessage == model.localizer.text("previewOnly"))
        #expect(!model.busy)
    }
}
