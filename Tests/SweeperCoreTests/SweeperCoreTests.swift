import Foundation
import XCTest
@testable import SweeperCore

// All mutable state, including the scripted response, is accessed under this lock.
private final class FakeExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var loaded: Set<String> = []
    private var bootstrapFailures: Int = 0
    private let response: @Sendable ([String]) -> CommandOutput?

    init(response: @escaping @Sendable ([String]) -> CommandOutput? = { _ in nil }) {
        self.response = response
    }

    var calls: [[String]] { lock.withLock { recorded } }
    var loadedLabels: Set<String> { lock.withLock { loaded } }
    func failNextBootstrap() { lock.withLock { bootstrapFailures = 1 } }

    func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        try lock.withLock {
            recorded.append(arguments)
            if let output = response(arguments) { return output }
            if executable == "/bin/launchctl" {
                switch arguments.first {
                case "print":
                    let label = String(arguments[1].split(separator: "/").last!)
                    return CommandOutput(status: loaded.contains(label) ? 0 : 113, stdout: label)
                case "bootstrap":
                    if bootstrapFailures > 0 {
                        bootstrapFailures -= 1
                        return CommandOutput(status: 5, stderr: "Simulated bootstrap failure")
                    }
                    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
                    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
                    loaded.insert(plist["Label"] as! String)
                case "bootout":
                    loaded.remove(String(arguments[1].split(separator: "/").last!))
                default:
                    XCTFail("Unexpected launchctl arguments: \(arguments)")
                }
                return CommandOutput()
            }
            if arguments == ["--version"] { return CommandOutput(stdout: "container CLI version 1.4.1") }
            if arguments.last == "--help" { return CommandOutput(stdout: "Usage: container --all --quiet") }
            if arguments == ["list", "--quiet"] { return CommandOutput(stdout: "web\ndb\n") }
            return CommandOutput()
        }
    }
}

private final class Fixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sweeper-test-\(UUID().uuidString)")
    var paths: SweeperPaths { SweeperPaths(home: home) }

    init() throws { try paths.prepare() }
    deinit { try? FileManager.default.removeItem(at: home) }

    func binary() throws -> URL {
        let url = home.appendingPathComponent("fixture-binary")
        try Data("test helper".utf8).write(to: url)
        return url
    }
}

final class SweeperCoreTests: XCTestCase {
    func testDefaultsNeverScheduleDestructiveActions() {
        let configuration = Configuration()
        XCTAssertEqual(configuration.profiles.map(\.frequency), [.daily, .weekly])
        XCTAssertTrue(configuration.profiles.allSatisfy { !$0.enabled && !$0.isDestructive })
        XCTAssertEqual(configuration.profiles[0].images, .none)
        XCTAssertEqual(configuration.profiles[1].images, .dangling)
    }

    func testDailyAndEveryWeeklyCalendarInterval() throws {
        var profile = CleanupProfile(hour: 23, minute: 59)
        XCTAssertEqual(profile.calendarInterval, ["Hour": 23, "Minute": 59])
        profile.frequency = .weekly
        for day in 0...6 {
            profile.weekday = day
            try profile.validate()
            XCTAssertEqual(profile.calendarInterval, ["Hour": 23, "Minute": 59, "Weekday": day])
        }
    }

    func testInvalidSchedulesAndConfigurationsAreRejected() {
        for profile in [
            CleanupProfile(hour: -1), CleanupProfile(hour: 24), CleanupProfile(minute: 60),
            CleanupProfile(weekday: 7), CleanupProfile(clean: false),
        ] {
            XCTAssertThrowsError(try profile.validate())
        }
        let profile = CleanupProfile()
        XCTAssertThrowsError(try Configuration(profiles: [profile, profile]).validate())
        XCTAssertThrowsError(try Configuration(containerPath: "container").validate())
        var config = Configuration()
        config.schemaVersion = 2
        XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try Configuration(profiles: (0..<33).map { _ in CleanupProfile() }).validate())
    }

    func testConfigurationRoundTripAndCorruptFileDoesNotReset() throws {
        let fixture = try Fixture()
        let store = ConfigurationStore(paths: fixture.paths)
        var configuration = Configuration(containerPath: "/a path/container")
        configuration.profiles[0].name = "日次"
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        try Data("broken json".utf8).write(to: fixture.paths.configuration)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configuration), Data("broken json".utf8))
    }

    func testLaunchAgentUsesArgumentArrayAndCalendarNotImmediateStartup() throws {
        let fixture = try Fixture()
        let profile = CleanupProfile(enabled: true, frequency: .weekly, weekday: 0, hour: 4, minute: 15)
        let group = try XCTUnwrap(ScheduleGroup.compile(Configuration(profiles: [profile])).first)
        let data = try LaunchAgentDefinition(group: group, paths: fixture.paths).encoded()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [
            fixture.paths.helper.path, "--run-group", group.id,
        ])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [[String: Int]], [["Hour": 4, "Minute": 15, "Weekday": 0]])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
        XCTAssertNil(plist["KeepAlive"])
    }

    func testEveryActionCombinationAndExecutionOrder() throws {
        for clean in [false, true] {
            for prune in [false, true] {
                for images in ImageCleanup.allCases {
                    let profile = CleanupProfile(clean: clean, images: images, prune: prune)
                    guard profile.hasActions else { continue }
                    let executor = FakeExecutor()
                    try CleanupService(executor: executor).perform(profile, path: "/usr/bin/true", log: { _ in })
                    var expected: [[String]] = []
                    if clean { expected += [["clean", "web"], ["clean", "db"]] }
                    if prune { expected.append(["prune"]) }
                    if images == .dangling { expected.append(["image", "prune"]) }
                    if images == .all { expected.append(["image", "prune", "--all"]) }
                    let actual = executor.calls.filter {
                        $0.last != "--help" && $0 != ["--version"] &&
                        $0 != ["system", "status"] && $0 != ["list", "--quiet"]
                    }
                    XCTAssertEqual(actual, expected)
                    XCTAssertFalse(executor.calls.contains { $0.contains("--force") || $0.contains("volume") })
                }
            }
        }
    }

    func testUnsupportedActionAbortsBeforeAnyDeletion() {
        let executor = FakeExecutor {
            $0 == ["clean", "--help"] ? CommandOutput(status: 64, stderr: "Unknown command") : nil
        }
        let profile = CleanupProfile(images: .all, prune: true)
        XCTAssertThrowsError(try CleanupService(executor: executor).perform(profile, path: "/usr/bin/true", log: { _ in }))
        XCTAssertFalse(executor.calls.contains(["prune"]))
        XCTAssertFalse(executor.calls.contains(["image", "prune", "--all"]))
        XCTAssertFalse(executor.calls.contains(["system", "status"]))
    }

    func testUnsupportedAllFlagAbortsBeforeAnyDeletion() {
        let executor = FakeExecutor {
            $0 == ["image", "prune", "--help"] ? CommandOutput(stdout: "Usage: image prune") : nil
        }
        let profile = CleanupProfile(clean: false, images: .all, prune: true)
        XCTAssertThrowsError(try CleanupService(executor: executor).perform(profile, path: "/usr/bin/true", log: { _ in }))
        XCTAssertFalse(executor.calls.contains(["prune"]))
    }

    func testStoppedServiceNeverStartsItOrDeletesData() {
        let executor = FakeExecutor {
            $0 == ["system", "status"] ? CommandOutput(status: 1, stderr: "Service is stopped") : nil
        }
        XCTAssertThrowsError(try CleanupService(executor: executor).perform(
            CleanupProfile(images: .all, prune: true), path: "/usr/bin/true", log: { _ in }
        ))
        XCTAssertFalse(executor.calls.contains(["system", "start"]))
        XCTAssertFalse(executor.calls.contains(["list", "--quiet"]))
        XCTAssertFalse(executor.calls.contains(["prune"]))
    }

    func testFailureStopsSubsequentActions() {
        let executor = FakeExecutor {
            $0 == ["clean", "web"] ? CommandOutput(status: 1, stderr: "Container stopped") : nil
        }
        XCTAssertThrowsError(try CleanupService(executor: executor).perform(
            CleanupProfile(images: .all, prune: true), path: "/usr/bin/true", log: { _ in }
        ))
        XCTAssertFalse(executor.calls.contains(["clean", "db"]))
        XCTAssertFalse(executor.calls.contains(["prune"]))
    }

    func testNoRunningContainersStillPrunesImages() throws {
        let executor = FakeExecutor { $0 == ["list", "--quiet"] ? CommandOutput() : nil }
        var messages: [String] = []
        try CleanupService(executor: executor).perform(
            CleanupProfile(images: .dangling), path: "/usr/bin/true", log: { messages.append($0) }
        )
        XCTAssertTrue(messages.contains("No running containers to clean."))
        XCTAssertTrue(executor.calls.contains(["image", "prune"]))
        XCTAssertFalse(executor.calls.contains { $0.first == "clean" && $0.last != "--help" })
    }

    func testOptionLikeContainerIDIsRejected() {
        let executor = FakeExecutor { $0 == ["list", "--quiet"] ? CommandOutput(stdout: "--all\n") : nil }
        XCTAssertThrowsError(try CleanupService(executor: executor).perform(
            CleanupProfile(), path: "/usr/bin/true", log: { _ in }
        ))
        XCTAssertFalse(executor.calls.contains(["clean", "--all"]))
    }

    func testOverlappingRunsAreRejected() throws {
        let fixture = try Fixture()
        let lock = try OperationLock(paths: fixture.paths)
        XCTAssertThrowsError(try OperationLock(paths: fixture.paths))
        withExtendedLifetime(lock) {}
    }

    func testScheduledRunnerRequiresSavedEnabledProfileAndLogsFailure() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let runner = CleanupRunner(paths: fixture.paths, executor: executor)
        let configuration = Configuration(containerPath: "/usr/bin/true")
        let groupID = "0300-0123456"
        XCTAssertThrowsError(try runner.runScheduled(groupID: groupID))
        try ConfigurationStore(paths: fixture.paths).save(configuration)
        XCTAssertThrowsError(try runner.runScheduled(groupID: groupID))
        XCTAssertTrue(executor.calls.isEmpty)
        let text = try String(contentsOf: fixture.paths.groupLog(for: groupID), encoding: .utf8)
        XCTAssertTrue(text.contains("ERROR:"))
        XCTAssertFalse(text.contains("SUCCESS:"))
    }

    func testScheduledRunnerExecutesSavedProfileAndManualRunWorksWhenDisabled() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let runner = CleanupRunner(paths: fixture.paths, executor: executor)
        var configuration = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true, clean: false, images: .dangling),
        ])
        let id = configuration.profiles[0].id
        let group = try XCTUnwrap(ScheduleGroup.compile(configuration).first)
        try ConfigurationStore(paths: fixture.paths).save(configuration)
        try runner.runScheduled(groupID: group.id)
        configuration.profiles[0].enabled = false
        try runner.runManual(configuration: configuration, id: id)
        XCTAssertEqual(executor.calls.filter { $0 == ["image", "prune"] }.count, 2)
        let text = try String(contentsOf: fixture.paths.log(for: id), encoding: .utf8)
        XCTAssertTrue(text.contains("Scheduled cleanup started"))
        XCTAssertTrue(text.contains("Manual cleanup started"))
        XCTAssertTrue(text.contains("SUCCESS:"))
    }

    func testScheduleApplyDisableAndUnrelatedAgentsArePreserved() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let manager = ScheduleManager(paths: fixture.paths, executor: executor, userID: 501)
        var configuration = Configuration(containerPath: "/usr/bin/true")
        configuration.profiles[0].enabled = true
        let unrelated = fixture.paths.agents.appendingPathComponent("dev.containersweeper.job.not-a-uuid.plist")
        try Data("unrelated".utf8).write(to: unrelated)
        let binary = try fixture.binary()
        let group = try XCTUnwrap(ScheduleGroup.compile(configuration).first)
        try manager.apply(configuration, executable: binary)
        XCTAssertEqual(executor.loadedLabels, [group.label])
        XCTAssertEqual(try ConfigurationStore(paths: fixture.paths).load(), configuration)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.helper), Data("test helper".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.agent(for: group).path))
        configuration.profiles[0].enabled = false
        try manager.apply(configuration, executable: binary)
        XCTAssertTrue(executor.loadedLabels.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.agent(for: group).path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }

    func testFailedRegistrationRollsBackSettingsPlistsHelperAndLoadedJobs() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let manager = ScheduleManager(paths: fixture.paths, executor: executor, userID: 501)
        let old = Configuration(containerPath: "/usr/bin/true", profiles: [CleanupProfile(enabled: true)])
        let binary = try fixture.binary()
        try manager.apply(old, executable: binary)
        let oldGroup = try XCTUnwrap(ScheduleGroup.compile(old).first)
        let oldPlist = try Data(contentsOf: fixture.paths.agent(for: oldGroup))
        let replacement = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true, frequency: .weekly, hour: 6),
        ])
        let newGroup = try XCTUnwrap(ScheduleGroup.compile(replacement).first)
        try Data("new helper".utf8).write(to: binary)
        executor.failNextBootstrap()
        XCTAssertThrowsError(try manager.apply(replacement, executable: binary))
        XCTAssertEqual(try ConfigurationStore(paths: fixture.paths).load(), old)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.agent(for: oldGroup)), oldPlist)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.helper), Data("test helper".utf8))
        XCTAssertEqual(executor.loadedLabels, [oldGroup.label])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.agent(for: newGroup).path))
    }

    func testInvalidCommandDoesNotReplaceExistingSchedule() throws {
        let fixture = try Fixture()
        let initialExecutor = FakeExecutor()
        let binary = try fixture.binary()
        let old = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true, clean: false, images: .dangling),
        ])
        try ScheduleManager(paths: fixture.paths, executor: initialExecutor).apply(old, executable: binary)
        let executor = FakeExecutor {
            $0 == ["clean", "--help"] ? CommandOutput(status: 64) : nil
        }
        var changed = old
        changed.profiles[0].clean = true
        XCTAssertThrowsError(try ScheduleManager(paths: fixture.paths, executor: executor).apply(changed, executable: binary))
        XCTAssertEqual(try ConfigurationStore(paths: fixture.paths).load(), old)
        XCTAssertFalse(executor.calls.contains { $0.first == "bootout" })
    }

    func testLogRotationKeepsOnePreviousFile() throws {
        let fixture = try Fixture()
        let id = UUID()
        let log = try RunLog(paths: fixture.paths, id: id)
        try Data(repeating: 65, count: 1_048_577).write(to: log.url)
        try log.append("new entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("previous").path))
        XCTAssertTrue(try String(contentsOf: log.url, encoding: .utf8).contains("new entry"))
    }

    func testProcessExecutorCapturesStatusAndStreamsWithoutShellInterpolation() throws {
        let executor = ProcessExecutor()
        let literal = "$(touch should-not-exist); space 日本語"
        let output = try executor.execute("/usr/bin/printf", ["%s", literal], timeout: 5)
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout, literal)
        let failed = try executor.execute("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"], timeout: 5)
        XCTAssertEqual(failed.status, 7)
        XCTAssertEqual(failed.stdout, "out")
        XCTAssertEqual(failed.stderr, "err")
        XCTAssertThrowsError(try executor.execute("/bin/sleep", ["2"], timeout: 0.1))
    }

    func testBothLocalizationsHaveTheSameNonemptyKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/ContainerSweeper/Resources")
        func strings(_ code: String) throws -> [String: String] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(code).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try strings("en")
        let japanese = try strings("ja")
        XCTAssertEqual(Set(english.keys), Set(japanese.keys))
        XCTAssertTrue(english.values.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(japanese.values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(english["daily"], "Daily")
        XCTAssertEqual(japanese["daily"], "日次")
    }

    func testLegacyLanguagePreferenceIsIgnoredAndRemovedOnSave() throws {
        let fixture = try Fixture()
        let configuration = Configuration()
        let data = try JSONEncoder().encode(configuration)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["language"] = "ja"
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.paths.configuration)
        let store = ConfigurationStore(paths: fixture.paths)
        XCTAssertEqual(try store.load(), configuration)
        try store.save(store.load())
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.paths.configuration)
        ) as? [String: Any])
        XCTAssertNil(saved["language"])
    }

    func testMatchingInstalledCalendarJobsRunUnionOnlyOnceAndLogEveryProfile() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let daily = CleanupProfile(enabled: true, images: .dangling, prune: true)
        let weekly = CleanupProfile(enabled: true, frequency: .weekly, clean: false, images: .all)
        let configuration = Configuration(containerPath: "/usr/bin/true", profiles: [daily, weekly])
        let manager = ScheduleManager(paths: fixture.paths, executor: executor)
        try manager.apply(configuration, executable: fixture.binary())
        let runner = CleanupRunner(paths: fixture.paths, executor: executor)
        let groups = try ScheduleGroup.compile(configuration)
        XCTAssertEqual(groups.count, 2)
        var sundayJobs = 0
        for group in groups {
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: fixture.paths.agent(for: group)), format: nil
            ) as? [String: Any])
            let intervals = try XCTUnwrap(plist["StartCalendarInterval"] as? [[String: Int]])
            if intervals.contains(where: {
                $0["Hour"] == 3 && $0["Minute"] == 0 && ($0["Weekday"] == nil || $0["Weekday"] == 0)
            }) {
                sundayJobs += 1
                let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
                XCTAssertEqual(arguments[1], "--run-group")
                try runner.runScheduled(groupID: arguments[2])
            }
        }
        XCTAssertEqual(sundayJobs, 1)
        let commands = executor.calls.filter {
            $0 == ["clean", "web"] || $0 == ["clean", "db"] || $0 == ["prune"]
                || $0 == ["image", "prune"] || $0 == ["image", "prune", "--all"]
        }
        XCTAssertEqual(commands, [["clean", "web"], ["clean", "db"], ["prune"], ["image", "prune", "--all"]])
        for profile in [daily, weekly] {
            let log = try String(contentsOf: fixture.paths.log(for: profile.id), encoding: .utf8)
            XCTAssertTrue(log.contains("merged profiles:"))
            XCTAssertTrue(log.contains(daily.id.uuidString.lowercased()))
            XCTAssertTrue(log.contains(weekly.id.uuidString.lowercased()))
            XCTAssertEqual(log.components(separatedBy: "$ container clean web").count - 1, 1)
            XCTAssertTrue(log.contains("SUCCESS:"))
        }
        let status = try manager.status(daily)
        for group in groups { XCTAssertTrue(status.contains(group.label)) }
    }

    func testWeekdayGroupDoesNotRunWeeklyOnlyActions() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let configuration = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true),
            CleanupProfile(enabled: true, frequency: .weekly, images: .all, prune: true),
        ])
        let group = try XCTUnwrap(ScheduleGroup.compile(configuration).first { $0.weekdays.contains(1) })
        try ConfigurationStore(paths: fixture.paths).save(configuration)
        try CleanupRunner(paths: fixture.paths, executor: executor).runScheduled(groupID: group.id)
        XCTAssertTrue(executor.calls.contains(["clean", "web"]))
        XCTAssertFalse(executor.calls.contains(["prune"]))
        XCTAssertFalse(executor.calls.contains(["image", "prune", "--all"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.log(for: configuration.profiles[1].id).path))
    }

    func testMergedFailureIsRecordedForEveryParticipatingProfile() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor {
            $0 == ["image", "prune", "--all"] ? CommandOutput(status: 1, stderr: "Simulated failure") : nil
        }
        let configuration = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true, clean: false, images: .dangling),
            CleanupProfile(enabled: true, clean: false, images: .all),
        ])
        let group = try XCTUnwrap(ScheduleGroup.compile(configuration).first)
        try ConfigurationStore(paths: fixture.paths).save(configuration)
        XCTAssertThrowsError(try CleanupRunner(paths: fixture.paths, executor: executor).runScheduled(groupID: group.id))
        for profile in configuration.profiles {
            let log = try String(contentsOf: fixture.paths.log(for: profile.id), encoding: .utf8)
            XCTAssertTrue(log.contains("ERROR:"))
            XCTAssertFalse(log.contains("SUCCESS:"))
        }
    }

    func testManualRunDoesNotMergeOtherProfiles() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor()
        let configuration = Configuration(containerPath: "/usr/bin/true", profiles: [
            CleanupProfile(enabled: true),
            CleanupProfile(enabled: true, images: .all, prune: true),
        ])
        try CleanupRunner(paths: fixture.paths, executor: executor).runManual(
            configuration: configuration, id: configuration.profiles[0].id
        )
        XCTAssertTrue(executor.calls.contains(["clean", "web"]))
        XCTAssertFalse(executor.calls.contains(["prune"]))
        XCTAssertFalse(executor.calls.contains(["image", "prune", "--all"]))
    }

    func testLegacyJobsMigrateAndMigrationFailureRestoresThem() throws {
        for fail in [false, true] {
            let fixture = try Fixture()
            let executor = FakeExecutor()
            let configuration = Configuration(containerPath: "/usr/bin/true", profiles: [
                CleanupProfile(enabled: true),
                CleanupProfile(enabled: true, frequency: .weekly, images: .all),
            ])
            let binary = try fixture.binary()
            try ConfigurationStore(paths: fixture.paths).save(configuration)
            try Data("old helper".utf8).write(to: fixture.paths.helper)
            for profile in configuration.profiles {
                let plist: [String: Any] = [
                    "Label": profile.label,
                    "ProgramArguments": [fixture.paths.helper.path, "--run-job", profile.id.uuidString],
                    "StartCalendarInterval": profile.calendarInterval,
                    "RunAtLoad": false,
                ]
                let url = fixture.paths.agent(for: profile)
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
                _ = try executor.execute("/bin/launchctl", ["bootstrap", "gui/501", url.path], timeout: 15)
            }
            let manager = ScheduleManager(paths: fixture.paths, executor: executor, userID: 501)
            if fail {
                executor.failNextBootstrap()
                XCTAssertThrowsError(try manager.apply(configuration, executable: binary))
                XCTAssertEqual(executor.loadedLabels, Set(configuration.profiles.map(\.label)))
                XCTAssertEqual(try Data(contentsOf: fixture.paths.helper), Data("old helper".utf8))
            } else {
                try manager.apply(configuration, executable: binary)
                XCTAssertEqual(executor.loadedLabels, Set(try ScheduleGroup.compile(configuration).map(\.label)))
                XCTAssertEqual(try Data(contentsOf: fixture.paths.helper), Data("test helper".utf8))
            }
            for profile in configuration.profiles {
                XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.paths.agent(for: profile).path), fail)
            }
            XCTAssertEqual(try ConfigurationStore(paths: fixture.paths).load(), configuration)
        }
    }
}
