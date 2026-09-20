import Foundation
import XCTest
@testable import SweeperCore

final class ScheduleGroupTests: XCTestCase {
    func testDailyAndWeeklyShareOnlyTheWeeklyDay() throws {
        let daily = CleanupProfile(enabled: true)
        let weekly = CleanupProfile(enabled: true, frequency: .weekly, images: .all)
        let configuration = Configuration(profiles: [daily, weekly])
        let groups = try ScheduleGroup.compile(configuration)
        XCTAssertEqual(groups.count, 2)
        let sunday = try XCTUnwrap(groups.first { $0.weekdays == [0] })
        let otherDays = try XCTUnwrap(groups.first { $0.weekdays == [1, 2, 3, 4, 5, 6] })
        XCTAssertEqual(Set(sunday.profiles.map(\.id)), [daily.id, weekly.id])
        XCTAssertEqual(otherDays.profiles.map(\.id), [daily.id])
        XCTAssertEqual(sunday.mergedProfile.images, .all)
        XCTAssertEqual(otherDays.mergedProfile.images, .none)
        XCTAssertTrue(sunday.mergedProfile.clean)
        XCTAssertEqual(otherDays.calendarIntervals.count, 6)
    }

    func testDuplicateDailyProfilesProduceOneDailyJob() throws {
        let config = Configuration(profiles: [
            CleanupProfile(enabled: true, images: .dangling),
            CleanupProfile(enabled: true, images: .all, prune: true),
        ])
        let groups = try ScheduleGroup.compile(config)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.id, "0300-0123456")
        XCTAssertEqual(group.calendarIntervals, [["Hour": 3, "Minute": 0]])
        XCTAssertEqual(group.mergedProfile.commandPreview, [
            "container list --quiet", "container clean <each-running-container>",
            "container prune", "container image prune --all",
        ])
    }

    func testEveryEnabledCalendarSlotIsCoveredExactlyOnce() throws {
        var profiles = (0...6).map {
            CleanupProfile(enabled: true, frequency: .weekly, weekday: $0, images: .dangling)
        }
        profiles += [
            CleanupProfile(enabled: true, prune: true),
            CleanupProfile(enabled: true, minute: 1, images: .all),
            CleanupProfile(enabled: true, frequency: .weekly, weekday: 4, hour: 4),
            CleanupProfile(enabled: false, images: .all),
        ]
        let groups = try ScheduleGroup.compile(Configuration(profiles: profiles))
        for day in 0...6 {
            for hour in 0...23 {
                for minute in 0...59 {
                    let expected = profiles.filter {
                        $0.enabled && $0.hour == hour && $0.minute == minute
                            && ($0.frequency == .daily || $0.weekday == day)
                    }
                    let matching = groups.filter { group in
                        group.calendarIntervals.contains { interval in
                            interval["Hour"] == hour && interval["Minute"] == minute
                                && (interval["Weekday"] == nil || interval["Weekday"] == day)
                        }
                    }
                    XCTAssertEqual(matching.count, expected.isEmpty ? 0 : 1)
                    XCTAssertEqual(Set(matching.flatMap(\.profiles).map(\.id)), Set(expected.map(\.id)))
                }
            }
        }
    }

    func testMergingAllActionPairsPreservesUnionAndStrongestImageMode() throws {
        for firstMode in ImageCleanup.allCases {
            for secondMode in ImageCleanup.allCases {
                for firstClean in [false, true] {
                    for secondPrune in [false, true] {
                        let first = CleanupProfile(
                            enabled: true, clean: firstClean, images: firstMode, prune: true
                        )
                        let second = CleanupProfile(
                            enabled: true, clean: true, images: secondMode, prune: secondPrune
                        )
                        let group = try XCTUnwrap(ScheduleGroup.compile(Configuration(profiles: [first, second])).first)
                        XCTAssertTrue(group.mergedProfile.clean)
                        XCTAssertTrue(group.mergedProfile.prune)
                        let expected: ImageCleanup = [firstMode, secondMode].contains(.all) ? .all
                            : [firstMode, secondMode].contains(.dangling) ? .dangling : .none
                        XCTAssertEqual(group.mergedProfile.images, expected)
                    }
                }
            }
        }
    }

    func testGroupIDsAndMembershipAreIndependentOfProfileOrder() throws {
        let profiles = [
            CleanupProfile(enabled: true),
            CleanupProfile(enabled: true, frequency: .weekly, weekday: 3, images: .all),
        ]
        XCTAssertEqual(
            try ScheduleGroup.compile(Configuration(profiles: profiles)),
            try ScheduleGroup.compile(Configuration(profiles: profiles.reversed()))
        )
    }

    func testDisabledProfilesNeverAddActionsOrJobs() throws {
        let enabled = CleanupProfile(enabled: true)
        let disabled = CleanupProfile(enabled: false, images: .all, prune: true)
        let groups = try ScheduleGroup.compile(Configuration(profiles: [enabled, disabled]))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.mergedProfile.images, .none)
        XCTAssertFalse(group.mergedProfile.prune)
        XCTAssertTrue(try ScheduleGroup.compile(Configuration(profiles: [disabled])).isEmpty)
    }

    func testGroupIDsRejectMalformedTimesDaysAndPaths() {
        for valid in ["0000-0", "2359-6", "0300-0123456", "1201-135"] {
            XCTAssertTrue(ScheduleGroup.isValidID(valid), valid)
        }
        for invalid in ["2400-0", "0060-1", "300-0", "0300-", "0300-7", "0300-00", "0300-10",
                        "../0300-0", "0300-0/../other", "0300-01-2", "0300-abc"] {
            XCTAssertFalse(ScheduleGroup.isValidID(invalid), invalid)
        }
    }
}
