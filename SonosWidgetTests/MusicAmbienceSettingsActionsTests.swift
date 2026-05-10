import XCTest
@testable import SonosWidget

@MainActor
final class MusicAmbienceSettingsActionsTests: XCTestCase {
    func testEnabledChangePushesCurrentStoreStateToRelayWhenReady() async {
        let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: makeDefaults()))
        store.isEnabled = false
        var refreshCount = 0
        var pushedEnabledState: Bool?

        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: { refreshCount += 1 },
            canSyncToRelay: { true },
            syncToRelay: { pushedEnabledState = store.isEnabled }
        )

        await actions.enabledChanged()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(pushedEnabledState, false)
    }

    func testEnabledChangeSkipsRelayPushWhenRelayIsNotReady() async {
        var refreshCount = 0
        var pushCount = 0
        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: { refreshCount += 1 },
            canSyncToRelay: { false },
            syncToRelay: { pushCount += 1 }
        )

        await actions.enabledChanged()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(pushCount, 0)
    }

    func testSyncableSettingChangePushesToRelayWhenReady() async {
        var pushCount = 0
        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: {},
            canSyncToRelay: { true },
            syncToRelay: { pushCount += 1 }
        )

        await actions.syncableSettingChanged()

        XCTAssertEqual(pushCount, 1)
    }

    func testSyncableSettingChangeSkipsRelayPushWhenRelayIsNotReady() async {
        var pushCount = 0
        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: {},
            canSyncToRelay: { false },
            syncToRelay: { pushCount += 1 }
        )

        await actions.syncableSettingChanged()

        XCTAssertEqual(pushCount, 0)
    }

    func testGroupPlaybackChangePushesToRelayWhenReady() async {
        var pushCount = 0
        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: {},
            canSyncToRelay: { true },
            syncToRelay: { pushCount += 1 }
        )

        await actions.groupPlaybackChanged()

        XCTAssertEqual(pushCount, 1)
    }

    func testStopBehaviorChangePushesToRelayWhenReady() async {
        var pushCount = 0
        let actions = MusicAmbienceSettingsSyncActions(
            refreshStatus: {},
            canSyncToRelay: { true },
            syncToRelay: { pushCount += 1 }
        )

        await actions.stopBehaviorChanged()

        XCTAssertEqual(pushCount, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MusicAmbienceSettingsActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
